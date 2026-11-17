use crate::{Error, Result};
use std::collections::HashSet;
use std::fs::File;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// Set when the MCP client disconnects or the engine is told to shut down, so
/// running workers are not orphaned.
pub static CANCELLED: AtomicBool = AtomicBool::new(false);

/// Makes a shutdown request drain the engine the same way closed input does.
#[cfg(unix)]
pub fn stop_on_shutdown_signals() {
    const SIGINT: i32 = 2;
    const SIGTERM: i32 = 15;
    unsafe extern "C" {
        safe fn signal(signum: i32, handler: usize) -> usize;
    }
    extern "C" fn on_signal(_signal: i32) {
        CANCELLED.store(true, Ordering::SeqCst);
    }
    signal(SIGINT, on_signal as extern "C" fn(i32) as usize);
    signal(SIGTERM, on_signal as extern "C" fn(i32) as usize);
}

/// Makes a shutdown request drain the engine the same way closed input does.
#[cfg(windows)]
pub fn stop_on_shutdown_signals() {
    use windows_sys::Win32::System::Console::SetConsoleCtrlHandler;
    const CTRL_CLOSE_EVENT: u32 = 2;
    const CTRL_LOGOFF_EVENT: u32 = 5;
    const CTRL_SHUTDOWN_EVENT: u32 = 6;
    unsafe extern "system" fn on_control(event: u32) -> i32 {
        CANCELLED.store(true, Ordering::SeqCst);
        // Windows ends the process once this returns for these events, so wait
        // inside the time it allows while the engine saves its jobs and exits.
        if matches!(event, CTRL_CLOSE_EVENT | CTRL_LOGOFF_EVENT | CTRL_SHUTDOWN_EVENT) {
            std::thread::sleep(Duration::from_secs(4));
        }
        1
    }
    unsafe {
        SetConsoleCtrlHandler(Some(on_control), 1);
    }
}

pub const OUTPUT_LIMIT: u64 = 1_048_576;
const LOGIN_OUTPUT_LIMIT: usize = 131_072;
const AUTH_MARKERS: [&str; 5] = ["not logged in", "invalid api key", "failed to authenticate", "authentication failed", "401 unauthorized"];

#[cfg(windows)]
mod group {
    use std::os::windows::io::AsRawHandle;
    use windows_sys::Win32::Foundation::{CloseHandle, HANDLE};
    use windows_sys::Win32::System::JobObjects::*;

    /// A kill-on-close job ends the worker and every process it started.
    pub struct Group(HANDLE);
    unsafe impl Send for Group {}

    impl Group {
        pub fn attach(child: &std::process::Child) -> Option<Self> {
            unsafe {
                let job = CreateJobObjectW(std::ptr::null(), std::ptr::null());
                if job.is_null() {
                    return None;
                }
                let mut limits: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = std::mem::zeroed();
                limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
                let configured = SetInformationJobObject(
                    job,
                    JobObjectExtendedLimitInformation,
                    &limits as *const _ as *const _,
                    std::mem::size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
                );
                if configured == 0 || AssignProcessToJobObject(job, child.as_raw_handle() as HANDLE) == 0 {
                    CloseHandle(job);
                    return None;
                }
                Some(Self(job))
            }
        }

        pub fn kill(&self) {
            unsafe {
                TerminateJobObject(self.0, 1);
            }
        }
    }

    impl Drop for Group {
        fn drop(&mut self) {
            unsafe {
                CloseHandle(self.0);
            }
        }
    }
}

#[cfg(unix)]
mod group {
    pub struct Group(i32);

    unsafe extern "C" {
        safe fn kill(pid: i32, signal: i32) -> i32;
    }

    impl Group {
        pub fn attach(child: &std::process::Child) -> Option<Self> {
            Some(Self(child.id() as i32))
        }

        pub fn kill(&self) {
            kill(-self.0, 9);
        }

        /// Gives the Linux confine helper the chance to end what left the group.
        #[cfg(target_os = "linux")]
        pub fn terminate(&self) {
            kill(-self.0, 15);
        }
    }
}

use group::Group;

