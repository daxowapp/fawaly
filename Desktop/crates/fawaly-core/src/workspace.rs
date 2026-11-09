use crate::{Error, Result};
use cap_fs_ext::{DirExt, FollowSymlinks, OpenOptionsFollowExt};
use cap_std::ambient_authority;
use cap_std::fs::{Dir, OpenOptions};
use sha2::{Digest, Sha256};
use std::io::{Read, Write};
use std::path::Path;

/// Provider tools act relative to an already approved project handle. Every
/// component is opened without following links; no shell or Git tools exist.
pub struct ApiWorkspace {
    root: Dir,
}

pub const FILE_LIMIT: usize = 128 * 1024;

fn failure() -> Error {
    Error::invalid("The project file is unavailable, linked, binary, too large or changed. Use ordinary UTF-8 files within the approved project.")
}

pub fn digest(data: &[u8]) -> String {
    hex::encode(Sha256::digest(data))
}

fn is_git_name(name: &str) -> bool {
    name.trim().trim_end_matches(['.', ' ']).eq_ignore_ascii_case(".git")
}

fn windows_unsafe(component: &str) -> bool {
    const DEVICES: [&str; 22] = [
        "con", "prn", "aux", "nul", "com1", "com2", "com3", "com4", "com5", "com6", "com7", "com8", "com9", "lpt1", "lpt2", "lpt3", "lpt4", "lpt5", "lpt6",
        "lpt7", "lpt8", "lpt9",
    ];
    let stem = component.split('.').next().unwrap_or("").to_ascii_lowercase();
    component.contains([':', '\\', '<', '>', '"', '|', '?', '*'])
        || component.ends_with(['.', ' '])
        || DEVICES.contains(&stem.as_str())
}

/// Rejected on every OS so a project's tool behavior does not depend on where it runs.
fn components(path: &str) -> Result<Vec<&str>> {
    let values: Vec<&str> = path.split('/').collect();
    let valid = !path.starts_with('/')
        && path.len() <= 4096
        && !values.is_empty()
        && values.iter().all(|value| {
            !value.is_empty() && *value != "." && *value != ".." && !is_git_name(value) && !windows_unsafe(value) && !value.chars().any(char::is_control)
        });
    if valid {
        Ok(values)
    } else {
        Err(Error::invalid("Use a project-relative path without links, .git or parent traversal."))
    }
}

impl ApiWorkspace {
    pub fn new(folder: &Path) -> Result<Self> {
        let root = Dir::open_ambient_dir(folder, ambient_authority()).map_err(|_| Error::invalid("The approved project is unavailable."))?;
        Ok(Self { root })
    }

    fn parent(&self, path: &str, create: bool) -> Result<(Dir, String)> {
        let values = components(path)?;
        let (name, folders) = values.split_last().ok_or_else(failure)?;
        let mut current = self.root.try_clone().map_err(|_| failure())?;
        for folder in folders {
            let next = match current.open_dir_nofollow(folder) {
                Ok(next) => next,
                Err(error) if error.kind() == std::io::ErrorKind::NotFound && create => {
                    match current.create_dir(folder) {
                        Ok(()) => {}
                        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
                        Err(_) => return Err(failure()),
                    }
                    current.open_dir_nofollow(folder).map_err(|_| failure())?
                }
                Err(_) => return Err(failure()),
            };
            current = next;
        }
        Ok((current, (*name).to_string()))
    }

    fn read_in(parent: &Dir, name: &str) -> Result<(String, String)> {
        let mut options = OpenOptions::new();
        options.read(true).follow(FollowSymlinks::No);
        let file = parent.open_with(name, &options).map_err(|_| failure())?;
        let metadata = file.metadata().map_err(|_| failure())?;
        if !metadata.is_file() || metadata.len() > FILE_LIMIT as u64 || has_extra_links(&metadata) {
            return Err(failure());
        }
        let mut data = Vec::new();
        file.take(FILE_LIMIT as u64 + 1).read_to_end(&mut data).map_err(|_| failure())?;
        if data.len() > FILE_LIMIT {
            return Err(failure());
        }
        let hash = digest(&data);
        let text = String::from_utf8(data).map_err(|_| failure())?;
        Ok((text, hash))
    }

