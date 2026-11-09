use crate::engine::Engine;
use crate::model::Agent;
use crate::process::{self, LoginCommand};
use crate::{paths, Error, Result};
use serde::Deserialize;
use sha2::{Digest, Sha256};
use std::fs::File;
use std::io::{Read, Write};
use std::path::{Component, Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

const DOWNLOAD_LIMIT: u64 = 400_000_000;
const EXTRACT_LIMIT: u64 = 1_500_000_000;
const ALLOWED_HOSTS: [&str; 5] = ["api.github.com", "github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com", "downloads.claude.ai"];
const CLAUDE_BASE: &str = "https://downloads.claude.ai/claude-code-releases";

pub struct Platform {
    pub codex: &'static str,
    pub claude: String,
    pub kimi: &'static str,
}

/// Returns None on a combination the official runtimes do not ship for.
pub fn platform() -> Option<Platform> {
    let musl = cfg!(target_os = "linux") && (Path::new("/lib/ld-musl-x86_64.so.1").exists() || Path::new("/lib/ld-musl-aarch64.so.1").exists());
    let (codex, claude, kimi) = match (std::env::consts::OS, std::env::consts::ARCH) {
        ("linux", "x86_64") => ("x86_64-unknown-linux-musl", "linux-x64", "linux-x64"),
        ("linux", "aarch64") => ("aarch64-unknown-linux-musl", "linux-arm64", "linux-arm64"),
        ("windows", "x86_64") => ("x86_64-pc-windows-msvc", "win32-x64", "win32-x64"),
        ("windows", "aarch64") => ("aarch64-pc-windows-msvc", "win32-arm64", "win32-arm64"),
        ("macos", "aarch64") => ("aarch64-apple-darwin", "darwin-arm64", "darwin-arm64"),
        ("macos", "x86_64") => ("x86_64-apple-darwin", "darwin-x64", "darwin-x64"),
        _ => return None,
    };
    let claude = if musl { format!("{claude}-musl") } else { claude.to_string() };
    Some(Platform { codex, claude, kimi })
}

#[derive(Deserialize)]
struct Asset {
    name: String,
    browser_download_url: String,
    digest: Option<String>,
    size: u64,
}

#[derive(Deserialize)]
struct Release {
    assets: Vec<Asset>,
}

#[derive(Deserialize)]
struct ClaudePlatform {
    checksum: String,
    size: u64,
}

#[derive(Deserialize)]
struct ClaudeManifest {
    platforms: std::collections::HashMap<String, ClaudePlatform>,
}

fn unavailable() -> Error {
    Error::invalid("The official download service is unavailable. Please retry.")
}

fn host_allowed(url: &str) -> bool {
    url::Url::parse(url).is_ok_and(|parsed| parsed.scheme() == "https" && parsed.host_str().is_some_and(|host| ALLOWED_HOSTS.contains(&host)))
}

/// Follows redirects by hand, so every hop stays on an official host.
fn open(url: &str, timeout: Duration) -> Result<ureq::http::Response<ureq::Body>> {
    let agent: ureq::Agent = ureq::Agent::config_builder()
        .max_redirects(0)
        .max_redirects_will_error(false)
        .http_status_as_error(false)
        .timeout_global(Some(timeout))
        .user_agent("SudoInterns-Desktop")
        .build()
        .into();
    let mut current = url.to_string();
    for _ in 0..6 {
        if !host_allowed(&current) {
            return Err(Error::invalid("The official service download could not be verified."));
        }
        let response = agent.get(&current).header("Accept", "*/*").call().map_err(|_| unavailable())?;
        let status = response.status().as_u16();
        if (300..400).contains(&status) {
            current = response.headers().get("location").and_then(|value| value.to_str().ok()).ok_or_else(unavailable)?.to_string();
            continue;
        }
        if !(200..300).contains(&status) {
            return Err(unavailable());
        }
        return Ok(response);
    }
    Err(unavailable())
}

fn metadata(url: &str, limit: u64) -> Result<Vec<u8>> {
    open(url, Duration::from_secs(30))?.body_mut().with_config().limit(limit).read_to_vec().map_err(|_| Error::invalid("Official service metadata exceeded its size limit."))
}

fn download(url: &str, size: u64, checksum: &str, destination: &Path, cancel: &AtomicBool) -> Result<()> {
    if size == 0 || size > DOWNLOAD_LIMIT || checksum.len() != 64 || !checksum.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err(Error::invalid("The official service manifest is incomplete."));
    }
    let mut response = open(url, Duration::from_secs(900))?;
    let mut reader = response.body_mut().with_config().limit(DOWNLOAD_LIMIT + 1).reader();
    let mut file = File::create_new(destination)?;
    let mut hash = Sha256::new();
    let mut total = 0_u64;
    let mut buffer = vec![0_u8; 1 << 20];
    loop {
        if cancel.load(Ordering::Relaxed) {
            return Err(Error::Cancelled);
        }
        let count = reader.read(&mut buffer).map_err(|_| unavailable())?;
        if count == 0 {
            break;
        }
        total += count as u64;
        hash.update(&buffer[..count]);
        file.write_all(&buffer[..count])?;
    }
    if total != size || !hex::encode(hash.finalize()).eq_ignore_ascii_case(checksum) {
        return Err(Error::invalid("The download did not pass its integrity check. Please retry."));
    }
    Ok(())
}

