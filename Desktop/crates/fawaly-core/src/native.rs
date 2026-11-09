use crate::api_worker::ApiWorker;
use crate::confine::{self, Confinement};
use crate::engine::{Engine, CLAUDE_TOKEN_ACCOUNT};
use crate::model::{cap_text, valid_model, Agent, ADVICE_LIMIT};
use crate::process::{self, WorkerSpec};
use crate::store::{ApiAssistantStore, WorkshopStore};
use crate::{paths, skills, Error, Result};
use serde_json::Value;
use std::path::{Path, PathBuf};

const PROMPT_LIMIT: usize = 120 * 1024;

#[derive(Clone, Debug)]
pub struct WorkerOutcome {
    pub answer: String,
    pub confinement: Confinement,
    pub git_changes: Vec<String>,
}

pub struct Invocation {
    pub arguments: Vec<String>,
    pub environment: Vec<(String, String)>,
}

#[derive(Default)]
pub struct InvocationOptions<'a> {
    pub workspace: Option<&'a Path>,
    pub token: Option<String>,
    pub claude_home: Option<PathBuf>,
    pub kimi_home: Option<PathBuf>,
    pub model: Option<String>,
}

fn strings(values: &[&str]) -> Vec<String> {
    values.iter().map(ToString::to_string).collect()
}

pub fn invocation(engine: &Engine, agent: Agent, directory: &Path, options: InvocationOptions<'_>) -> Result<Invocation> {
    let directory_text = directory.to_string_lossy().to_string();
    let mut environment = process::base_environment(&engine.home);
    environment.push(("DELEGATE_WORKER_DEPTH".into(), "1".into()));
    environment.push(("TMPDIR".into(), directory_text.clone()));
    environment.push(("TEMP".into(), directory_text.clone()));
    environment.push(("TMP".into(), directory_text.clone()));
    let workspace_text = options.workspace.map(|path| path.to_string_lossy().to_string());
    let mut arguments;
    match agent {
        Agent::Codex => {
            environment.push(("CODEX_HOME".into(), engine.auth_dir(Agent::Codex).to_string_lossy().to_string()));
            arguments = strings(&["-a", "never", "exec", "--ignore-user-config", "--ephemeral", "--skip-git-repo-check", "--sandbox"]);
            arguments.push(if options.workspace.is_some() { "workspace-write" } else { "read-only" }.to_string());
            arguments.extend(strings(&[
                "--json",
                "--disable",
                "hooks",
                "--disable",
                "plugins",
                "--disable",
                "multi_agent",
                "--disable",
                "skill_search",
                "-c",
                "cli_auth_credentials_store=\"file\"",
                "-c",
                "web_search=\"disabled\"",
                "--output-last-message",
            ]));
            arguments.push(directory.join("final.txt").to_string_lossy().to_string());
            if options.workspace.is_none() {
                arguments.extend(strings(&["--disable", "shell_tool", "--disable", "unified_exec"]));
            }
            if let Some(workspace) = &workspace_text {
                arguments.extend(["--add-dir".to_string(), workspace.clone()]);
            }
            arguments.push("-".to_string());
        }
        Agent::Kimi => {
            if options.kimi_home.is_none() {
                return Err(Error::invalid("Open Services in Sudo Interns and connect Kimi."));
            }
            // Kimi watches its home for settings; keep that inside the private folder.
            environment.retain(|(key, _)| key != "HOME" && key != "USERPROFILE");
            environment.push(("HOME".into(), directory_text.clone()));
            environment.push(("USERPROFILE".into(), directory_text.clone()));
            environment.push(("KIMI_CODE_HOME".into(), directory.join("kimi-config").to_string_lossy().to_string()));
            environment.push(("KIMI_DISABLE_TELEMETRY".into(), "1".into()));
            arguments = vec![
                "--agent-file".to_string(),
                directory.join("fawaly-worker.md").to_string_lossy().to_string(),
                "--skills-dir".to_string(),
                directory.join("empty-skills").to_string_lossy().to_string(),
                "--output-format".to_string(),
                "stream-json".to_string(),
                "--prompt".to_string(),
                "Read brief.txt in the current directory and complete that assignment for the primary agent.".to_string(),
            ];
            if let Some(workspace) = &workspace_text {
                arguments.extend(["--add-dir".to_string(), workspace.clone()]);
            }
        }
        Agent::Claude => {
            if options.token.is_none() && options.claude_home.is_none() {
                return Err(Error::invalid("Open Services in Sudo Interns and connect Claude Code."));
            }
            if let Some(token) = options.token {
                environment.push(("CLAUDE_CODE_OAUTH_TOKEN".into(), token));
            }
            let config = options.claude_home.unwrap_or_else(|| directory.join("claude-config"));
            environment.push(("CLAUDE_CONFIG_DIR".into(), config.to_string_lossy().to_string()));
            arguments = strings(&[
                "--print",
                "--safe-mode",
                "--setting-sources",
                "",
                "--strict-mcp-config",
                "--mcp-config",
                "{\"mcpServers\":{}}",
                "--no-session-persistence",
                "--output-format",
                "json",
                "--tools",
            ]);
            arguments.push(if options.workspace.is_some() { "Read,Glob,Grep,Edit,Write" } else { "" }.to_string());
            arguments.extend(["--permission-mode".to_string(), if options.workspace.is_some() { "acceptEdits" } else { "default" }.to_string()]);
            if let Some(workspace) = &workspace_text {
                arguments.extend(["--add-dir".to_string(), workspace.clone()]);
            }
        }
        _ => return Err(Error::invalid("API assistants do not launch a native CLI.")),
    }
    if let Some(model) = options.model {
        if !valid_model(&model) {
            return Err(Error::invalid("Invalid worker model identifier."));
        }
        let pair = ["--model".to_string(), model];
        if agent == Agent::Codex {
            let position = arguments.len() - 1;
            arguments.splice(position..position, pair);
        } else {
            arguments.extend(pair);
        }
    }
    Ok(Invocation { arguments, environment })
}