fn prepare(command: &mut Command) {
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        command.process_group(0);
    }
    // The kernel ends the worker if the engine dies with no chance to clean up.
    // This follows the spawning thread, which stays in the supervision loop until
    // the worker has ended. The confine helper replaces it with SIGTERM.
    #[cfg(target_os = "linux")]
    {
        use std::os::unix::process::CommandExt;
        const PR_SET_PDEATHSIG: i32 = 1;
        const SIGKILL: u64 = 9;
        const ESRCH: i32 = 3;
        unsafe extern "C" {
            fn prctl(option: i32, ...) -> i32;
            safe fn getppid() -> i32;
        }
        let parent = std::process::id() as i32;
        // Only async-signal-safe calls. The parent check covers an engine that
        // died before the signal was armed.
        unsafe {
            command.pre_exec(move || {
                if prctl(PR_SET_PDEATHSIG, SIGKILL) != 0 || getppid() != parent {
                    return Err(std::io::Error::from_raw_os_error(ESRCH));
                }
                Ok(())
            });
        }
    }
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        command.creation_flags(CREATE_NO_WINDOW);
    }
}

struct Supervised {
    child: Child,
    group: Group,
    reaped: bool,
    ends_gently: bool,
}

impl Supervised {
    /// SIGKILL cannot be caught, so the confine helper is asked first and
    /// allowed to end any child that called setsid.
    #[cfg(target_os = "linux")]
    fn end_gently(&mut self) {
        self.group.terminate();
        let deadline = Instant::now() + Duration::from_secs(2);
        while Instant::now() < deadline {
            match self.child.try_wait() {
                Ok(Some(_)) => {
                    self.reaped = true;
                    return;
                }
                Ok(None) => std::thread::sleep(Duration::from_millis(20)),
                Err(_) => return,
            }
        }
    }

    #[cfg(not(target_os = "linux"))]
    fn end_gently(&mut self) {}
}

impl Drop for Supervised {
    fn drop(&mut self) {
        if self.ends_gently && !self.reaped {
            self.end_gently();
        }
        self.group.kill();
        if !self.reaped {
            let _ = self.child.kill();
            let _ = self.child.wait();
        }
    }
}

fn supervise(mut child: Child, ends_gently: bool) -> Result<Supervised> {
    match Group::attach(&child) {
        Some(group) => Ok(Supervised { child, group, reaped: false, ends_gently }),
        None => {
            let _ = child.kill();
            let _ = child.wait();
            Err(Error::invalid("The worker process could not be supervised, so it was stopped."))
        }
    }
}

pub struct WorkerSpec {
    pub program: PathBuf,
    pub arguments: Vec<String>,
    pub environment: Vec<(String, String)>,
    /// Private folder receiving brief.txt, stdout and stderr.
    pub directory: PathBuf,
    pub prompt: String,
    pub timeout: u64,
    pub stop_file: Option<PathBuf>,
}

fn create_new(path: &Path) -> Result<File> {
    Ok(std::fs::OpenOptions::new().read(true).write(true).create_new(true).open(path)?)
}

fn bounded_read(path: &Path) -> Vec<u8> {
    let mut data = Vec::new();
    if let Ok(file) = File::open(path) {
        let _ = file.take(OUTPUT_LIMIT + 1).read_to_end(&mut data);
    }
    data
}

fn length(path: &Path) -> u64 {
    std::fs::metadata(path).map_or(0, |info| info.len())
}

