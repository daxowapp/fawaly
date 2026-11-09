use crate::engine::{same_path, Engine};
use crate::model::Agent;
use crate::process::{self, LoginCommand, LoginReply};
use crate::{paths, Error, Result};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::AtomicBool;
use std::sync::mpsc;
use std::sync::Arc;
use std::time::{Duration, Instant};

pub const SERVER_NAME: &str = "fawaly_team";
pub const ENGINE_NAME: &str = "sudo-interns-engine";
/// Marks the data folder so the launcher can locate it from its own path.
pub const ROOT_MARKER: &str = ".sudo-interns-root";

pub type Execute = Arc<dyn Fn(&LoginCommand, Duration) -> Result<LoginReply> + Send + Sync>;

#[derive(Debug, PartialEq, Eq)]
pub struct Entry {
    pub command: String,
    pub arguments: Vec<String>,
    pub environment: bool,
}

pub struct ClientLink {
    pub engine: Engine,
    pub execute: Execute,
    pub write_codex_timeout: bool,
}

/// A stable copy: package install paths and AppImage mounts change between runs.
pub fn launcher_path(engine: &Engine) -> PathBuf {
    engine.root.join("bin").join(paths::exe_name(ENGINE_NAME))
}

fn file_digest(path: &Path) -> Option<String> {
    std::fs::read(path).ok().map(|data| hex::encode(Sha256::digest(data)))
}

/// Copies the engine into place. A running copy on Windows is moved aside first.
pub fn prepare_launcher(engine: &Engine, source: &Path) -> Result<PathBuf> {
    let target = launcher_path(engine);
    let folder = target.parent().ok_or_else(|| Error::invalid("Invalid launcher folder."))?.to_path_buf();
    paths::ensure_private_dir(&folder)?;
    std::fs::write(engine.root.join(ROOT_MARKER), b"")?;
    if let Ok(entries) = std::fs::read_dir(&folder) {
        for entry in entries.flatten() {
            if entry.file_name().to_string_lossy().starts_with(".old-") {
                let _ = std::fs::remove_file(entry.path());
            }
        }
    }
    if !source.is_file() {
        return Err(Error::invalid("The team engine is missing from this installation. Reinstall Sudo Interns."));
    }
    if file_digest(source) == file_digest(&target) && target.is_file() {
        return Ok(target);
    }
    let temporary = folder.join(format!(".new-{}", uuid::Uuid::new_v4()));
    std::fs::copy(source, &temporary)?;
    paths::set_executable(&temporary)?;
    if target.exists() {
        let parked = folder.join(format!(".old-{}", uuid::Uuid::new_v4()));
        std::fs::rename(&target, &parked)?;
        let _ = std::fs::remove_file(&parked);
    }
    std::fs::rename(&temporary, &target)?;
    Ok(target)
}

impl ClientLink {
    pub fn new(engine: Engine) -> Self {
        let never = Arc::new(AtomicBool::new(false));
        Self {
            engine,
            execute: Arc::new(move |command, timeout| process::run_login(command, timeout, &never, &|_| {})),
            write_codex_timeout: true,
        }
    }

    fn environment(&self) -> Vec<(String, String)> {
        let mut values = process::base_environment(&self.engine.home);
        values.push(("CODEX_HOME".into(), self.engine.home.join(".codex").to_string_lossy().to_string()));
        values
    }

    fn command(&self, executable: &Path, arguments: Vec<String>) -> LoginCommand {
        LoginCommand { executable: executable.to_path_buf(), arguments, environment: self.environment(), directory: self.engine.root.clone(), input: None }
    }

    fn remove_arguments(primary: Agent) -> Vec<String> {
        let values: &[&str] = if primary == Agent::Codex { &["mcp", "remove", SERVER_NAME] } else { &["mcp", "remove", "--scope", "user", SERVER_NAME] };
        values.iter().map(ToString::to_string).collect()
    }

