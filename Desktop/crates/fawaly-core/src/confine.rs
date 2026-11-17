use crate::Result;
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, HashMap, HashSet};
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
const PROJECT_ENTRY_LIMIT: usize = 200_000;
const HASH_LIMIT: u64 = 8 * 1024 * 1024;
/// Manifest key meaning the scan stopped early, so a change may have gone unseen.
const INCOMPLETE: &str = "(incomplete)";

/// Fingerprints the project's .git and any nested .git. Detection only: it
/// reports changes after they happen.
pub fn git_manifest(workspace: &Path) -> BTreeMap<String, String> {
    scan(workspace, MANIFEST_FILE_LIMIT, PROJECT_ENTRY_LIMIT)
}

fn scan(workspace: &Path, file_limit: usize, entry_limit: usize) -> BTreeMap<String, String> {
    let mut scan = Scan { manifest: BTreeMap::new(), file_limit, entries_left: entry_limit, incomplete: false };
    scan.visit(&workspace.join(".git"), ".git");
    scan.find_nested(workspace, "");
    if scan.incomplete {
        scan.manifest.insert(INCOMPLETE.to_string(), String::new());
    }
    scan.manifest
}

struct Scan {
    manifest: BTreeMap<String, String>,
    file_limit: usize,
    entries_left: usize,
    incomplete: bool,
}

impl Scan {
    fn visit(&mut self, path: &Path, label: &str) {
        if self.manifest.len() >= self.file_limit {
            self.incomplete = true;
            return;
        }
        let Ok(info) = std::fs::symlink_metadata(path) else { return };
        if info.is_dir() {
            self.manifest.insert(format!("{label}/"), "dir".to_string());
            let Ok(entries) = std::fs::read_dir(path) else { return };
            // Bulk stores go last, so a limit never hides config, hooks or refs.
            let mut names: Vec<String> = entries.flatten().map(|entry| entry.file_name().to_string_lossy().to_string()).collect();
            names.sort_by_key(|name| (matches!(name.as_str(), "objects" | "lfs"), name.clone()));
            for name in names {
                self.visit(&path.join(&name), &format!("{label}/{name}"));
            }
        } else if info.file_type().is_symlink() {
            let target = std::fs::read_link(path).map(|value| value.to_string_lossy().to_string()).unwrap_or_default();
            self.manifest.insert(label.to_string(), format!("link:{target}"));
        } else if info.is_file() {
            self.manifest.insert(label.to_string(), file_fingerprint(path, info.len()));
        }
    }