pub fn kimi_has_credentials(authentication: &Path) -> bool {
    let Ok(entries) = std::fs::read_dir(authentication.join("credentials")) else {
        return false;
    };
    entries.flatten().any(|entry| {
        let path = entry.path();
        path.extension().is_some_and(|extension| extension == "json") && std::fs::symlink_metadata(&path).is_ok_and(|info| info.is_file() && info.len() > 0)
    })
}

fn copy_tree(source: &Path, target: &Path) -> Result<()> {
    std::fs::create_dir_all(target)?;
    for entry in std::fs::read_dir(source)?.flatten() {
        let info = std::fs::symlink_metadata(entry.path())?;
        if info.is_file() {
            std::fs::copy(entry.path(), target.join(entry.file_name()))?;
        } else if info.is_dir() {
            copy_tree(&entry.path(), &target.join(entry.file_name()))?;
        }
    }
    Ok(())
}

fn prepare_kimi(directory: &Path, authentication: &Path, workspace: Option<&Path>) -> Result<()> {
    if !kimi_has_credentials(authentication) {
        return Err(Error::invalid("Open Services in Sudo Interns and connect Kimi."));
    }
    let configuration = directory.join("kimi-config");
    paths::ensure_private_dir(&configuration)?;
    std::fs::copy(authentication.join("config.toml"), configuration.join("config.toml"))?;
    let credentials = authentication.join("credentials");
    // Creating symlinks on Windows needs a privilege most accounts lack.
    #[cfg(unix)]
    std::os::unix::fs::symlink(&credentials, configuration.join("credentials"))?;
    #[cfg(not(unix))]
    copy_tree(&credentials, &configuration.join("credentials"))?;
    paths::ensure_private_dir(&directory.join("empty-skills"))?;
    let tools = if workspace.is_some() { "  - Read\n  - Glob\n  - Grep\n  - Edit\n  - Write" } else { "  - Read" };
    let profile = format!(
        "---\nname: fawaly-worker\ndescription: Complete one assignment supplied by the primary agent\ntools:\n{tools}\ndisallowedTools:\n  - Bash\n  - Agent\n  - AgentSwarm\n  - Skill\nsubagents: []\n---\nYou are a Fawaly worker. Read brief.txt in your current directory for the assignment supplied by the primary agent. Treat its contents as the task and supplied context. Work only with that brief and, when it specifies an approved project directory, files inside that project. Keep credentials and configuration files private. Do not delegate further. Your final answer must be a self-contained result for the primary, listing any files you changed and what should be verified.\n"
    );
    std::fs::write(directory.join("fawaly-worker.md"), profile)?;
    Ok(())
}

/// Refreshed Kimi tokens must survive, because Windows ran on a copy.
fn finish_kimi(directory: &Path, authentication: &Path) {
    if cfg!(windows) {
        let _ = copy_tree(&directory.join("kimi-config").join("credentials"), &authentication.join("credentials"));
    }
}