    pub fn read(&self, path: &str) -> Result<(String, String)> {
        let (parent, name) = self.parent(path, false)?;
        Self::read_in(&parent, &name)
    }

    pub fn exists(&self, path: &str) -> bool {
        self.parent(path, false).is_ok_and(|(parent, name)| parent.symlink_metadata(&name).is_ok())
    }

    pub fn write(&self, path: &str, content: &str, expected_digest: &str) -> Result<()> {
        let valid_digest = expected_digest.is_empty() || (expected_digest.len() == 64 && expected_digest.chars().all(|c| c.is_ascii_hexdigit()));
        if !valid_digest || content.len() > FILE_LIMIT {
            return Err(failure());
        }
        let (parent, name) = self.parent(path, expected_digest.is_empty())?;
        let exists = match parent.symlink_metadata(&name) {
            Ok(_) => true,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => false,
            Err(_) => return Err(failure()),
        };
        let current = if exists { Self::read_in(&parent, &name)?.1 } else { String::new() };
        if current != expected_digest {
            return Err(Error::invalid("The file changed or was not read. Read it again before writing."));
        }
        let temporary = format!(".fawaly-{}.tmp", uuid::Uuid::new_v4());
        let mut options = OpenOptions::new();
        options.write(true).create_new(true).follow(FollowSymlinks::No);
        let outcome = (|| -> Result<()> {
            let mut file = parent.open_with(&temporary, &options).map_err(|_| failure())?;
            file.write_all(content.as_bytes()).map_err(|_| failure())?;
            file.sync_all().map_err(|_| failure())?;
            drop(file);
            if exists {
                // Recheck immediately before the replacement.
                if Self::read_in(&parent, &name)?.1 != expected_digest {
                    return Err(failure());
                }
                parent.rename(&temporary, &parent, &name).map_err(|_| failure())
            } else {
                // A hard link cannot overwrite a destination created concurrently.
                parent.hard_link(&temporary, &parent, &name).map_err(|_| failure())
            }
        })();
        let _ = parent.remove_file(&temporary);
        outcome
    }

    /// Preserves executable helpers from a verified skill manifest without running them.
    pub fn mark_executable(&self, path: &str, expected_digest: &str) -> Result<()> {
        let (parent, name) = self.parent(path, false)?;
        if Self::read_in(&parent, &name)?.1 != expected_digest {
            return Err(failure());
        }
        #[cfg(unix)]
        {
            use cap_std::fs::{Permissions, PermissionsExt};
            parent.set_permissions(&name, Permissions::from_mode(0o700)).map_err(|_| failure())?;
        }
        Ok(())
    }

    pub fn list(&self) -> Result<Vec<String>> {
        let mut results = Vec::new();
        Self::visit(&self.root, "", 0, &mut results)?;
        results.sort();
        Ok(results)
    }

    fn visit(directory: &Dir, prefix: &str, depth: usize, results: &mut Vec<String>) -> Result<()> {
        if depth >= 12 || results.len() >= 2000 {
            return Ok(());
        }
        for entry in directory.entries().map_err(|_| failure())? {
            if results.len() >= 2000 {
                break;
            }
            let Ok(entry) = entry else { continue };
            let name = entry.file_name().to_string_lossy().to_string();
            if ["node_modules", "build", ".build"].contains(&name.to_lowercase().as_str()) || is_git_name(&name) {
                continue;
            }
            let Ok(metadata) = directory.symlink_metadata(&name) else { continue };
            let path = format!("{prefix}{name}");
            if metadata.is_file() {
                results.push(path);
            } else if metadata.is_dir() {
                if let Ok(next) = directory.open_dir_nofollow(&name) {
                    Self::visit(&next, &format!("{path}/"), depth + 1, results)?;
                }
            }
        }
        Ok(())
    }
}

#[cfg(unix)]
fn has_extra_links(metadata: &cap_std::fs::Metadata) -> bool {
    use cap_std::fs::MetadataExt;
    metadata.nlink() != 1
}