pub fn run_worker(spec: &WorkerSpec) -> Result<Vec<u8>> {
    let launch = |_| Error::invalid("Sudo Interns could not start the worker process.");
    let brief = spec.directory.join("brief.txt");
    let stdout_path = spec.directory.join("stdout");
    let stderr_path = spec.directory.join("stderr");
    create_new(&brief)?.write_all(spec.prompt.as_bytes())?;
    let stdin = File::open(&brief)?;
    let stdout = create_new(&stdout_path)?;
    let stderr = create_new(&stderr_path)?;
    if CANCELLED.load(Ordering::Relaxed) {
        return Err(Error::Cancelled);
    }
    if spec.stop_file.as_deref().is_some_and(Path::exists) {
        return Err(Error::Stopped);
    }
    let mut command = Command::new(&spec.program);
    command
        .args(&spec.arguments)
        .env_clear()
        .envs(spec.environment.iter().map(|(key, value)| (key, value)))
        .current_dir(&spec.directory)
        .stdin(Stdio::from(stdin))
        .stdout(Stdio::from(stdout))
        .stderr(Stdio::from(stderr));
    prepare(&mut command);
    let mut process = supervise(command.spawn().map_err(launch)?, true)?;
    let deadline = Instant::now() + Duration::from_secs(spec.timeout.clamp(1, 3600));
    let status = loop {
        match process.child.try_wait() {
            Ok(Some(status)) => {
                process.reaped = true;
                // A worker may have left children in its group.
                process.group.kill();
                break status;
            }
            Ok(None) => {}
            Err(_) => return Err(Error::invalid("Sudo Interns lost the worker process.")),
        }
        if CANCELLED.load(Ordering::Relaxed) {
            return Err(Error::Cancelled);
        }
        if spec.stop_file.as_deref().is_some_and(Path::exists) {
            return Err(Error::Stopped);
        }
        if Instant::now() >= deadline {
            return Err(Error::invalid("The worker exceeded its time limit."));
        }
        if length(&stdout_path) > OUTPUT_LIMIT || length(&stderr_path) > OUTPUT_LIMIT {
            return Err(Error::invalid("The worker exceeded its output limit."));
        }
        std::thread::sleep(Duration::from_millis(100));
    };
    if length(&stdout_path) > OUTPUT_LIMIT || length(&stderr_path) > OUTPUT_LIMIT {
        return Err(Error::invalid("The worker exceeded its output limit."));
    }
    let output = bounded_read(&stdout_path);
    if !status.success() {
        // The engine's own stops return above, so something else killed it, and
        // whatever it would have cleaned up on the way out is still there.
        #[cfg(unix)]
        if std::os::unix::process::ExitStatusExt::signal(&status) == Some(9) {
            return Err(Error::invalid("The worker was killed before it finished, and processes it started may still be running. Review the workspace and .git, and check again before trusting them."));
        }
        let detail = String::from_utf8_lossy(&bounded_read(&stderr_path)).to_lowercase();
        if detail.contains("landlock") && detail.contains("sudo interns") {
            return Err(Error::invalid("The worker file boundary could not be applied. The request was stopped."));
        }
        let response = String::from_utf8_lossy(&output).to_lowercase();
        let combined = detail + &response;
        let api_status = serde_json::from_slice::<serde_json::Value>(&output).ok().and_then(|value| value.get("api_error_status").and_then(serde_json::Value::as_i64));
        if api_status == Some(401) || AUTH_MARKERS.iter().any(|marker| combined.contains(marker)) {
            return Err(Error::WorkerAuthentication);
        }
        return Err(Error::invalid("The worker exited before returning a result. Check its isolated sign-in and CLI version."));
    }
    Ok(output)
}

#[derive(Clone)]
pub struct LoginCommand {
    pub executable: PathBuf,
    pub arguments: Vec<String>,
    pub environment: Vec<(String, String)>,
    pub directory: PathBuf,
    pub input: Option<String>,
}

#[derive(Clone, Debug, Default)]
pub struct LoginReply {
    pub exit_code: i32,
    pub output: String,
    pub error_output: String,
}

fn pump<R: Read + Send + 'static>(mut source: R, sink: Arc<Mutex<Vec<u8>>>) -> std::thread::JoinHandle<()> {
    std::thread::spawn(move || {
        let mut buffer = [0_u8; 16_384];
        while let Ok(count) = source.read(&mut buffer) {
            if count == 0 {
                return;
            }
            let mut data = sink.lock().unwrap();
            let room = LOGIN_OUTPUT_LIMIT.saturating_sub(data.len());
            data.extend_from_slice(&buffer[..count.min(room)]);
        }
    })
}

pub type UrlCallback<'a> = &'a (dyn Fn(String) + Send + Sync);