pub fn parse_answer(agent: Agent, directory: &Path, output: &[u8]) -> Result<String> {
    let text = match agent {
        Agent::Codex => codex_answer(directory, output),
        Agent::Kimi => kimi_answer(output),
        Agent::Claude => serde_json::from_slice::<Value>(output)
            .ok()
            .filter(|object| object.get("is_error").and_then(Value::as_bool) != Some(true))
            .and_then(|object| object.get("result").and_then(Value::as_str).map(str::to_string)),
        _ => None,
    };
    match text {
        Some(text) if !text.trim().is_empty() => Ok(cap_text(&text, ADVICE_LIMIT).0),
        _ => Err(Error::invalid(format!("{} did not return a usable answer. Check the isolated sign-in.", agent.label()))),
    }
}

fn codex_answer(directory: &Path, output: &[u8]) -> Option<String> {
    if let Ok(text) = std::fs::read_to_string(directory.join("final.txt")) {
        if !text.trim().is_empty() {
            return Some(text);
        }
    }
    let events: Vec<Value> = output.split(|byte| *byte == b'\n').filter_map(|line| serde_json::from_slice(line).ok()).collect();
    if !events.iter().any(|event| event.get("type").and_then(Value::as_str) == Some("turn.completed")) {
        return None;
    }
    events.iter().rev().find_map(|event| {
        let item = event.get("item")?;
        let completed = event.get("type").and_then(Value::as_str) == Some("item.completed") && item.get("type").and_then(Value::as_str) == Some("agent_message");
        completed.then(|| item.get("text").and_then(Value::as_str).map(str::to_string)).flatten()
    })
}

fn kimi_answer(output: &[u8]) -> Option<String> {
    let messages: Vec<Value> = output.split(|byte| *byte == b'\n').filter_map(|line| serde_json::from_slice(line).ok()).collect();
    messages.iter().rev().find_map(|message| {
        if message.get("role").and_then(Value::as_str) != Some("assistant") || message.get("tool_calls").is_some() {
            return None;
        }
        let content = message.get("content")?;
        if let Some(text) = content.as_str() {
            return Some(text.to_string());
        }
        let joined: String = content
            .as_array()?
            .iter()
            .filter(|part| part.get("type").and_then(Value::as_str) == Some("text"))
            .filter_map(|part| part.get("text").and_then(Value::as_str))
            .collect();
        (!joined.is_empty()).then_some(joined)
    })
}

/// Decides what limits this run before anything starts. Refusal is the default
/// where the OS and assistant cannot keep edits inside the approved project.
pub fn choose_confinement(engine: &Engine, agent: Agent, has_workspace: bool, landlock: bool) -> Result<Confinement> {
    if !has_workspace {
        return Ok(Confinement::NoProjectAccess);
    }
    if !agent.is_native() {
        return Ok(Confinement::AppEnforced);
    }
    let state = WorkshopStore::new(&engine.root).load()?;
    if cfg!(target_os = "linux") {
        if landlock {
            return Ok(Confinement::LandlockGitMonitored);
        }
        return if state.allow_unconfined_linux_workers {
            Ok(Confinement::UnconfinedByChoice)
        } else {
            Err(Error::invalid("This Linux kernel does not provide Landlock, so a native worker cannot be kept inside the project. Use an API or local assistant, or allow unconfined workers in Settings."))
        };
    }
    if cfg!(windows) && agent == Agent::Kimi {
        return if state.allow_unconfined_windows_kimi {
            Ok(Confinement::UnconfinedByChoice)
        } else {
            Err(Error::invalid("Kimi cannot be kept inside the project on Windows, so project editing is off for it. Use it for text-only work, choose another worker, or enable it in Settings."))
        };
    }
    Ok(Confinement::ToolLevel)
}

fn confined_program(engine: &Engine, program: &Path, arguments: Vec<String>, read: Vec<PathBuf>, write: Vec<PathBuf>) -> Result<(PathBuf, Vec<String>)> {
    let helper = engine.helper.clone().ok_or_else(|| Error::invalid("The worker file boundary helper is missing."))?;
    let mut wrapped = vec!["confine".to_string()];
    for path in read {
        wrapped.extend(["--read".to_string(), path.to_string_lossy().to_string()]);
    }
    for path in write {
        wrapped.extend(["--write".to_string(), path.to_string_lossy().to_string()]);
    }
    wrapped.push("--".to_string());
    wrapped.push(program.to_string_lossy().to_string());
    wrapped.extend(arguments);
    Ok((helper, wrapped))
}