    pub fn entry(&self, primary: Agent, executable: &Path) -> Result<Option<Entry>> {
        let value: Option<Value> = if primary == Agent::Codex {
            let arguments = ["mcp", "get", SERVER_NAME, "--json"].map(str::to_string).to_vec();
            let reply = (self.execute)(&self.command(executable, arguments), Duration::from_secs(15))?;
            if reply.exit_code != 0 {
                if format!("{}{}", reply.output, reply.error_output).contains("No MCP server named") {
                    return Ok(None);
                }
                return Err(Error::invalid("Codex settings could not be read. Check your agent's settings and retry."));
            }
            serde_json::from_str::<Value>(&reply.output)?.get("transport").cloned()
        } else {
            match std::fs::read(self.engine.home.join(".claude.json")) {
                Ok(data) => serde_json::from_slice::<Value>(&data)?.get("mcpServers").and_then(|servers| servers.get(SERVER_NAME)).cloned(),
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
                Err(error) => return Err(error.into()),
            }
        };
        Ok(value.map(|value| Entry {
            command: value.get("command").and_then(Value::as_str).unwrap_or("").to_string(),
            arguments: value.get("args").and_then(Value::as_array).into_iter().flatten().filter_map(Value::as_str).map(str::to_string).collect(),
            environment: value.get("env").and_then(Value::as_object).is_some_and(|env| !env.is_empty()),
        }))
    }

    /// Only our own registration is touched. Other MCP servers stay as they are.
    pub fn connect(&self, primary: Agent, engine_source: &Path) -> Result<()> {
        if !primary.is_primary() {
            return Err(Error::invalid("Prepare your primary agent first."));
        }
        let executable = self.engine.executable(primary).ok_or_else(|| Error::invalid("Prepare your primary agent first."))?;
        paths::ensure_private_dir(&self.engine.root)?;
        let launcher = launcher_path(&self.engine);
        let launcher_text = launcher.to_string_lossy().to_string();
        let expected = vec!["mcp".to_string(), "--client".to_string(), primary.raw().to_string()];
        let mut saved = self.entry(primary, &executable)?;
        if let Some(existing) = &saved {
            if !same_path(Path::new(&existing.command), &launcher) || existing.arguments != expected || existing.environment {
                return Err(Error::invalid("A different Sudo Interns team connection already exists. Open your agent's MCP settings to review it before reconnecting."));
            }
        }
        prepare_launcher(&self.engine, engine_source)?;
        if saved.take().is_none() {
            let mut arguments: Vec<String> = if primary == Agent::Codex {
                vec!["mcp".to_string(), "add".to_string(), SERVER_NAME.to_string(), "--".to_string(), launcher_text.clone()]
            } else {
                ["mcp", "add", "--scope", "user", "--transport", "stdio", SERVER_NAME, "--", launcher_text.as_str()].map(str::to_string).to_vec()
            };
            arguments.extend(expected.clone());
            let reply = (self.execute)(&self.command(&executable, arguments), Duration::from_secs(30))?;
            if reply.exit_code != 0 {
                return Err(Error::invalid("The team connection could not be saved in your primary agent. Please retry."));
            }
        }
        let confirmed = self.entry(primary, &executable)?;
        if !confirmed.is_some_and(|entry| same_path(Path::new(&entry.command), &launcher) && entry.arguments == expected) {
            return Err(Error::invalid("The primary agent has not confirmed its team settings. Please retry."));
        }
        if primary == Agent::Codex && self.write_codex_timeout {
            write_codex_timeout(&executable, &self.engine.home, &self.engine.root, &self.environment())?;
        }
        self.check_engine(primary)
    }

    /// Removes only a registration that points at this app's launcher.
    pub fn disconnect(&self, primary: Agent) -> Result<bool> {
        let Some(executable) = self.engine.executable(primary) else {
            return Ok(false);
        };
        let Some(entry) = self.entry(primary, &executable)? else {
            return Ok(false);
        };
        if !same_path(Path::new(&entry.command), &launcher_path(&self.engine)) {
            return Err(Error::invalid("The saved connection points elsewhere, so it was left in place."));
        }
        let reply = (self.execute)(&self.command(&executable, Self::remove_arguments(primary)), Duration::from_secs(30))?;
        if reply.exit_code != 0 {
            return Err(Error::invalid("The team connection could not be removed. Please retry."));
        }
        Ok(true)
    }

