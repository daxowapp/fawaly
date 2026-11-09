//! Console engine started by Codex or Claude Code over MCP stdio.

use fawaly_core::bridge::Bridge;
use fawaly_core::client_link::{self, ClientLink};
use fawaly_core::confine;
use fawaly_core::mcp::Server;
use fawaly_core::model::Agent;
use fawaly_core::secrets::{SecretStore, SystemSecrets};
use fawaly_core::{native, process, Engine, Error, Result};
use std::io::BufReader;
use std::path::PathBuf;
use std::process::ExitCode;

const USAGE: &str = "Usage: sudo-interns-engine mcp --client codex|claude, status, version, allow-workspace PATH, deny-workspace PATH, disconnect, confine-probe";

/// Agent apps start MCP servers with a trimmed environment. The stable launcher
/// sits inside the data folder, so it can find its data without those variables.
fn locate_data_root() {
    if std::env::var_os("SUDO_INTERNS_DATA_DIR").is_some() {
        return;
    }
    let root = std::env::current_exe().ok().and_then(|exe| exe.parent()?.parent().map(PathBuf::from));
    if let Some(root) = root.filter(|root| root.join(client_link::ROOT_MARKER).is_file()) {
        // Runs before any thread starts.
        unsafe { std::env::set_var("SUDO_INTERNS_DATA_DIR", root) };
    }
}

/// libdbus finds the session keyring through this variable, which agents often drop.
#[cfg(target_os = "linux")]
fn locate_session_bus() {
    if std::env::var_os("DBUS_SESSION_BUS_ADDRESS").is_some() {
        return;
    }
    unsafe extern "C" {
        safe fn getuid() -> u32;
    }
    let bus = PathBuf::from(format!("/run/user/{}/bus", getuid()));
    if bus.exists() {
        // Runs before any thread starts.
        unsafe { std::env::set_var("DBUS_SESSION_BUS_ADDRESS", format!("unix:path={}", bus.display())) };
    }
}

#[cfg(not(target_os = "linux"))]
fn locate_session_bus() {}

fn engine() -> Result<Engine> {
    let mut engine = Engine::live()?;
    engine.helper = std::env::current_exe().ok();
    Ok(engine)
}

fn run(arguments: &[String]) -> Result<ExitCode> {
    match arguments.first().map(String::as_str) {
        Some("mcp") => {
            let client = match arguments.get(1..).unwrap_or_default() {
                [] => None,
                [flag, value] if flag == "--client" => Some(Agent::from_provider(value).filter(|agent| agent.is_primary()).ok_or_else(|| Error::invalid("Use: sudo-interns-engine mcp --client codex|claude"))?),
                _ => return Err(Error::invalid("Use: sudo-interns-engine mcp --client codex|claude")),
            };
            let bridge = Bridge::new(engine()?, client);
            process::stop_on_shutdown_signals();
            native::sweep_stale_worker_folders();
            // Bookkeeping about a past crash must not stop this session from starting.
            let _ = bridge.mark_interrupted_jobs();
            Server::new(bridge).serve(BufReader::new(std::io::stdin()), std::io::stdout());
            Ok(ExitCode::SUCCESS)
        }
        Some("status") => {
            println!("{}", serde_json::to_string(&Bridge::new(engine()?, None).status()?).map_err(|_| Error::invalid("Invalid engine result."))?);
            Ok(ExitCode::SUCCESS)
        }
        Some("version") => {
            println!("{}", fawaly_core::VERSION);
            Ok(ExitCode::SUCCESS)
        }
        Some("allow-workspace") if arguments.len() == 2 => {
            println!("Allowed workspace: {}", engine()?.allow_workspace(&arguments[1])?.display());
            Ok(ExitCode::SUCCESS)
        }
        Some("deny-workspace") if arguments.len() == 2 => {
            engine()?.deny_workspace(&arguments[1])?;
            println!("Workspace removed from the allowlist.");
            Ok(ExitCode::SUCCESS)
        }
        Some("disconnect") => {
            // Called by the uninstaller. Never blocks removal of the app.
            let link = ClientLink::new(engine()?);
            for primary in Agent::PRIMARY {
                let _ = link.disconnect(primary);
            }
            Ok(ExitCode::SUCCESS)
        }
        // Used by CI to exercise the real secret store, with a throwaway value.
        Some("secrets-probe") => {
            let store = SystemSecrets;
            store.set("ci-probe", "not-a-real-key")?;
            let value = store.get("ci-probe")?;
            store.delete("ci-probe")?;
            if value.as_deref() != Some("not-a-real-key") || store.get("ci-probe")?.is_some() {
                return Err(Error::invalid("The system secret store did not round-trip the value."));
            }
            println!("ok");
            Ok(ExitCode::SUCCESS)
        }
        Some("confine-probe") => {
            confine::apply_landlock(&confine::linux_system_read_paths(), &[])?;
            Ok(ExitCode::SUCCESS)
        }
        Some("confine") => confine_worker(&arguments[1..]),
        Some("--help") => {
            println!("{USAGE}");
            Ok(ExitCode::SUCCESS)
        }
        _ => {
            println!("{USAGE}");
            Ok(ExitCode::from(64))
        }
    }
}

/// Runs the worker inside the file boundary and outlives it to end its children.
fn confine_worker(arguments: &[String]) -> Result<ExitCode> {
    let mut read = Vec::new();
    let mut write = Vec::new();
    let mut index = 0;
    while index < arguments.len() && arguments[index] != "--" {
        let value = arguments.get(index + 1).map(PathBuf::from).ok_or_else(|| Error::invalid(USAGE))?;
        match arguments[index].as_str() {
            "--read" => read.push(value),
            "--write" => write.push(value),
            _ => return Err(Error::invalid(USAGE)),
        }
        index += 2;
    }
    let program = arguments.get(index + 1).ok_or_else(|| Error::invalid(USAGE))?;
    confine::run_confined(&read, &write, program, &arguments[index + 2..])
}

fn main() -> ExitCode {
    locate_data_root();
    locate_session_bus();
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    match run(&arguments) {
        Ok(code) => code,
        Err(error) => {
            eprintln!("{error}");
            ExitCode::FAILURE
        }
    }
}
