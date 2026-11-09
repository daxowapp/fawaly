//! Treats a shell as a hostile worker under the same Landlock launch native
//! workers get. A successful write outside the allowed folder fails the test.
#![cfg(target_os = "linux")]

use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::time::Duration;

const ENGINE: &str = env!("CARGO_BIN_EXE_sudo-interns-engine");
const SYSTEM: [&str; 6] = ["/usr", "/bin", "/lib", "/lib64", "/etc", "/proc"];

fn landlock_works() -> bool {
    let works = Command::new(ENGINE).arg("confine-probe").status().unwrap().success();
    assert!(works || std::env::var_os("REQUIRE_LANDLOCK").is_none(), "this runner must enforce Landlock");
    works
}

struct Sandbox {
    _base: tempfile::TempDir,
    allowed: PathBuf,
    outside: PathBuf,
}

fn sandbox() -> Sandbox {
    let base = tempfile::tempdir().unwrap();
    let allowed = base.path().join("allowed");
    let outside = base.path().join("outside");
    std::fs::create_dir_all(&allowed).unwrap();
    std::fs::create_dir_all(&outside).unwrap();
    std::fs::write(outside.join("secret"), "secret").unwrap();
    Sandbox { _base: base, allowed, outside }
}

fn confined(sandbox: &Sandbox, script: &str) -> Command {
    let mut command = Command::new(ENGINE);
    command.arg("confine");
    for path in SYSTEM.iter().filter(|path| Path::new(path).exists()) {
        command.args(["--read", path]);
    }
    command.arg("--write").arg(&sandbox.allowed).args(["--write", "/dev/null"]);
    command.arg("--").args(["/bin/sh", "-c", script]);
    command.env("A", &sandbox.allowed).env("B", &sandbox.outside);
    command
}

fn run(sandbox: &Sandbox, script: &str) -> Output {
    confined(sandbox, script).output().unwrap()
}

/// Starts a daemon in its own session, which a process-group kill cannot reach.
const DAEMON: &str = r#"setsid /bin/sh -c 'echo $$ > "$A/pid.tmp"; mv "$A/pid.tmp" "$A/pid"; sleep 3; echo late > "$A/late"' >/dev/null 2>&1 &"#;
const WAIT_FOR_DAEMON: &str = r#"while [ ! -s "$A/pid" ]; do sleep 0.05; done"#;

fn assert_daemon_ended(sandbox: &Sandbox) {
    let pid = std::fs::read_to_string(sandbox.allowed.join("pid")).unwrap();
    assert!(!Path::new(&format!("/proc/{}", pid.trim())).exists(), "the daemon must be gone when the helper exits");
    std::thread::sleep(Duration::from_secs(4));
    assert!(!sandbox.allowed.join("late").exists(), "the daemon must not write after the job");
}

#[test]
fn a_setsid_child_is_dead_when_the_worker_exits() {
    if !landlock_works() {
        return;
    }
    let sandbox = sandbox();
    let output = run(&sandbox, &format!("{DAEMON}\n{WAIT_FOR_DAEMON}"));
    assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
    assert_daemon_ended(&sandbox);
}

#[test]
fn the_helper_ends_a_setsid_child_when_it_is_terminated() {
    if !landlock_works() {
        return;
    }
    let sandbox = sandbox();
    let mut helper = confined(&sandbox, &format!("{DAEMON}\n{WAIT_FOR_DAEMON}\nsleep 30")).spawn().unwrap();
    while !sandbox.allowed.join("pid").exists() {
        std::thread::sleep(Duration::from_millis(20));
    }
    assert!(Command::new("kill").args(["-TERM", &helper.id().to_string()]).status().unwrap().success());
    assert_eq!(helper.wait().unwrap().code(), Some(143));
    assert_daemon_ended(&sandbox);
}

#[test]
fn the_worker_exit_status_is_passed_on() {
    if !landlock_works() {
        return;
    }
    assert_eq!(run(&sandbox(), "exit 7").status.code(), Some(7));
}

#[test]
fn writes_inside_the_project_work() {
    if !landlock_works() {
        return;
    }
    let sandbox = sandbox();
    let output = run(&sandbox, r#"mkdir "$A/src" && echo hi > "$A/src/file" && cat "$A/src/file""#);
    assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
    assert_eq!(std::fs::read_to_string(sandbox.allowed.join("src/file")).unwrap(), "hi\n");
}

#[test]
fn absolute_and_parent_paths_cannot_write_outside() {
    if !landlock_works() {
        return;
    }
    let sandbox = sandbox();
    for script in [r#"echo x > "$B/absolute""#, r#"cd "$A" && echo x > ../outside/relative"#, r#"mkdir "$B/folder""#, r#"touch "$A/../escaped""#] {
        assert!(!run(&sandbox, script).status.success(), "{script}");
    }
    assert!(!sandbox.outside.join("absolute").exists());
    assert!(!sandbox.outside.join("relative").exists());
    assert!(!sandbox.outside.join("folder").exists());
    assert!(!sandbox.allowed.parent().unwrap().join("escaped").exists());
}

#[test]
fn a_symlink_inside_cannot_reach_outside() {
    if !landlock_works() {
        return;
    }
    let sandbox = sandbox();
    let script = r#"ln -s "$B" "$A/link"; echo x > "$A/link/through""#;
    assert!(!run(&sandbox, script).status.success());
    assert!(!sandbox.outside.join("through").exists());
}

#[test]
fn child_processes_inherit_the_boundary() {
    if !landlock_works() {
        return;
    }
    let sandbox = sandbox();
    let script = r#"/bin/sh -c '/bin/sh -c "echo x > \"$B/nested\""'"#;
    assert!(!run(&sandbox, script).status.success());
    assert!(!sandbox.outside.join("nested").exists());
}

#[test]
fn files_outside_cannot_be_read_or_moved_in() {
    if !landlock_works() {
        return;
    }
    let sandbox = sandbox();
    for script in [r#"cat "$B/secret""#, r#"cp "$B/secret" "$A/copy""#, r#"ln "$B/secret" "$A/alias""#, r#"mv "$B/secret" "$A/moved""#] {
        assert!(!run(&sandbox, script).status.success(), "{script}");
    }
    assert!(sandbox.outside.join("secret").exists(), "the file must stay in place");
    assert!(!sandbox.allowed.join("copy").exists());
    assert!(!sandbox.allowed.join("alias").exists());
    assert!(!sandbox.allowed.join("moved").exists());
}

#[test]
fn inside_files_cannot_be_moved_out() {
    if !landlock_works() {
        return;
    }
    let sandbox = sandbox();
    std::fs::write(sandbox.allowed.join("keep"), "x").unwrap();
    assert!(!run(&sandbox, r#"mv "$A/keep" "$B/keep""#).status.success());
    assert!(sandbox.allowed.join("keep").exists());
}

#[test]
fn the_home_folder_is_not_readable_by_default() {
    if !landlock_works() {
        return;
    }
    let Some(home) = std::env::var_os("HOME") else { return };
    let sandbox = sandbox();
    assert!(!run(&sandbox, &format!("ls '{}'", Path::new(&home).display())).status.success());
}