pub fn run_login(command: &LoginCommand, timeout: Duration, cancel: &AtomicBool, on_url: UrlCallback<'_>) -> Result<LoginReply> {
    let launch = |_| Error::invalid("The sign-in process could not be started or monitored.");
    let mut process = Command::new(&command.executable);
    process
        .args(&command.arguments)
        .env_clear()
        .envs(command.environment.iter().map(|(key, value)| (key, value)))
        .current_dir(&command.directory)
        .stdin(if command.input.is_some() { Stdio::piped() } else { Stdio::null() })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    prepare(&mut process);
    let mut supervised = supervise(process.spawn().map_err(launch)?, false)?;
    if let (Some(input), Some(mut stdin)) = (command.input.clone(), supervised.child.stdin.take()) {
        std::thread::spawn(move || {
            let _ = stdin.write_all(input.as_bytes());
        });
    }
    let out = Arc::new(Mutex::new(Vec::new()));
    let err = Arc::new(Mutex::new(Vec::new()));
    let out_thread = pump(supervised.child.stdout.take().ok_or_else(|| Error::invalid("The sign-in output was unavailable."))?, out.clone());
    let err_thread = pump(supervised.child.stderr.take().ok_or_else(|| Error::invalid("The sign-in output was unavailable."))?, err.clone());
    let deadline = Instant::now() + timeout.min(Duration::from_secs(3600));
    let mut delivered = HashSet::new();
    let text_of = |data: &Arc<Mutex<Vec<u8>>>| String::from_utf8_lossy(&data.lock().unwrap()).to_string();
    let status = loop {
        for url in browser_urls(&format!("{}\n{}", text_of(&out), text_of(&err))) {
            if delivered.insert(url.clone()) {
                on_url(url);
            }
        }
        match supervised.child.try_wait() {
            Ok(Some(status)) => {
                supervised.reaped = true;
                supervised.group.kill();
                break status;
            }
            Ok(None) => {}
            Err(_) => return Err(Error::invalid("The sign-in process could not be started or monitored.")),
        }
        if cancel.load(Ordering::Relaxed) {
            return Err(Error::Cancelled);
        }
        if Instant::now() >= deadline {
            return Err(Error::invalid("Sign-in timed out. Please try again."));
        }
        std::thread::sleep(Duration::from_millis(50));
    };
    let _ = out_thread.join();
    let _ = err_thread.join();
    Ok(LoginReply { exit_code: status.code().unwrap_or(128), output: text_of(&out), error_output: text_of(&err) })
}

const SIGN_IN_HOSTS: [&str; 11] = [
    "auth.openai.com",
    "chatgpt.com",
    "claude.ai",
    "console.anthropic.com",
    "platform.claude.com",
    "auth.kimi.com",
    "auth.kimi.ai",
    "www.kimi.com",
    "www.kimi.ai",
    "kimi.com",
    "kimi.ai",
];

/// Only official provider sign-in pages are ever offered to the browser.
pub fn browser_urls(text: &str) -> Vec<String> {
    let mut found = Vec::new();
    let mut rest = text;
    while let Some(start) = rest.find("https://") {
        let tail = &rest[start..];
        let end = tail.find(|c: char| c.is_whitespace() || c == '\u{1b}' || c == '<' || c == '>' || c == '"').unwrap_or(tail.len());
        let candidate = &tail[..end];
        if let Ok(url) = url::Url::parse(candidate) {
            let official = url.host_str().is_some_and(|host| SIGN_IN_HOSTS.contains(&host.to_lowercase().as_str()));
            if official && url.username().is_empty() && url.password().is_none() {
                found.push(candidate.to_string());
            }
        }
        rest = &tail[end..];
    }
    found
}

