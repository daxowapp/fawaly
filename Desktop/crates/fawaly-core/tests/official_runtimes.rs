//! Downloads the real Codex, Claude Code and Kimi CLIs and runs them. Network
//! heavy, so it is ignored by default and run on purpose in CI.

use fawaly_core::installer;
use fawaly_core::model::Agent;
use fawaly_core::secrets::MemorySecrets;
use fawaly_core::Engine;
use std::sync::atomic::AtomicBool;
use std::sync::Arc;

#[test]
#[ignore = "downloads official CLIs"]
fn every_official_cli_installs_and_runs_on_this_system() {
    let base = tempfile::tempdir().unwrap();
    let engine = Engine::with(base.path().join("data"), base.path().join("home"), Arc::new(MemorySecrets::default()));
    std::fs::create_dir_all(&engine.home).unwrap();
    let never = AtomicBool::new(false);
    let mut failures = Vec::new();
    for agent in Agent::NATIVE {
        match installer::install(&engine, agent, &never) {
            Ok(path) => println!("{}: installed and ran --version at {}", agent.label(), path.display()),
            Err(error) => failures.push(format!("{}: {error}", agent.label())),
        }
    }
    assert!(failures.is_empty(), "{failures:#?}");
}