/// Runs one assignment. `model` is the caller's resolved selection, if any.
pub fn run(engine: &Engine, agent: Agent, prompt: &str, workspace: Option<&Path>, timeout: u64, stop_file: Option<PathBuf>, model: Option<String>) -> Result<WorkerOutcome> {
    if prompt.is_empty() || prompt.len() > PROMPT_LIMIT {
        return Err(Error::invalid("The worker brief must be 1 byte to 120 KB."));
    }
    if std::env::var_os("DELEGATE_WORKER_DEPTH").is_some_and(|value| !value.is_empty()) {
        return Err(Error::invalid("Nested delegation is disabled."));
    }
    let _access = engine.lock_worker_access()?;
    let authorized = workspace.map(|path| engine.approved_workspace(&path.to_string_lossy())).transpose()?;
    let _locks = engine.lock_worker(agent, authorized.as_deref())?;
    let prompt = skills::enrich_prompt(prompt, authorized.as_deref(), &engine.home);
    let landlock = confine::landlock_available(engine.helper.as_deref());
    let confinement = choose_confinement(engine, agent, authorized.is_some(), landlock)?;
    let before = authorized.as_deref().map(confine::git_manifest);
    let answer = if agent.is_native() {
        run_native(engine, agent, &prompt, authorized.as_deref(), timeout, stop_file, model, landlock)
    } else {
        let mut assistant = ApiAssistantStore::new(&engine.root)
            .load(agent)?
            .filter(|assistant| assistant.enabled)
            .ok_or_else(|| Error::invalid("Connect this assistant in Sudo Interns first."))?;
        if let Some(model) = model {
            assistant.model = model;
        }
        ApiWorker { engine, transport: engine.transport.clone(), stop_file }.run(&assistant, &prompt, authorized.as_deref(), timeout)
    };
    let git_changes = match (&before, authorized.as_deref()) {
        (Some(before), Some(path)) => confine::manifest_changes(before, &confine::git_manifest(path)),
        _ => Vec::new(),
    };
    Ok(WorkerOutcome { answer: answer?, confinement, git_changes })
}

