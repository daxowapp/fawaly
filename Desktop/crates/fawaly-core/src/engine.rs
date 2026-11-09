use crate::http::{self, Transport};
use crate::model::Agent;
use crate::secrets::{SecretStore, SystemSecrets};
use crate::store::ApiAssistantStore;
use crate::{paths, Error, Result};
use sha2::{Digest, Sha256};
use std::fs::{File, OpenOptions, TryLockError};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use uuid::Uuid;

pub const CLAUDE_TOKEN_ACCOUNT: &str = "claude-setup-token";

#[derive(Clone)]
pub struct Engine {
    pub root: PathBuf,
    pub home: PathBuf,
    pub secrets: Arc<dyn SecretStore>,
    pub transport: Transport,
    /// The console engine used to apply OS confinement to native workers.
    pub helper: Option<PathBuf>,
}

impl Engine {
    pub fn live() -> Result<Self> {
        Ok(Self::with(paths::data_root()?, paths::home()?, Arc::new(SystemSecrets)))
    }

    pub fn with(root: PathBuf, home: PathBuf, secrets: Arc<dyn SecretStore>) -> Self {
        Self { root, home, secrets, transport: http::live(), helper: None }
    }

    pub fn auth_dir(&self, agent: Agent) -> PathBuf {
        self.root.join("official").join(agent.raw())
    }

    pub fn runtime_dir(&self, agent: Agent) -> PathBuf {
        self.root.join("runtimes").join(agent.raw())
    }

    fn managed_candidates(&self, agent: Agent) -> Vec<PathBuf> {
        let directory = self.runtime_dir(agent);
        let name = paths::exe_name(agent.raw());
        vec![directory.join(&name), directory.join("bin").join(&name)]
    }

    /// `.cmd`/`.bat` shims are skipped on Windows; they cannot be launched without a shell.
    pub fn executable(&self, agent: Agent) -> Option<PathBuf> {
        if !agent.is_native() {
            return None;
        }
        let name = paths::exe_name(agent.raw());
        let mut candidates = self.managed_candidates(agent);
        if agent != Agent::Kimi {
            candidates.push(self.home.join(".local").join("bin").join(&name));
            if cfg!(unix) {
                candidates.push(PathBuf::from("/usr/local/bin").join(&name));
                candidates.push(PathBuf::from("/usr/bin").join(&name));
            }
            if let Ok(found) = which::which(&name) {
                candidates.push(found);
            }
        }
        candidates
            .into_iter()
            .find(|path| path.is_file() && path.to_string_lossy().to_lowercase().ends_with(&name.to_lowercase()))
            .map(|path| dunce::canonicalize(&path).unwrap_or(path))
    }

    pub fn is_ready(&self, agent: Agent) -> bool {
        if !agent.is_native() {
            let Ok(Some(assistant)) = ApiAssistantStore::new(&self.root).load(agent) else {
                return false;
            };
            if !assistant.enabled {
                return false;
            }
            return assistant.is_local() || matches!(self.secrets.get(&assistant.key_account()), Ok(Some(_)));
        }
        if self.requires_sign_in(agent) || self.executable(agent).is_none() {
            return false;
        }
        match agent {
            Agent::Codex => {
                let auth = self.auth_dir(Agent::Codex).join("auth.json");
                std::fs::symlink_metadata(auth).is_ok_and(|info| info.is_file() && info.len() > 0)
            }
            Agent::Claude => self.has_sign_in(Agent::Claude) || matches!(self.secrets.get(CLAUDE_TOKEN_ACCOUNT), Ok(Some(_))),
            Agent::Kimi => self.has_sign_in(Agent::Kimi) && crate::native::kimi_has_credentials(&self.auth_dir(Agent::Kimi)),
            _ => false,
        }
    }

    pub fn requires_sign_in(&self, agent: Agent) -> bool {
        match std::fs::read(self.auth_dir(agent).join("fawaly-reauth-required.json")) {
            Ok(data) => serde_json::from_slice::<bool>(&data).unwrap_or(true),
            Err(error) => error.kind() != std::io::ErrorKind::NotFound,
        }
    }

    pub fn set_requires_sign_in(&self, agent: Agent, required: bool) -> Result<()> {
        if !agent.is_native() {
            return Ok(());
        }
        paths::write_atomic(&self.auth_dir(agent).join("fawaly-reauth-required.json"), serde_json::to_string(&required)?.as_bytes())
    }

    pub fn has_sign_in(&self, agent: Agent) -> bool {
        std::fs::read(self.auth_dir(agent).join("fawaly-verified.json"))
            .ok()
            .and_then(|data| serde_json::from_slice::<serde_json::Value>(&data).ok())
            .and_then(|value| value.get("connected").and_then(serde_json::Value::as_bool))
            .unwrap_or(false)
    }

    pub fn record_sign_in(&self, agent: Agent, connected: bool) -> Result<()> {
        let record = serde_json::json!({"connected": connected, "checked": chrono::Utc::now()});
        paths::write_atomic(&self.auth_dir(agent).join("fawaly-verified.json"), &serde_json::to_vec(&record)?)
    }