fn safe_relative(path: &Path) -> bool {
    path.components().all(|component| matches!(component, Component::Normal(_) | Component::CurDir))
}

fn write_entry(target: &Path, source: &mut impl Read, budget: &mut u64) -> Result<()> {
    if let Some(parent) = target.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let mut file = File::create_new(target)?;
    let copied = std::io::copy(&mut source.take(*budget + 1), &mut file)?;
    if copied > *budget {
        return Err(Error::invalid("The service archive is larger than expected."));
    }
    *budget -= copied;
    paths::set_executable(target)
}

/// Optional Codex voice libraries are skipped; workers never use them.
fn skipped(path: &Path) -> bool {
    path.to_string_lossy().replace('\\', "/").starts_with("codex-resources/voice/")
}

pub fn extract_zip(archive: &Path, destination: &Path) -> Result<()> {
    let invalid = || Error::invalid("The service archive has an unexpected layout.");
    let mut zip = zip::ZipArchive::new(File::open(archive)?).map_err(|_| invalid())?;
    let mut budget = EXTRACT_LIMIT;
    for index in 0..zip.len() {
        let mut entry = zip.by_index(index).map_err(|_| invalid())?;
        let relative = entry.enclosed_name().ok_or_else(invalid)?;
        if skipped(&relative) || entry.is_dir() {
            continue;
        }
        if entry.is_symlink() || !safe_relative(&relative) {
            return Err(invalid());
        }
        write_entry(&destination.join(relative), &mut entry, &mut budget)?;
    }
    Ok(())
}

pub fn extract_tar_gz(archive: &Path, destination: &Path) -> Result<()> {
    let invalid = || Error::invalid("The service archive has an unexpected layout.");
    let mut tar = tar::Archive::new(flate2::read::GzDecoder::new(File::open(archive)?));
    let mut budget = EXTRACT_LIMIT;
    for entry in tar.entries().map_err(|_| invalid())? {
        let mut entry = entry.map_err(|_| invalid())?;
        let kind = entry.header().entry_type();
        let relative = entry.path().map_err(|_| invalid())?.into_owned();
        if !safe_relative(&relative) || relative.is_absolute() {
            return Err(invalid());
        }
        if kind.is_dir() || skipped(&relative) {
            continue;
        }
        if !kind.is_file() {
            return Err(invalid());
        }
        write_entry(&destination.join(relative), &mut entry, &mut budget)?;
    }
    Ok(())
}

/// Archives name the binary after its platform; the runtime needs its plain name.
fn normalize_entry(staging: &Path, agent: Agent, platform_name: &str) -> Result<()> {
    let plain = paths::exe_name(agent.raw());
    if staging.join(&plain).is_file() || staging.join("bin").join(&plain).is_file() {
        return Ok(());
    }
    let suffixed = paths::exe_name(&format!("{}-{platform_name}", agent.raw()));
    if staging.join(&suffixed).is_file() {
        std::fs::rename(staging.join(&suffixed), staging.join(&plain))?;
        return Ok(());
    }
    Err(Error::invalid("The service archive has an unexpected layout."))
}

