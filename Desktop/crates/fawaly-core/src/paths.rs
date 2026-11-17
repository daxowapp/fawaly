use crate::{Error, Result};
use std::path::{Path, PathBuf};

/// `SUDO_INTERNS_DATA_DIR` isolates fresh-profile tests. It must be absolute.
pub fn data_root() -> Result<PathBuf> {
    if let Some(value) = std::env::var_os("SUDO_INTERNS_DATA_DIR") {
        let path = PathBuf::from(value);
        if !path.is_absolute() {
            return Err(Error::invalid("SUDO_INTERNS_DATA_DIR must be an absolute path."));
        }
        return Ok(path);
    }
    dirs::data_dir()
        .map(|base| base.join("SudoInterns"))
        .ok_or_else(|| Error::invalid("The application data folder could not be located."))
}

pub fn home() -> Result<PathBuf> {
    if let Some(value) = std::env::var_os("SUDO_INTERNS_HOME") {
        let path = PathBuf::from(value);
        if !path.is_absolute() {
            return Err(Error::invalid("SUDO_INTERNS_HOME must be an absolute path."));
        }
        return Ok(path);
    }
    dirs::home_dir().ok_or_else(|| Error::invalid("The home folder could not be located."))
}

pub fn ensure_private_dir(path: &Path) -> Result<()> {
    std::fs::create_dir_all(path)?;
    set_private(path, true)
}

#[cfg(unix)]
pub fn set_private(path: &Path, directory: bool) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(if directory { 0o700 } else { 0o600 }))?;
    Ok(())
}

/// Files under the per-user profile inherit the profile's owner-only ACL.
#[cfg(not(unix))]
pub fn set_private(_path: &Path, _directory: bool) -> Result<()> {
    Ok(())
}

#[cfg(unix)]
pub fn set_executable(path: &Path) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700))?;
    Ok(())
}

#[cfg(not(unix))]
pub fn set_executable(_path: &Path) -> Result<()> {
    Ok(())
}

/// Atomically replaces `path` with `contents`, leaving it private to the user.
pub fn write_atomic(path: &Path, contents: &[u8]) -> Result<()> {
    let parent = path.parent().ok_or_else(|| Error::invalid("Invalid destination."))?;
    ensure_private_dir(parent)?;
    let temporary = parent.join(format!(".tmp-{}", uuid::Uuid::new_v4()));
    let outcome = (|| -> Result<()> {
        std::fs::write(&temporary, contents)?;
        set_private(&temporary, false)?;
        std::fs::rename(&temporary, path)?;
        Ok(())
    })();
    if outcome.is_err() {
        let _ = std::fs::remove_file(&temporary);
    }
    outcome
}

pub fn exe_name(base: &str) -> String {
    if cfg!(windows) {
        format!("{base}.exe")
    } else {
        base.to_string()
    }
}