    fn workspaces_file(&self) -> PathBuf {
        self.root.join("engine-workspaces.json")
    }

    fn read_workspaces(&self) -> Result<Vec<String>> {
        match std::fs::read(self.workspaces_file()) {
            Ok(data) => Ok(serde_json::from_slice(&data)?),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(Vec::new()),
            Err(error) => Err(error.into()),
        }
    }

    pub fn workspaces(&self) -> Result<Vec<String>> {
        self.read_workspaces()
    }

    fn canonical_workspace(&self, path: &str) -> Result<PathBuf> {
        let rejected = || Error::invalid("Choose a specific, existing project folder.");
        let requested = Path::new(path);
        if !requested.is_absolute() {
            return Err(rejected());
        }
        let directory = dunce::canonicalize(requested).map_err(|_| rejected())?;
        if !directory.is_dir() {
            return Err(rejected());
        }
        let home = dunce::canonicalize(&self.home).unwrap_or_else(|_| self.home.clone());
        let own_state = dunce::canonicalize(&self.root).unwrap_or_else(|_| self.root.clone());
        let broad = [
            home.clone(),
            home.join("Documents"),
            home.join("Desktop"),
            home.join("Downloads"),
            home.join("AppData"),
            home.join(".config"),
            home.join(".local"),
        ];
        let sensitive = [home.join(".codex"), home.join(".claude"), home.join(".ssh"), home.join("AppData"), home.join(".gnupg"), own_state.clone()];
        let inside = |base: &Path| same_or_under(&directory, base);
        let is_ancestor_of_state = own_state.starts_with(&directory) && own_state != directory;
        let mounted = allowed_outside_home(&directory);
        if broad.iter().any(|path| same_path(path, &directory))
            || directory.parent().is_none()
            || sensitive.iter().any(|path| inside(path))
            || is_ancestor_of_state
            || !(inside(&home) || mounted)
        {
            return Err(rejected());
        }
        Ok(directory)
    }

    pub fn approved_workspace(&self, path: &str) -> Result<PathBuf> {
        let directory = self.canonical_workspace(path)?;
        if self.read_workspaces()?.iter().any(|known| same_path(Path::new(known), &directory)) {
            Ok(directory)
        } else {
            Err(Error::invalid("Workspace access is off. Choose and approve this project folder from the Sudo Interns home screen first."))
        }
    }

    pub fn allow_workspace(&self, path: &str) -> Result<PathBuf> {
        let directory = self.canonical_workspace(path)?;
        let _lock = self.lock_job()?;
        let mut current = self.read_workspaces()?;
        let text = directory.to_string_lossy().to_string();
        if !current.contains(&text) {
            current.push(text);
            current.sort();
        }
        paths::write_atomic(&self.workspaces_file(), &serde_json::to_vec(&current)?)?;
        Ok(directory)
    }

    pub fn deny_workspace(&self, path: &str) -> Result<()> {
        let target = dunce::canonicalize(path).unwrap_or_else(|_| PathBuf::from(path));
        let _lock = self.lock_job()?;
        let current: Vec<String> = self.read_workspaces()?.into_iter().filter(|known| !same_path(Path::new(known), &target)).collect();
        paths::write_atomic(&self.workspaces_file(), &serde_json::to_vec(&current)?)
    }

    fn open_lock(&self, path: &Path) -> Result<File> {
        if let Some(parent) = path.parent() {
            paths::ensure_private_dir(parent)?;
        }
        Ok(OpenOptions::new().create(true).truncate(false).read(true).write(true).open(path)?)
    }

    pub fn lock_worker_access(&self) -> Result<File> {
        let file = self.open_lock(&self.root.join("engine.lock"))?;
        match file.try_lock_shared() {
            Ok(()) => Ok(file),
            Err(TryLockError::WouldBlock) => Err(Error::invalid("Sudo Interns is changing its configuration. Retry after setup finishes.")),
            Err(TryLockError::Error(error)) => Err(error.into()),
        }
    }

    pub fn lock_job(&self) -> Result<File> {
        let file = self.open_lock(&self.root.join("engine.lock"))?;
        match file.try_lock() {
            Ok(()) => Ok(file),
            Err(TryLockError::WouldBlock) => Err(Error::invalid("The engine is already running a job. Retry after it finishes.")),
            Err(TryLockError::Error(error)) => Err(error.into()),
        }
    }

    fn agent_lock_path(&self, agent: Agent) -> PathBuf {
        self.root.join("work-locks").join(format!("agent-{}.lock", agent.raw()))
    }

    pub fn lock_worker(&self, agent: Agent, workspace: Option<&Path>) -> Result<Vec<File>> {
        let mut names = vec![self.agent_lock_path(agent)];
        if let Some(workspace) = workspace {
            let identity = dunce::canonicalize(workspace).unwrap_or_else(|_| workspace.to_path_buf());
            let text = identity.to_string_lossy().to_lowercase();
            names.push(self.root.join("work-locks").join(format!("project-{}.lock", hex::encode(Sha256::digest(text.as_bytes())))));
        }
        let mut held = Vec::new();
        for path in names {
            let file = self.open_lock(&path)?;
            match file.try_lock() {
                Ok(()) => held.push(file),
                Err(TryLockError::WouldBlock) => return Err(Error::invalid("This assistant or project is already in use. Retry when its current task finishes.")),
                Err(TryLockError::Error(error)) => return Err(error.into()),
            }
        }
        Ok(held)
    }