    pub fn check_engine(&self, primary: Agent) -> Result<()> {
        let requests = [
            json!({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"fawaly-setup","version":crate::VERSION}}}),
            json!({"jsonrpc":"2.0","method":"notifications/initialized"}),
            json!({"jsonrpc":"2.0","id":2,"method":"tools/list"}),
        ];
        let input = requests.iter().map(Value::to_string).collect::<Vec<_>>().join("\n") + "\n";
        let mut command = self.command(&launcher_path(&self.engine), vec!["mcp".to_string(), "--client".to_string(), primary.raw().to_string()]);
        command.input = Some(input);
        let reply = (self.execute)(&command, Duration::from_secs(15))?;
        let listing = reply.output.lines().filter_map(|line| serde_json::from_str::<Value>(line).ok()).find(|value| value.get("id") == Some(&json!(2)));
        let names: Vec<String> = listing
            .as_ref()
            .and_then(|value| value.pointer("/result/tools"))
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(|tool| tool.get("name").and_then(Value::as_str).map(str::to_string))
            .collect();
        if reply.exit_code == 0 && ["roster_get", "consult", "delegate"].iter().all(|name| names.iter().any(|value| value == name)) {
            Ok(())
        } else {
            Err(Error::invalid("The team connection was saved, but its engine check failed. Please retry."))
        }
    }
}