fn github_asset(repository: &str, name: &str) -> Result<Asset> {
    let data = metadata(&format!("https://api.github.com/repos/{repository}/releases/latest"), 2 * 1024 * 1024)?;
    let release: Release = serde_json::from_slice(&data).map_err(|_| unavailable())?;
    let asset = release.assets.into_iter().find(|asset| asset.name == name);
    let prefix = format!("https://github.com/{repository}/releases/download/");
    asset
        .filter(|asset| asset.browser_download_url.starts_with(&prefix) && asset.size <= DOWNLOAD_LIMIT && asset.digest.as_deref().is_some_and(|digest| digest.starts_with("sha256:")))
        .ok_or_else(|| Error::invalid("The official service download could not be verified."))
}

fn fetch_into(agent: Agent, staging: &Path, cancel: &AtomicBool) -> Result<()> {
    let platform = platform().ok_or_else(|| Error::invalid("This service is unavailable for this computer."))?;
    let windows = cfg!(windows);
    match agent {
        Agent::Codex | Agent::Kimi => {
            let (repository, asset_name, platform_name) = if agent == Agent::Codex {
                ("openai/codex", format!("codex-{}{}", platform.codex, if windows { ".exe.zip" } else { ".tar.gz" }), platform.codex)
            } else {
                ("MoonshotAI/kimi-code", format!("kimi-code-{}{}", platform.kimi, if windows { ".zip" } else { ".tar.gz" }), platform.kimi)
            };
            let asset = github_asset(repository, &asset_name)?;
            let checksum = asset.digest.as_deref().unwrap_or_default().trim_start_matches("sha256:").to_string();
            let archive = staging.join(".download");
            download(&asset.browser_download_url, asset.size, &checksum, &archive, cancel)?;
            if windows {
                extract_zip(&archive, staging)?;
            } else {
                extract_tar_gz(&archive, staging)?;
            }
            std::fs::remove_file(&archive)?;
            normalize_entry(staging, agent, platform_name)
        }
        Agent::Claude => {
            let version = String::from_utf8(metadata(&format!("{CLAUDE_BASE}/stable"), 128)?).map_err(|_| unavailable())?;
            let version = version.trim();
            let parts: Vec<&str> = version.split('.').collect();
            if parts.len() != 3 || !parts.iter().all(|part| !part.is_empty() && part.bytes().all(|byte| byte.is_ascii_digit())) {
                return Err(Error::invalid("The official Claude Code version could not be read."));
            }
            let data = metadata(&format!("{CLAUDE_BASE}/{version}/manifest.json"), 512 * 1024)?;
            let manifest: ClaudeManifest = serde_json::from_slice(&data).map_err(|_| unavailable())?;
            let entry = manifest.platforms.get(&platform.claude).ok_or_else(|| Error::invalid("Claude Code is unavailable for this computer."))?;
            let name = paths::exe_name("claude");
            let destination = staging.join(&name);
            download(&format!("{CLAUDE_BASE}/{version}/{}/{name}", platform.claude), entry.size, &entry.checksum, &destination, cancel)?;
            paths::set_executable(&destination)
        }
        _ => Err(Error::invalid("This service does not install a native CLI.")),
    }
}

fn verify(engine: &Engine, executable: &Path, directory: &Path) -> Result<()> {
    let never = AtomicBool::new(false);
    let reply = process::run_login(
        &LoginCommand {
            executable: executable.to_path_buf(),
            arguments: vec!["--version".to_string()],
            environment: process::base_environment(&engine.home),
            directory: directory.to_path_buf(),
            input: None,
        },
        Duration::from_secs(60),
        &never,
        &|_| {},
    )?;
    if reply.exit_code == 0 && !(reply.output.trim().is_empty() && reply.error_output.trim().is_empty()) {
        Ok(())
    } else {
        Err(Error::invalid("The downloaded service could not be verified or prepared."))
    }
}