    pub fn is_working(&self, agent: Agent) -> bool {
        let Ok(file) = OpenOptions::new().read(true).write(true).open(self.agent_lock_path(agent)) else {
            return false;
        };
        matches!(file.try_lock(), Err(TryLockError::WouldBlock))
    }

    pub fn stop_file(&self, job: Uuid) -> PathBuf {
        self.root.join("stops").join(job.to_string())
    }

    pub fn request_stop(&self, job: Uuid, primary: Agent) -> Result<()> {
        let record = crate::log::TeamJobLog::new(&self.root)
            .get(job)?
            .filter(|record| record.primary == Some(primary) && record.status == "running")
            .ok_or_else(|| Error::invalid("Choose a running job from this primary."))?;
        paths::write_atomic(&self.stop_file(record.id), b"stop")
    }
}

fn normalize(path: &Path) -> String {
    let text = path.to_string_lossy().replace('\\', "/");
    let text = text.trim_end_matches('/').to_string();
    if cfg!(windows) {
        text.to_lowercase()
    } else {
        text
    }
}

pub fn same_path(left: &Path, right: &Path) -> bool {
    normalize(left) == normalize(right)
}

pub fn same_or_under(path: &Path, base: &Path) -> bool {
    let (path, base) = (normalize(path), normalize(base));
    path == base || path.starts_with(&format!("{base}/"))
}

/// Project folders on other drives or standard Linux mount points.
#[cfg(windows)]
fn allowed_outside_home(directory: &Path) -> bool {
    let text = normalize(directory);
    let system = ["c:/windows", "c:/program files", "c:/program files (x86)", "c:/programdata"];
    !system.iter().any(|root| text == *root || text.starts_with(&format!("{root}/"))) && text.len() > 3 && !text.starts_with("//")
}

#[cfg(not(windows))]
fn allowed_outside_home(directory: &Path) -> bool {
    ["/mnt/", "/media/", "/srv/", "/workspace/", "/Volumes/"].iter().any(|root| directory.to_string_lossy().starts_with(root))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::secrets::MemorySecrets;

    fn setup() -> (tempfile::TempDir, Engine) {
        let base = tempfile::tempdir().unwrap();
        let home = dunce::canonicalize(base.path()).unwrap().join("home");
        std::fs::create_dir_all(home.join("Documents")).unwrap();
        std::fs::create_dir_all(home.join(".ssh")).unwrap();
        std::fs::create_dir_all(home.join("code/project")).unwrap();
        let root = home.join(".local/share/SudoInterns");
        std::fs::create_dir_all(&root).unwrap();
        (base, Engine::with(root, home, Arc::new(MemorySecrets::default())))
    }

    #[test]
    fn approval_is_required_for_each_project() {
        let (_base, engine) = setup();
        let project = engine.home.join("code/project");
        let text = project.to_string_lossy().to_string();
        assert!(engine.approved_workspace(&text).is_err());
        engine.allow_workspace(&text).unwrap();
        assert!(engine.approved_workspace(&text).is_ok());
        engine.deny_workspace(&text).unwrap();
        assert!(engine.approved_workspace(&text).is_err());
    }

    #[test]
    fn broad_and_sensitive_folders_cannot_be_approved() {
        let (_base, engine) = setup();
        for folder in [engine.home.clone(), engine.home.join("Documents"), engine.home.join(".ssh"), engine.root.clone()] {
            assert!(engine.allow_workspace(&folder.to_string_lossy()).is_err(), "{}", folder.display());
        }
        assert!(engine.allow_workspace("relative/path").is_err());
    }

    #[test]
    fn a_folder_holding_app_data_cannot_be_approved() {
        let (_base, engine) = setup();
        assert!(engine.allow_workspace(&engine.home.join(".local/share").to_string_lossy()).is_err());
    }

    #[test]
    fn worker_locks_exclude_a_second_job() {
        let (_base, engine) = setup();
        let project = engine.home.join("code/project");
        let held = engine.lock_worker(Agent::Kimi, Some(&project)).unwrap();
        assert!(engine.is_working(Agent::Kimi));
        assert!(engine.lock_worker(Agent::Codex, Some(&project)).is_err(), "same project");
        drop(held);
        assert!(!engine.is_working(Agent::Kimi));
    }

    #[test]
    fn reauth_marker_fails_closed_when_corrupt() {
        let (_base, engine) = setup();
        assert!(!engine.requires_sign_in(Agent::Claude));
        crate::paths::write_atomic(&engine.auth_dir(Agent::Claude).join("fawaly-reauth-required.json"), b"garbage").unwrap();
        assert!(engine.requires_sign_in(Agent::Claude));
    }
}