/// Uses Codex's own config writer so the edit stays limited to this server's timeout.
fn write_codex_timeout(executable: &Path, home: &Path, directory: &Path, environment: &[(String, String)]) -> Result<()> {
    let failed = || Error::invalid("Codex could not save the team's task duration. Please retry setup.");
    let mut command = Command::new(executable);
    command
        .arg("app-server")
        .env_clear()
        .envs(environment.iter().map(|(key, value)| (key, value)))
        .current_dir(directory)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        command.creation_flags(0x0800_0000);
    }
    let mut child = command.spawn().map_err(|_| failed())?;
    let mut stdin = child.stdin.take().ok_or_else(failed)?;
    let stdout = child.stdout.take().ok_or_else(failed)?;
    let (sender, receiver) = mpsc::channel::<Value>();
    std::thread::spawn(move || {
        for line in BufReader::new(stdout).lines().map_while(std::result::Result::ok) {
            if let Ok(value) = serde_json::from_str::<Value>(&line) {
                if sender.send(value).is_err() {
                    return;
                }
            }
        }
    });
    let outcome = (|| -> Result<()> {
        let mut send = |value: Value| writeln!(stdin, "{value}").map_err(|_| failed());
        let wait = |id: i64| -> Result<()> {
            let deadline = Instant::now() + Duration::from_secs(15);
            loop {
                let remaining = deadline.checked_duration_since(Instant::now()).ok_or_else(failed)?;
                let message = receiver.recv_timeout(remaining).map_err(|_| failed())?;
                if message.get("id") == Some(&json!(id)) {
                    return if message.get("error").is_none() && message.get("result").is_some() { Ok(()) } else { Err(failed()) };
                }
            }
        };
        send(json!({"id":1,"method":"initialize","params":{"clientInfo":{"name":"fawaly-setup","version":crate::VERSION},"capabilities":{}}}))?;
        wait(1)?;
        send(json!({"method":"initialized"}))?;
        let file = home.join(".codex").join("config.toml");
        send(json!({"id":2,"method":"config/value/write","params":{"keyPath":format!("mcp_servers.{SERVER_NAME}.tool_timeout_sec"),"value":3610,"mergeStrategy":"replace","filePath":file.to_string_lossy()}}))?;
        wait(2)
    })();
    let _ = child.kill();
    let _ = child.wait();
    outcome
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::secrets::MemorySecrets;
    use std::sync::Mutex;

    struct Fixture {
        _root: tempfile::TempDir,
        link: ClientLink,
        calls: Arc<Mutex<Vec<Vec<String>>>>,
        source: PathBuf,
    }

    fn fixture(respond: impl Fn(&LoginCommand) -> LoginReply + Send + Sync + 'static) -> Fixture {
        let root = tempfile::tempdir().unwrap();
        let home = root.path().join("home");
        std::fs::create_dir_all(&home).unwrap();
        let engine = Engine::with(root.path().join("data"), home, Arc::new(MemorySecrets::default()));
        for agent in [Agent::Codex, Agent::Claude] {
            let runtime = engine.runtime_dir(agent);
            std::fs::create_dir_all(&runtime).unwrap();
            std::fs::write(runtime.join(paths::exe_name(agent.raw())), "x").unwrap();
        }
        let source = root.path().join("source-engine");
        std::fs::write(&source, "engine-v1").unwrap();
        let calls = Arc::new(Mutex::new(Vec::new()));
        let seen = calls.clone();
        let execute: Execute = Arc::new(move |command, _| {
            seen.lock().unwrap().push(command.arguments.clone());
            Ok(respond(command))
        });
        Fixture { _root: root, link: ClientLink { engine, execute, write_codex_timeout: false }, calls, source }
    }

    fn tools_reply() -> LoginReply {
        LoginReply { exit_code: 0, output: "{\"id\":1}\n{\"id\":2,\"result\":{\"tools\":[{\"name\":\"roster_get\"},{\"name\":\"consult\"},{\"name\":\"delegate\"}]}}\n".into(), error_output: String::new() }
    }

    #[test]
    fn claude_registration_preserves_other_servers() {
        let shared: Arc<Mutex<Option<PathBuf>>> = Arc::new(Mutex::new(None));
        let observed = shared.clone();
        let fixture = fixture(move |command| {
            if command.arguments.first().map(String::as_str) == Some("mcp") && command.arguments.get(1).map(String::as_str) == Some("add") {
                // Stand-in for the official CLI, which merges into the user's file.
                let home = observed.lock().unwrap().clone().unwrap();
                let file = home.join(".claude.json");
                let mut settings: Value = serde_json::from_slice(&std::fs::read(&file).unwrap()).unwrap();
                let separator = command.arguments.iter().position(|value| value == "--").unwrap();
                settings["mcpServers"][SERVER_NAME] = json!({"command": command.arguments[separator + 1], "args": command.arguments[separator + 2..]});
                std::fs::write(file, serde_json::to_vec(&settings).unwrap()).unwrap();
                return LoginReply::default();
            }
            tools_reply()
        });
        *shared.lock().unwrap() = Some(fixture.link.engine.home.clone());
        let file = fixture.link.engine.home.join(".claude.json");
        std::fs::write(&file, r#"{"mcpServers":{"other":{"command":"keep-me"}},"theme":"dark"}"#).unwrap();
        fixture.link.connect(Agent::Claude, &fixture.source).unwrap();
        let settings: Value = serde_json::from_slice(&std::fs::read(&file).unwrap()).unwrap();
        assert_eq!(settings["mcpServers"]["other"]["command"], "keep-me");
        assert_eq!(settings["theme"], "dark");
        assert!(launcher_path(&fixture.link.engine).is_file());
        let calls = fixture.calls.lock().unwrap();
        assert!(calls.iter().any(|call| call.len() > 3 && call[..4] == ["mcp", "add", "--scope", "user"]));
    }

    #[test]
    fn a_foreign_registration_is_left_alone() {
        let fixture = fixture(|_| tools_reply());
        std::fs::write(fixture.link.engine.home.join(".claude.json"), format!(r#"{{"mcpServers":{{"{SERVER_NAME}":{{"command":"/somewhere/else","args":[]}}}}}}"#)).unwrap();
        assert!(fixture.link.connect(Agent::Claude, &fixture.source).unwrap_err().to_string().contains("different"));
        assert!(fixture.link.disconnect(Agent::Claude).is_err());
        assert!(fixture.calls.lock().unwrap().is_empty());
    }

    #[test]
    fn a_failed_engine_check_is_reported() {
        let fixture = fixture(|command| {
            if command.input.is_some() {
                LoginReply { exit_code: 1, ..Default::default() }
            } else {
                LoginReply::default()
            }
        });
        let launcher = launcher_path(&fixture.link.engine).to_string_lossy().to_string();
        let args = r#"["mcp","--client","claude"]"#;
        let body = format!(r#"{{"mcpServers":{{"{SERVER_NAME}":{{"command":{},"args":{args}}}}}}}"#, serde_json::to_string(&launcher).unwrap());
        std::fs::write(fixture.link.engine.home.join(".claude.json"), body).unwrap();
        assert!(fixture.link.connect(Agent::Claude, &fixture.source).unwrap_err().to_string().contains("engine check"));
    }

    #[test]
    fn launcher_updates_when_the_engine_changes() {
        let fixture = fixture(|_| tools_reply());
        let target = prepare_launcher(&fixture.link.engine, &fixture.source).unwrap();
        assert_eq!(std::fs::read_to_string(&target).unwrap(), "engine-v1");
        std::fs::write(&fixture.source, "engine-v2").unwrap();
        prepare_launcher(&fixture.link.engine, &fixture.source).unwrap();
        assert_eq!(std::fs::read_to_string(&target).unwrap(), "engine-v2");
    }

    #[test]
    fn missing_codex_entry_is_recognized() {
        let fixture = fixture(|_| LoginReply { exit_code: 1, output: String::new(), error_output: "No MCP server named 'fawaly_team' found".into() });
        let executable = fixture.link.engine.executable(Agent::Codex).unwrap();
        assert_eq!(fixture.link.entry(Agent::Codex, &executable).unwrap(), None);
    }
}