fn find_entry(directory: &Path, agent: Agent) -> Option<PathBuf> {
    let name = paths::exe_name(agent.raw());
    [directory.join(&name), directory.join("bin").join(&name)].into_iter().find(|path| path.is_file())
}

/// Installs under the user's data folder. No administrator rights are involved.
pub fn install(engine: &Engine, agent: Agent, cancel: &AtomicBool) -> Result<PathBuf> {
    let runtimes = engine.root.join("runtimes");
    paths::ensure_private_dir(&runtimes)?;
    let target = engine.runtime_dir(agent);
    if let Some(existing) = find_entry(&target, agent) {
        verify(engine, &existing, &runtimes)?;
        return Ok(existing);
    }
    let staging = runtimes.join(format!(".install-{}", uuid::Uuid::new_v4()));
    paths::ensure_private_dir(&staging)?;
    let outcome = (|| -> Result<PathBuf> {
        fetch_into(agent, &staging, cancel)?;
        let candidate = find_entry(&staging, agent).ok_or_else(|| Error::invalid("The service could not be located after preparation."))?;
        verify(engine, &candidate, &staging)?;
        if cancel.load(Ordering::Relaxed) {
            return Err(Error::Cancelled);
        }
        if target.exists() {
            std::fs::remove_dir_all(&target)?;
        }
        std::fs::rename(&staging, &target)?;
        find_entry(&target, agent).ok_or_else(|| Error::invalid("The service could not be located after preparation."))
    })();
    let _ = std::fs::remove_dir_all(&staging);
    outcome
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn download_hosts_are_limited() {
        assert!(host_allowed("https://github.com/openai/codex/releases/download/x"));
        assert!(!host_allowed("http://github.com/x"));
        assert!(!host_allowed("https://example.com/x"));
    }

    #[test]
    fn tar_entries_cannot_escape_the_install_folder() {
        let folder = tempfile::tempdir().unwrap();
        let archive_path = folder.path().join("a.tar.gz");
        let file = File::create(&archive_path).unwrap();
        let mut builder = tar::Builder::new(flate2::write::GzEncoder::new(file, flate2::Compression::fast()));
        let mut header = tar::Header::new_gnu();
        header.as_old_mut().name[..7].copy_from_slice(b"../evil");
        header.set_size(1);
        header.set_entry_type(tar::EntryType::Regular);
        header.set_cksum();
        builder.append(&header, &b"x"[..]).unwrap();
        builder.into_inner().unwrap().finish().unwrap();
        let destination = folder.path().join("out");
        std::fs::create_dir_all(&destination).unwrap();
        assert!(extract_tar_gz(&archive_path, &destination).is_err());
        assert!(!folder.path().join("evil").exists());
    }

    #[test]
    fn tar_links_are_refused() {
        let folder = tempfile::tempdir().unwrap();
        let archive_path = folder.path().join("a.tar.gz");
        let file = File::create(&archive_path).unwrap();
        let mut builder = tar::Builder::new(flate2::write::GzEncoder::new(file, flate2::Compression::fast()));
        let mut header = tar::Header::new_gnu();
        header.set_size(0);
        header.set_entry_type(tar::EntryType::Symlink);
        builder.append_link(&mut header, "link", "/etc/passwd").unwrap();
        builder.into_inner().unwrap().finish().unwrap();
        let destination = folder.path().join("out");
        std::fs::create_dir_all(&destination).unwrap();
        assert!(extract_tar_gz(&archive_path, &destination).is_err());
    }

    #[test]
    fn platform_named_binaries_get_their_plain_name() {
        let folder = tempfile::tempdir().unwrap();
        let name = paths::exe_name("codex-x86_64-unknown-linux-musl");
        std::fs::write(folder.path().join(name), "x").unwrap();
        normalize_entry(folder.path(), Agent::Codex, "x86_64-unknown-linux-musl").unwrap();
        assert!(folder.path().join(paths::exe_name("codex")).is_file());
    }

    #[test]
    fn checksum_mismatch_is_refused_before_any_request() {
        let folder = tempfile::tempdir().unwrap();
        let never = AtomicBool::new(false);
        assert!(download("https://github.com/x", 10, "short", &folder.path().join("f"), &never).is_err());
    }
}