/// Baseline variables a CLI needs on this OS. Nothing else is inherited.
pub fn base_environment(home: &Path) -> Vec<(String, String)> {
    let mut values = Vec::new();
    let home_text = home.to_string_lossy().to_string();
    if cfg!(windows) {
        for key in ["SystemRoot", "windir", "ComSpec", "PATHEXT", "SystemDrive", "ProgramData", "ProgramFiles", "ProgramFiles(x86)", "ProgramW6432", "NUMBER_OF_PROCESSORS", "PROCESSOR_ARCHITECTURE", "OS", "PATH", "APPDATA", "LOCALAPPDATA", "HOMEDRIVE", "HOMEPATH"] {
            if let Ok(value) = std::env::var(key) {
                values.push((key.to_string(), value));
            }
        }
        values.push(("USERPROFILE".to_string(), home_text.clone()));
    } else {
        values.push(("PATH".to_string(), "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin".to_string()));
        for key in ["LANG", "LC_ALL", "XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS", "DISPLAY", "WAYLAND_DISPLAY"] {
            if let Ok(value) = std::env::var(key) {
                values.push((key.to_string(), value));
            }
        }
    }
    values.push(("HOME".to_string(), home_text));
    values.push(("TERM".to_string(), "dumb".to_string()));
    values
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_official_sign_in_hosts_are_opened() {
        let text = "Open https://auth.openai.com/oauth?x=1 or https://evil.example/phish and https://claude.ai/login\x1b[0m";
        assert_eq!(browser_urls(text), vec!["https://auth.openai.com/oauth?x=1".to_string(), "https://claude.ai/login".to_string()]);
    }

    #[test]
    fn urls_with_credentials_are_refused() {
        assert!(browser_urls("https://user@claude.ai/login").is_empty());
    }

    #[cfg(unix)]
    #[test]
    fn worker_timeout_kills_the_process_group() {
        let directory = tempfile::tempdir().unwrap();
        let marker = directory.path().join("still-alive");
        let script = format!("(sleep 3; touch '{}') & sleep 30", marker.display());
        let spec = WorkerSpec {
            program: "/bin/sh".into(),
            arguments: vec!["-c".into(), script],
            environment: vec![("PATH".into(), "/usr/bin:/bin".into())],
            directory: directory.path().to_path_buf(),
            prompt: "x".into(),
            timeout: 1,
            stop_file: None,
        };
        assert!(run_worker(&spec).unwrap_err().to_string().contains("time limit"));
        std::thread::sleep(Duration::from_secs(3));
        assert!(!marker.exists(), "child in the worker's process group must be killed");
    }

    #[cfg(unix)]
    #[test]
    fn a_worker_killed_outright_warns_about_what_it_left_running() {
        let directory = tempfile::tempdir().unwrap();
        let spec = WorkerSpec {
            program: "/bin/sh".into(),
            arguments: vec!["-c".into(), "kill -9 $$".into()],
            environment: vec![],
            directory: directory.path().to_path_buf(),
            prompt: "x".into(),
            timeout: 30,
            stop_file: None,
        };
        assert!(run_worker(&spec).unwrap_err().to_string().contains("may still be running"));
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn a_worker_does_not_outlive_the_thread_supervising_it() {
        use std::os::unix::process::ExitStatusExt;
        let mut child = std::thread::spawn(|| {
            let mut command = Command::new("/bin/sleep");
            command.arg("30");
            prepare(&mut command);
            command.spawn().unwrap()
        })
        .join()
        .unwrap();
        let deadline = Instant::now() + Duration::from_secs(10);
        let status = loop {
            if let Some(status) = child.try_wait().unwrap() {
                break status;
            }
            assert!(Instant::now() < deadline, "the parent-death signal never arrived");
            std::thread::sleep(Duration::from_millis(20));
        };
        assert_eq!(status.signal(), Some(9));
    }

    #[cfg(unix)]
    #[test]
    fn stop_file_stops_a_running_worker() {
        let directory = tempfile::tempdir().unwrap();
        let stop = directory.path().join("stop");
        std::fs::write(&stop, "x").unwrap();
        let spec = WorkerSpec {
            program: "/bin/sh".into(),
            arguments: vec!["-c".into(), "sleep 30".into()],
            environment: vec![],
            directory: directory.path().to_path_buf(),
            prompt: "x".into(),
            timeout: 30,
            stop_file: Some(stop),
        };
        assert!(matches!(run_worker(&spec), Err(Error::Stopped)));
    }
}