    /// A nested clone has its own hooks and config, and a parent diff never shows them.
    fn find_nested(&mut self, directory: &Path, prefix: &str) {
        let Ok(entries) = std::fs::read_dir(directory) else { return };
        for entry in entries.flatten() {
            if self.entries_left == 0 {
                self.incomplete = true;
                return;
            }
            self.entries_left -= 1;
            let Ok(kind) = entry.file_type() else { continue };
            let name = entry.file_name().to_string_lossy().to_string();
            let label = format!("{prefix}{name}");
            // The name comes first: git obeys a link named .git, and visit records
            // the link without following it. No other link counts as a directory.
            if name.eq_ignore_ascii_case(".git") {
                if !prefix.is_empty() {
                    self.visit(&entry.path(), &label);
                }
            } else if kind.is_dir() {
                self.find_nested(&entry.path(), &format!("{label}/"));
            }
        }
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
    for (path, value) in after.iter().filter(|(path, _)| *path != INCOMPLETE) {
        match before.get(path) {
            None => changes.push(format!("added {path}")),
            Some(old) if old != value => changes.push(format!("changed {path}")),
            _ => {}
        }
    }
    changes.extend(before.keys().filter(|path| *path != INCOMPLETE && !after.contains_key(*path)).map(|path| format!("removed {path}")));
    changes
}

/// True when either scan stopped early, so a change may have gone unseen. Kept
/// apart from the changes, because an incomplete scan is not itself a change.
pub fn manifest_incomplete(before: &BTreeMap<String, String>, after: &BTreeMap<String, String>) -> bool {
    before.contains_key(INCOMPLETE) || after.contains_key(INCOMPLETE)
}

/// Reads a native worker needs on Linux. The home folder is deliberately absent.
pub fn linux_system_read_paths() -> Vec<PathBuf> {
    ["/usr", "/bin", "/sbin", "/lib", "/lib32", "/lib64", "/libx32", "/etc", "/opt", "/proc", "/sys", "/dev", "/run", "/nix", "/snap"]
        .iter()
        .map(PathBuf::from)
        .filter(|path| path.exists())
        .collect()
}

/// Applies Landlock to this process and every process it later starts.
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

/// The parent pid in `/proc/<pid>/stat`. The name is skipped by its last ')',
/// because a process can put spaces and brackets in its own name.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
fn parent_in_stat(stat: &str) -> Option<i32> {
    stat.rsplit_once(')')?.1.split_whitespace().nth(1)?.parse().ok()
}

/// Everything below `root` in a pid-to-parent table.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
fn descendants(parents: &HashMap<i32, i32>, root: i32) -> Vec<i32> {
    let mut seen = HashSet::from([root]);
    let mut found = Vec::new();
    let mut frontier = vec![root];
    while let Some(parent) = frontier.pop() {
        for (pid, owner) in parents {
            if *owner == parent && seen.insert(*pid) {
                found.push(*pid);
                frontier.push(*pid);
            }
        }
    }
    found
}

/// Runs a worker under Landlock and stays as its supervisor. As the subreaper
/// it still finds a child that left the process group with setsid, or whose
/// parent exited, and ends it before the job is treated as finished.
#[cfg(target_os = "linux")]
pub fn run_confined(read: &[PathBuf], write: &[PathBuf], program: &str, arguments: &[String]) -> Result<std::process::ExitCode> {
    use crate::Error;
    use std::os::unix::process::ExitStatusExt;
    use std::process::ExitCode;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::time::Duration;

    const PR_SET_PDEATHSIG: i32 = 1;
    const PR_SET_CHILD_SUBREAPER: i32 = 36;
    const SIGTERM: i32 = 15;
    const SIGKILL: i32 = 9;
    const WNOHANG: i32 = 1;
    const CLEANUP_ROUNDS: usize = 300;

    static TERMINATED: AtomicBool = AtomicBool::new(false);

    unsafe extern "C" {
        fn prctl(option: i32, ...) -> i32;
        fn waitpid(pid: i32, status: *mut i32, options: i32) -> i32;
        safe fn signal(signum: i32, handler: usize) -> usize;
        safe fn kill(pid: i32, signal: i32) -> i32;
    }

    extern "C" fn on_terminate(_signal: i32) {
        TERMINATED.store(true, Ordering::SeqCst);
    }

    fn process_table() -> Option<HashMap<i32, i32>> {
        let mut parents = HashMap::new();
        for entry in std::fs::read_dir("/proc").ok()?.flatten() {
            let Some(pid) = entry.file_name().to_str().and_then(|name| name.parse::<i32>().ok()) else { continue };
            // Lossy, because a process can give itself a name that is not UTF-8.
            let Ok(stat) = std::fs::read(entry.path().join("stat")) else { continue };
            if let Some(parent) = parent_in_stat(&String::from_utf8_lossy(&stat)) {
                parents.insert(pid, parent);
            }
        }
        (!parents.is_empty()).then_some(parents)
    }

    fn end_descendants() -> bool {
        let me = std::process::id() as i32;
        for _ in 0..CLEANUP_ROUNDS {
            let Some(parents) = process_table() else { return false };
            let found = descendants(&parents, me);
            if found.is_empty() {
                return true;
            }
            for pid in found {
                kill(pid, SIGKILL);
            }
            while unsafe { waitpid(-1, std::ptr::null_mut(), WNOHANG) } > 0 {}
            std::thread::sleep(Duration::from_millis(10));
        }
        false
    }

    if unsafe { prctl(PR_SET_CHILD_SUBREAPER, 1_u64) } != 0 {
        return Err(Error::invalid("Sudo Interns could not keep track of the worker's processes."));
    }
    // If the engine dies, this helper still ends the worker and its children.
    unsafe { prctl(PR_SET_PDEATHSIG, SIGTERM as u64) };
    signal(SIGTERM, on_terminate as extern "C" fn(i32) as usize);
    apply_landlock(read, write)?;
    let mut worker = std::process::Command::new(program)
        .args(arguments)
        .spawn()
        .map_err(|error| Error::invalid(format!("Sudo Interns could not start the confined worker: {error}")))?;
    let status = loop {
        if TERMINATED.load(Ordering::SeqCst) {
            break None;
        }
        match worker.try_wait() {
            Ok(Some(status)) => break Some(status),
            Ok(None) => std::thread::sleep(Duration::from_millis(20)),
            Err(_) => break None,
        }
    };
    if !end_descendants() {
        eprintln!("Sudo Interns could not confirm that the worker's processes ended.");
        return Ok(ExitCode::FAILURE);
    }
    Ok(match status {
        Some(status) => ExitCode::from(status.code().unwrap_or_else(|| 128 + status.signal().unwrap_or(0)) as u8),
        None => ExitCode::from(128 + SIGTERM as u8),
    })
}

#[cfg(not(target_os = "linux"))]
pub fn run_confined(_read: &[PathBuf], _write: &[PathBuf], _program: &str, _arguments: &[String]) -> Result<std::process::ExitCode> {
    Err(crate::Error::invalid("Confined launch is available only on Linux."))
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
    fn nested_repositories_are_monitored() {
        let project = tempfile::tempdir().unwrap();
        let hooks = project.path().join("vendor/lib/.git/hooks");
        std::fs::create_dir_all(&hooks).unwrap();
        let before = git_manifest(project.path());
        std::fs::write(hooks.join("post-checkout"), "evil").unwrap();
        std::fs::write(project.path().join("vendor/lib/ordinary.txt"), "fine").unwrap();
        let changes = manifest_changes(&before, &git_manifest(project.path()));
        assert_eq!(changes, vec!["added vendor/lib/.git/hooks/post-checkout".to_string()]);
    }

    #[cfg(unix)]
    #[test]
    fn links_to_another_repository_are_not_followed() {
        let outside = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(outside.path().join(".git/hooks")).unwrap();
        let project = tempfile::tempdir().unwrap();
        std::os::unix::fs::symlink(outside.path(), project.path().join("link")).unwrap();
        assert!(git_manifest(project.path()).is_empty());
    }

    #[cfg(unix)]
    #[test]
    fn a_planted_git_link_is_reported_and_not_followed() {
        let outside = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(outside.path().join("hooks")).unwrap();
        std::fs::write(outside.path().join("config"), "a").unwrap();
        let project = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(project.path().join("src")).unwrap();
        let before = git_manifest(project.path());
        std::os::unix::fs::symlink(outside.path(), project.path().join("src/.git")).unwrap();
        let changes = manifest_changes(&before, &git_manifest(project.path()));
        assert_eq!(changes, vec!["added src/.git".to_string()]);
    }

    #[test]
    fn a_truncated_scan_says_so_and_keeps_config_and_hooks() {
        let project = tempfile::tempdir().unwrap();
        let git = project.path().join(".git");
        std::fs::create_dir_all(git.join("objects")).unwrap();
        std::fs::create_dir_all(git.join("hooks")).unwrap();
        for index in 0..20 {
            std::fs::write(git.join("objects").join(format!("{index}")), "o").unwrap();
        }
        std::fs::write(git.join("config"), "a").unwrap();
        let before = scan(project.path(), 8, PROJECT_ENTRY_LIMIT);
        assert!(before.contains_key(".git/config"), "config comes before objects");
        assert!(before.contains_key(".git/hooks/"), "hooks come before objects");
        assert!(manifest_changes(&before, &before).is_empty(), "an incomplete scan is not a change");
        assert!(manifest_incomplete(&before, &before));
        assert!(!manifest_incomplete(&BTreeMap::new(), &BTreeMap::new()));
    }

    #[test]
    fn a_project_too_large_to_walk_says_so() {
        let project = tempfile::tempdir().unwrap();
        for name in ["a", "b", "c", "d"] {
            std::fs::create_dir_all(project.path().join(name)).unwrap();
        }
        assert!(scan(project.path(), MANIFEST_FILE_LIMIT, 2).contains_key(INCOMPLETE));
        assert!(!scan(project.path(), MANIFEST_FILE_LIMIT, 100).contains_key(INCOMPLETE));
    }

    #[test]
    fn process_parents_survive_hostile_names() {
        assert_eq!(parent_in_stat("42 (sh) S 7 42 42 0"), Some(7));
        assert_eq!(parent_in_stat("42 (a) S 1 2 (b)) R 99 1 1"), Some(99));
        assert_eq!(parent_in_stat("garbage"), None);
    }

    #[test]
    fn descendants_include_every_level_and_nothing_else() {
        let parents = HashMap::from([(2, 1), (3, 2), (4, 3), (5, 9), (1, 0)]);
        let mut found = descendants(&parents, 1);
        found.sort();
        assert_eq!(found, vec![2, 3, 4]);
        assert!(descendants(&HashMap::from([(2, 3), (3, 2)]), 2).contains(&3), "a cycle in a stale table ends");
    }

    #[test]
    fn a_project_without_git_has_an_empty_manifest() {
        let project = tempfile::tempdir().unwrap();
        assert!(git_manifest(project.path()).is_empty());
    }
}
