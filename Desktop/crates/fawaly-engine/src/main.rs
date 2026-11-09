//! Console engine started by Codex or Claude Code over MCP stdio.

use fawaly_core::bridge::Bridge;
use fawaly_core::client_link::ClientLink;
use fawaly_core::confine;
use fawaly_core::mcp::Server;
use fawaly_core::model::Agent;
use fawaly_core::secrets::{SecretStore, SystemSecrets};
use fawaly_core::{Engine, Error, Result};
use std::path::PathBuf;
use std::process::ExitCode;

const USAGE: &str = "Usage: sudo-interns-engine mcp --client codex|claude, status, version, allow-workspace PATH, deny-workspace PATH, disconnect, confine-probe";

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
            let server = Server::new(Bridge::new(engine()?, client));
            server.serve(std::io::stdin().lock(), std::io::stdout());
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
        Some("confine") => confine_and_exec(&arguments[1..]),
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

/// Applies the file boundary, then becomes the worker so it inherits it.
fn confine_and_exec(arguments: &[String]) -> Result<ExitCode> {
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
    confine::apply_landlock(&read, &write)?;
    exec(program, &arguments[index + 2..])
}

#[cfg(unix)]
fn exec(program: &str, arguments: &[String]) -> Result<ExitCode> {
    use std::os::unix::process::CommandExt;
    let error = std::process::Command::new(program).args(arguments).exec();
    Err(Error::invalid(format!("Sudo Interns could not start the confined worker: {error}")))
}

#[cfg(not(unix))]
fn exec(_program: &str, _arguments: &[String]) -> Result<ExitCode> {
    Err(Error::invalid("Confined launch is available only on Linux."))
}

fn main() -> ExitCode {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    match run(&arguments) {
        Ok(code) => code,
        Err(error) => {
            eprintln!("{error}");
            ExitCode::FAILURE
        }
    }
}
