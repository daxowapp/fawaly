use crate::engine::{Engine, CLAUDE_TOKEN_ACCOUNT};
use crate::model::Agent;
use crate::process::{self, LoginCommand, LoginReply, UrlCallback};
use crate::{paths, Error, Result};
use serde_json::Value;
use std::sync::atomic::AtomicBool;
use std::sync::Arc;
use std::time::Duration;

pub type Execute = Arc<dyn Fn(&LoginCommand, Duration, &AtomicBool, UrlCallback<'_>) -> Result<LoginReply> + Send + Sync>;

pub struct NativeSignIn {
    pub engine: Engine,
    pub execute: Execute,
}

impl NativeSignIn {
    pub fn new(engine: Engine) -> Self {
        Self { engine, execute: Arc::new(|command, timeout, cancel, on_url| process::run_login(command, timeout, cancel, on_url)) }
    }

    pub fn command(&self, agent: Agent, login: bool, region: &str) -> Result<LoginCommand> {
        let executable = self.engine.executable(agent).ok_or_else(|| Error::invalid("This service needs to be prepared first."))?;
        let directory = self.engine.auth_dir(agent);
        paths::ensure_private_dir(&directory)?;
        let directory_text = directory.to_string_lossy().to_string();
        let mut environment = process::base_environment(&self.engine.home);
        environment.push(("CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC".into(), "1".into()));
        environment.push(("DISABLE_AUTOUPDATER".into(), "1".into()));
        let text = |values: &[&str]| values.iter().map(ToString::to_string).collect::<Vec<_>>();
        let arguments = match agent {
            Agent::Codex => {
                environment.push(("CODEX_HOME".into(), directory_text));
                let mut values = if login { text(&["login"]) } else { text(&["login", "status"]) };
                values.extend(text(&["-c", "cli_auth_credentials_store=\"file\""]));
                values
            }
            Agent::Kimi => {
                environment.push(("KIMI_CODE_HOME".into(), directory_text));
                environment.push(("KIMI_DISABLE_TELEMETRY".into(), "1".into()));
                if login {
                    vec!["login".to_string(), "--region".to_string(), if region == "mainland-cn" { "mainland-cn" } else { "global" }.to_string()]
                } else {
                    text(&["provider", "list", "--json"])
                }
            }
            Agent::Claude => {
                environment.push(("CLAUDE_CONFIG_DIR".into(), directory_text));
                if login {
                    text(&["auth", "login", "--claudeai"])
                } else {
                    text(&["auth", "status", "--json"])
                }
            }
            _ => return Err(Error::invalid("Configure API assistants from the app's API services section.")),
        };
        Ok(LoginCommand { executable, arguments, environment, directory, input: None })
    }

    pub fn sign_in(&self, agent: Agent, region: &str, cancel: &AtomicBool, on_url: UrlCallback<'_>) -> Result<()> {
        let result = (self.execute)(&self.command(agent, true, region)?, Duration::from_secs(600), cancel, on_url)?;
        if result.exit_code != 0 {
            return Err(Error::invalid("Sign-in was not completed. You can retry from this screen."));
        }
        self.engine.set_requires_sign_in(agent, false)?;
        if agent == Agent::Kimi {
            self.engine.record_sign_in(agent, true)?;
        }
        match self.verify(agent, cancel) {
            Ok(true) => Ok(()),
            Ok(false) => Err(Error::invalid("The service has not confirmed your sign-in yet.")),
            Err(error) => {
                let _ = self.engine.record_sign_in(agent, false);
                Err(error)
            }
        }
    }

    pub fn verify(&self, agent: Agent, cancel: &AtomicBool) -> Result<bool> {
        if self.engine.requires_sign_in(agent) {
            self.engine.record_sign_in(agent, false)?;
            return Ok(false);
        }
        let result = (self.execute)(&self.command(agent, false, "global")?, Duration::from_secs(20), cancel, &|_| {})?;
        let connected = match agent {
            Agent::Codex => result.exit_code == 0 && format!("{}\n{}", result.output, result.error_output).lines().any(|line| line.trim().to_lowercase().starts_with("logged in")),
            Agent::Kimi => {
                let object: Option<Value> = serde_json::from_str(&result.output).ok();
                let has_providers = object.and_then(|value| value.get("providers").and_then(Value::as_object).map(|providers| !providers.is_empty())).unwrap_or(false);
                result.exit_code == 0 && has_providers && self.engine.has_sign_in(Agent::Kimi) && crate::native::kimi_has_credentials(&self.engine.auth_dir(Agent::Kimi))
            }
            Agent::Claude => {
                let object: Option<Value> = serde_json::from_str(&result.output).ok();
                result.exit_code == 0 && object.and_then(|value| value.get("loggedIn").and_then(Value::as_bool)) == Some(true)
            }
            _ => return Err(Error::invalid("Configure API assistants from the app's API services section.")),
        };
        self.engine.record_sign_in(agent, connected)?;
        Ok(connected)
    }

    pub fn sign_out(&self, agent: Agent, cancel: &AtomicBool) -> Result<()> {
        let _lock = self.engine.lock_job()?;
        if agent == Agent::Kimi {
            // Removes this app's whole Kimi profile, not just one credential folder.
            let directory = self.engine.auth_dir(Agent::Kimi);
            if directory.exists() {
                std::fs::remove_dir_all(&directory)?;
            }
            return self.engine.record_sign_in(Agent::Kimi, false);
        }
        let mut command = self.command(agent, false, "global")?;
        command.arguments = if agent == Agent::Codex {
            ["logout", "-c", "cli_auth_credentials_store=\"file\""].map(str::to_string).to_vec()
        } else {
            ["auth", "logout"].map(str::to_string).to_vec()
        };
        let reply = (self.execute)(&command, Duration::from_secs(20), cancel, &|_| {})?;
        if reply.exit_code != 0 {
            return Err(Error::invalid("Sign-out could not be completed. Please retry."));
        }
        self.engine.record_sign_in(agent, false)?;
        if agent == Agent::Claude {
            self.engine.secrets.delete(CLAUDE_TOKEN_ACCOUNT)?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::secrets::MemorySecrets;
    use std::path::PathBuf;
    use std::sync::Mutex;

    fn fixture(reply: LoginReply) -> (tempfile::TempDir, NativeSignIn, Arc<Mutex<Vec<Vec<String>>>>) {
        let root = tempfile::tempdir().unwrap();
        let engine = Engine::with(root.path().join("data"), root.path().join("home"), Arc::new(MemorySecrets::default()));
        let name = paths::exe_name("claude");
        let runtime = engine.runtime_dir(Agent::Claude);
        std::fs::create_dir_all(&runtime).unwrap();
        std::fs::write(runtime.join(&name), "x").unwrap();
        let calls = Arc::new(Mutex::new(Vec::new()));
        let seen = calls.clone();
        let execute: Execute = Arc::new(move |command, _timeout, _cancel, _on_url| {
            seen.lock().unwrap().push(command.arguments.clone());
            assert!(command.directory.ends_with(PathBuf::from("official").join("claude")));
            Ok(reply.clone())
        });
        (root, NativeSignIn { engine, execute }, calls)
    }

    #[test]
    fn claude_sign_in_is_verified_before_counting_as_connected() {
        let never = AtomicBool::new(false);
        let (_root, service, calls) = fixture(LoginReply { exit_code: 0, output: r#"{"loggedIn":true}"#.into(), error_output: String::new() });
        service.sign_in(Agent::Claude, "global", &never, &|_| {}).unwrap();
        assert!(service.engine.has_sign_in(Agent::Claude));
        let calls = calls.lock().unwrap();
        assert_eq!(calls[0], ["auth", "login", "--claudeai"]);
        assert_eq!(calls[1], ["auth", "status", "--json"]);
    }

    #[test]
    fn an_unconfirmed_sign_in_stays_disconnected() {
        let never = AtomicBool::new(false);
        let (_root, service, _calls) = fixture(LoginReply { exit_code: 0, output: r#"{"loggedIn":false}"#.into(), error_output: String::new() });
        assert!(service.sign_in(Agent::Claude, "global", &never, &|_| {}).is_err());
        assert!(!service.engine.has_sign_in(Agent::Claude));
    }
}