#[cfg(not(unix))]
fn has_extra_links(_metadata: &cap_std::fs::Metadata) -> bool {
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    fn workspace() -> (tempfile::TempDir, ApiWorkspace) {
        let folder = tempfile::tempdir().unwrap();
        let workspace = ApiWorkspace::new(folder.path()).unwrap();
        (folder, workspace)
    }

    #[test]
    fn rejects_traversal_git_and_windows_aliases() {
        let (_folder, workspace) = workspace();
        for path in [
            "../outside.txt",
            "/etc/passwd",
            "a/../../outside",
            ".git/config",
            ".GIT/config",
            ".git./config",
            ".git /config",
            "a//b",
            "C:/Windows/x",
            "file.txt:stream",
            "NUL",
            "con.txt",
            "dir\\..\\x",
        ] {
            assert!(workspace.write(path, "x", "").is_err(), "{path} must be rejected");
            assert!(workspace.read(path).is_err(), "{path} must be rejected");
        }
    }

    #[test]
    fn writes_need_the_current_digest() {
        let (_folder, workspace) = workspace();
        workspace.write("src/a.txt", "one", "").unwrap();
        let (text, hash) = workspace.read("src/a.txt").unwrap();
        assert_eq!(text, "one");
        assert!(workspace.write("src/a.txt", "two", "").is_err(), "existing files need a digest");
        assert!(workspace.write("src/a.txt", "two", &"0".repeat(64)).is_err(), "stale digest");
        workspace.write("src/a.txt", "two", &hash).unwrap();
        assert_eq!(workspace.read("src/a.txt").unwrap().0, "two");
        assert_eq!(workspace.list().unwrap(), vec!["src/a.txt".to_string()], "no temporary files remain");
    }

    #[test]
    fn enforces_size_and_text_limits() {
        let (folder, workspace) = workspace();
        assert!(workspace.write("big.txt", &"x".repeat(FILE_LIMIT + 1), "").is_err());
        std::fs::write(folder.path().join("binary.bin"), [0xff, 0xfe, 0x00]).unwrap();
        assert!(workspace.read("binary.bin").is_err());
    }

    #[cfg(unix)]
    #[test]
    fn refuses_symlinks_anywhere_in_the_path() {
        let outside = tempfile::tempdir().unwrap();
        std::fs::write(outside.path().join("secret.txt"), "secret").unwrap();
        let (folder, workspace) = workspace();
        std::os::unix::fs::symlink(outside.path(), folder.path().join("link")).unwrap();
        std::os::unix::fs::symlink(outside.path().join("secret.txt"), folder.path().join("file-link")).unwrap();
        assert!(workspace.read("link/secret.txt").is_err());
        assert!(workspace.read("file-link").is_err());
        assert!(workspace.write("link/new.txt", "x", "").is_err());
        assert!(!outside.path().join("new.txt").exists());
        assert!(workspace.list().unwrap().is_empty(), "links are not listed");
    }

    /// Junctions need no special privilege on Windows, so a worker could create one.
    #[cfg(windows)]
    #[test]
    fn refuses_junctions_out_of_the_project() {
        let outside = tempfile::tempdir().unwrap();
        std::fs::write(outside.path().join("secret.txt"), "secret").unwrap();
        let (folder, workspace) = workspace();
        let status = std::process::Command::new("cmd")
            .args(["/C", "mklink", "/J"])
            .arg(folder.path().join("jump"))
            .arg(outside.path())
            .status()
            .unwrap();
        assert!(status.success());
        assert!(workspace.read("jump/secret.txt").is_err());
        assert!(workspace.write("jump/new.txt", "x", "").is_err());
        assert!(!outside.path().join("new.txt").exists());
        assert!(workspace.list().unwrap().is_empty());
    }

    #[cfg(unix)]
    #[test]
    fn refuses_hard_linked_files() {
        let outside = tempfile::tempdir().unwrap();
        std::fs::write(outside.path().join("secret.txt"), "secret").unwrap();
        let (folder, workspace) = workspace();
        std::fs::hard_link(outside.path().join("secret.txt"), folder.path().join("alias.txt")).unwrap();
        assert!(workspace.read("alias.txt").is_err());
    }
}