#[allow(clippy::too_many_arguments)]
fn run_native(engine: &Engine, agent: Agent, prompt: &str, workspace: Option<&Path>, timeout: u64, stop_file: Option<PathBuf>, model: Option<String>, landlock: bool) -> Result<String> {
    let executable = engine.executable(agent).ok_or_else(|| Error::invalid(format!("{} CLI is not installed.", agent.label())))?;
    if !engine.is_ready(agent) {
        return Err(Error::invalid(format!("Open Services in Sudo Interns and connect {}.", agent.label())));
    }
    let claude_home = (agent == Agent::Claude && engine.has_sign_in(Agent::Claude)).then(|| engine.auth_dir(Agent::Claude));
    let token = if agent == Agent::Claude && claude_home.is_none() { engine.secrets.get(CLAUDE_TOKEN_ACCOUNT)? } else { None };
    let directory = dunce::canonicalize(std::env::temp_dir())?.join(format!("fawaly-worker-{}", uuid::Uuid::new_v4()));
    paths::ensure_private_dir(&directory)?;
    struct Cleanup(PathBuf);
    impl Drop for Cleanup {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
    let _cleanup = Cleanup(directory.clone());
    let kimi_home = (agent == Agent::Kimi).then(|| engine.auth_dir(Agent::Kimi));
    if let Some(home) = &kimi_home {
        prepare_kimi(&directory, home, workspace)?;
    }
    let invocation = invocation(
        engine,
        agent,
        &directory,
        InvocationOptions { workspace, token, claude_home: claude_home.clone(), kimi_home: kimi_home.clone(), model },
    )?;
    let worker_prompt = match workspace {
        Some(path) => format!("The only approved project directory is {}. Use absolute paths under that directory.\n\n{prompt}", path.display()),
        None => prompt.to_string(),
    };
    let (program, arguments) = if landlock {
        let auth = match agent {
            Agent::Codex => Some(engine.auth_dir(Agent::Codex)),
            Agent::Kimi => kimi_home.clone(),
            _ => claude_home.clone(),
        };
        let mut write = vec![directory.clone(), PathBuf::from("/dev/null")];
        write.extend(workspace.map(Path::to_path_buf));
        write.extend(auth);
        let mut read = confine::linux_system_read_paths();
        read.extend(executable.parent().map(Path::to_path_buf));
        confined_program(engine, &executable, invocation.arguments, read, write)?
    } else {
        (executable, invocation.arguments)
    };
    let spec = WorkerSpec { program, arguments, environment: invocation.environment, directory: directory.clone(), prompt: worker_prompt, timeout, stop_file };
    let output = match process::run_worker(&spec) {
        Ok(output) => output,
        Err(Error::WorkerAuthentication) => {
            let _ = engine.set_requires_sign_in(agent, true);
            return Err(Error::WorkerAuthentication);
        }
        Err(error) => return Err(error),
    };
    if let Some(home) = &kimi_home {
        finish_kimi(&directory, home);
    }
    parse_answer(agent, &directory, &output)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::secrets::MemorySecrets;
    use std::sync::Arc;

    fn engine() -> (tempfile::TempDir, Engine) {
        let root = tempfile::tempdir().unwrap();
        let engine = Engine::with(root.path().join("data"), root.path().join("home"), Arc::new(MemorySecrets::default()));
        (root, engine)
    }

    #[test]
    fn claude_workers_never_get_a_shell() {
        let (root, engine) = engine();
        let project = root.path().join("project");
        let options = InvocationOptions { workspace: Some(&project), token: Some("t".into()), ..Default::default() };
        let invocation = invocation(&engine, Agent::Claude, root.path(), options).unwrap();
        let tools = invocation.arguments.iter().position(|value| value == "--tools").unwrap();
        assert_eq!(invocation.arguments[tools + 1], "Read,Glob,Grep,Edit,Write");
        assert!(!invocation.arguments.iter().any(|value| value.contains("Bash")));
    }

    #[test]
    fn workers_cannot_delegate_again() {
        let (root, engine) = engine();
        let options = InvocationOptions { token: Some("t".into()), ..Default::default() };
        let invocation = invocation(&engine, Agent::Claude, root.path(), options).unwrap();
        assert!(invocation.environment.iter().any(|(key, value)| key == "DELEGATE_WORKER_DEPTH" && value == "1"));
        assert!(invocation.arguments.iter().any(|value| value == "--strict-mcp-config"));
    }

    #[test]
    fn codex_is_read_only_without_a_project_and_keeps_the_dash_last() {
        let (root, engine) = engine();
        let options = InvocationOptions { model: Some("gpt-x".into()), ..Default::default() };
        let invocation = invocation(&engine, Agent::Codex, root.path(), options).unwrap();
        let position = invocation.arguments.iter().position(|value| value == "--sandbox").unwrap();
        assert_eq!(invocation.arguments[position + 1], "read-only");
        assert_eq!(invocation.arguments.last().unwrap(), "-");
        assert!(invocation.arguments.iter().any(|value| value == "shell_tool"));
    }

    #[test]
    fn kimi_home_stays_in_the_private_folder() {
        let (root, engine) = engine();
        let options = InvocationOptions { kimi_home: Some(root.path().join("auth")), ..Default::default() };
        let invocation = invocation(&engine, Agent::Kimi, root.path(), options).unwrap();
        let home: Vec<_> = invocation.environment.iter().filter(|(key, _)| key == "HOME").collect();
        assert_eq!(home.len(), 1);
        assert_eq!(home[0].1, root.path().to_string_lossy());
    }

    #[test]
    fn invalid_model_ids_are_refused() {
        let (root, engine) = engine();
        let options = InvocationOptions { token: Some("t".into()), model: Some("--dangerous flag".into()), ..Default::default() };
        assert!(invocation(&engine, Agent::Claude, root.path(), options).is_err());
    }

    #[test]
    fn parses_each_cli_answer_format() {
        let directory = tempfile::tempdir().unwrap();
        assert_eq!(parse_answer(Agent::Claude, directory.path(), br#"{"result":"ok","is_error":false}"#).unwrap(), "ok");
        assert!(parse_answer(Agent::Claude, directory.path(), br#"{"result":"no","is_error":true}"#).is_err());
        let codex = b"{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"done\"}}\n{\"type\":\"turn.completed\"}\n";
        assert_eq!(parse_answer(Agent::Codex, directory.path(), codex).unwrap(), "done");
        let kimi = b"{\"role\":\"assistant\",\"tool_calls\":[]}\n{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"hi\"}]}\n";
        assert_eq!(parse_answer(Agent::Kimi, directory.path(), kimi).unwrap(), "hi");
    }

    #[test]
    fn project_access_is_never_silently_unconfined() {
        let (_root, engine) = engine();
        assert_eq!(choose_confinement(&engine, Agent::Kimi, false, false).unwrap(), Confinement::NoProjectAccess);
        assert_eq!(choose_confinement(&engine, Agent::Deepseek, true, false).unwrap(), Confinement::AppEnforced);
        if cfg!(target_os = "linux") {
            assert!(choose_confinement(&engine, Agent::Claude, true, false).is_err());
            assert_eq!(choose_confinement(&engine, Agent::Claude, true, true).unwrap(), Confinement::LandlockGitMonitored);
        }
        if cfg!(windows) {
            assert!(choose_confinement(&engine, Agent::Kimi, true, false).is_err());
            assert_eq!(choose_confinement(&engine, Agent::Claude, true, false).unwrap(), Confinement::ToolLevel);
        }
    }
}
