use crate::Result;
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::io::Read;
use std::path::{Path, PathBuf};

/// What actually limits a worker's file access. Reported on every job, so the
/// app never claims more than the current OS and assistant provide.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Confinement {
    /// No project access was granted.
    NoProjectAccess,
    /// Our anchored file tools are the only way to reach the project.
    AppEnforced,
    /// Kernel-enforced project-tree limit; .git is monitored, not protected.
    LandlockGitMonitored,
    /// The assistant's own tool settings limit it; the OS does not.
    ToolLevel,
    /// The user explicitly enabled this assistant without a file boundary.
    UnconfinedByChoice,
}

impl Confinement {
    pub fn name(self) -> &'static str {
        match self {
            Self::NoProjectAccess => "no_project_access",
            Self::AppEnforced => "app_enforced",
            Self::LandlockGitMonitored => "landlock_git_monitored",
            Self::ToolLevel => "tool_level",
            Self::UnconfinedByChoice => "unconfined_by_choice",
        }
    }
}

const MANIFEST_FILE_LIMIT: usize = 50_000;
const HASH_LIMIT: u64 = 8 * 1024 * 1024;

/// Fingerprints all of .git. Detection only: it reports changes after they happen.
pub fn git_manifest(workspace: &Path) -> BTreeMap<String, String> {
    let mut manifest = BTreeMap::new();
    visit(&workspace.join(".git"), ".git", &mut manifest);
    manifest
}

fn visit(path: &Path, label: &str, manifest: &mut BTreeMap<String, String>) {
    if manifest.len() >= MANIFEST_FILE_LIMIT {
        return;
    }
    let Ok(info) = std::fs::symlink_metadata(path) else { return };
    if info.is_dir() {
        manifest.insert(format!("{label}/"), "dir".to_string());
        let Ok(entries) = std::fs::read_dir(path) else { return };
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().to_string();
            visit(&entry.path(), &format!("{label}/{name}"), manifest);
        }
    } else if info.file_type().is_symlink() {
        let target = std::fs::read_link(path).map(|value| value.to_string_lossy().to_string()).unwrap_or_default();
        manifest.insert(label.to_string(), format!("link:{target}"));
    } else if info.is_file() {
        manifest.insert(label.to_string(), file_fingerprint(path, info.len()));
    }
}

fn file_fingerprint(path: &Path, length: u64) -> String {
    if length > HASH_LIMIT {
        let modified = std::fs::metadata(path).and_then(|info| info.modified()).ok();
        return format!("large:{length}:{modified:?}");
    }
    let mut data = Vec::new();
    match std::fs::File::open(path).and_then(|file| file.take(HASH_LIMIT + 1).read_to_end(&mut data)) {
        Ok(_) => hex::encode(Sha256::digest(&data)),
        Err(_) => format!("unreadable:{length}"),
    }
}

pub fn manifest_changes(before: &BTreeMap<String, String>, after: &BTreeMap<String, String>) -> Vec<String> {
    let mut changes = Vec::new();
    for (path, value) in after {
        match before.get(path) {
            None => changes.push(format!("added {path}")),
            Some(old) if old != value => changes.push(format!("changed {path}")),
            _ => {}
        }
    }
    changes.extend(before.keys().filter(|path| !after.contains_key(*path)).map(|path| format!("removed {path}")));
    changes
}

/// Reads a native worker needs on Linux. The home folder is deliberately absent.
pub fn linux_system_read_paths() -> Vec<PathBuf> {
    ["/usr", "/bin", "/sbin", "/lib", "/lib32", "/lib64", "/libx32", "/etc", "/opt", "/proc", "/sys", "/dev", "/run", "/nix", "/snap"]
        .iter()
        .map(PathBuf::from)
        .filter(|path| path.exists())
        .collect()
}

/// Applies Landlock to this process; the caller then replaces itself with the worker.
#[cfg(target_os = "linux")]
pub fn apply_landlock(read: &[PathBuf], write: &[PathBuf]) -> Result<()> {
    use crate::Error;
    use landlock::{path_beneath_rules, Access, AccessFs, Ruleset, RulesetAttr, RulesetCreatedAttr, RulesetStatus, ABI};
    let abi = ABI::V3;
    let refuse = |_| Error::invalid("Sudo Interns could not apply the Landlock file boundary.");
    let read: Vec<&PathBuf> = read.iter().filter(|path| path.exists()).collect();
    let write: Vec<&PathBuf> = write.iter().filter(|path| path.exists()).collect();
    let status = Ruleset::default()
        .handle_access(AccessFs::from_all(abi))
        .map_err(refuse)?
        .create()
        .map_err(refuse)?
        .add_rules(path_beneath_rules(read, AccessFs::from_read(abi)))
        .map_err(refuse)?
        .add_rules(path_beneath_rules(write, AccessFs::from_all(abi)))
        .map_err(refuse)?
        .restrict_self()
        .map_err(refuse)?;
    if status.ruleset == RulesetStatus::NotEnforced {
        return Err(Error::invalid("Sudo Interns landlock support is not enforced by this kernel."));
    }
    Ok(())
}

#[cfg(not(target_os = "linux"))]
pub fn apply_landlock(_read: &[PathBuf], _write: &[PathBuf]) -> Result<()> {
    Err(crate::Error::invalid("Landlock exists only on Linux."))
}

/// Runs in a child, because Landlock cannot be undone in the process applying it.
pub fn landlock_available(helper: Option<&Path>) -> bool {
    if !cfg!(target_os = "linux") {
        return false;
    }
    let Some(helper) = helper else { return false };
    std::process::Command::new(helper)
        .arg("confine-probe")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .is_ok_and(|status| status.success())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn manifest_detects_every_kind_of_git_change() {
        let project = tempfile::tempdir().unwrap();
        let git = project.path().join(".git");
        std::fs::create_dir_all(git.join("refs/heads")).unwrap();
        std::fs::create_dir_all(git.join("hooks")).unwrap();
        std::fs::write(git.join("config"), "a").unwrap();
        std::fs::write(git.join("refs/heads/main"), "1").unwrap();
        std::fs::write(git.join("packed-refs"), "p").unwrap();
        let before = git_manifest(project.path());
        assert!(manifest_changes(&before, &git_manifest(project.path())).is_empty());
        std::fs::write(git.join("config"), "b").unwrap();
        std::fs::write(git.join("hooks/pre-commit"), "evil").unwrap();
        std::fs::remove_file(git.join("packed-refs")).unwrap();
        let changes = manifest_changes(&before, &git_manifest(project.path()));
        assert!(changes.contains(&"changed .git/config".to_string()));
        assert!(changes.contains(&"added .git/hooks/pre-commit".to_string()));
        assert!(changes.contains(&"removed .git/packed-refs".to_string()));
    }

    #[test]
    fn a_project_without_git_has_an_empty_manifest() {
        let project = tempfile::tempdir().unwrap();
        assert!(git_manifest(project.path()).is_empty());
    }
}
