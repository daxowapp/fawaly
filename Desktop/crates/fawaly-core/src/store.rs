use crate::model::{valid_model, Agent, WorkshopState};
use crate::{paths, Error, Result};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};
use url::Url;

pub struct WorkshopStore {
    file: PathBuf,
}

impl WorkshopStore {
    pub fn new(root: &Path) -> Self {
        Self { file: root.join("workshop.json") }
    }

    pub fn load(&self) -> Result<WorkshopState> {
        match std::fs::read(&self.file) {
            Ok(data) => Ok(serde_json::from_slice(&data)?),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(WorkshopState::default()),
            Err(error) => Err(error.into()),
        }
    }

    pub fn save(&self, state: &WorkshopState) -> Result<()> {
        paths::write_atomic(&self.file, &serde_json::to_vec_pretty(state)?)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum ApiFormat {
    #[serde(rename = "openAI")]
    OpenAi,
    #[serde(rename = "anthropic")]
    Anthropic,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ApiAssistant {
    pub agent: Agent,
    pub endpoint: String,
    pub model: String,
    pub format: ApiFormat,
    pub enabled: bool,
    pub daily_request_limit: u32,
    pub max_rounds: u32,
}

impl ApiAssistant {
    pub fn preset(agent: Agent) -> Self {
        let (endpoint, model, format) = match agent {
            Agent::Zai => ("https://api.z.ai/api/paas/v4/chat/completions", "glm-5.3", ApiFormat::OpenAi),
            Agent::Minimax => ("https://api.minimax.io/anthropic/v1/messages", "MiniMax-M3.1-Flash", ApiFormat::Anthropic),
            Agent::Deepseek => ("https://api.deepseek.com/chat/completions", "deepseek-flash", ApiFormat::OpenAi),
            Agent::Openrouter => ("https://openrouter.ai/api/v1/chat/completions", "", ApiFormat::OpenAi),
            Agent::Ollama => ("http://localhost:11434/v1/chat/completions", "", ApiFormat::OpenAi),
            Agent::Lmstudio => ("http://localhost:1234/v1/chat/completions", "", ApiFormat::OpenAi),
            Agent::AnthropicApi => ("https://api.anthropic.com/v1/messages", "", ApiFormat::Anthropic),
            _ => ("https://api.openai.com/v1/chat/completions", "", ApiFormat::OpenAi),
        };
        Self { agent, endpoint: endpoint.to_string(), model: model.to_string(), format, enabled: true, daily_request_limit: 100, max_rounds: 12 }
    }

    pub fn is_local(&self) -> bool {
        Url::parse(&self.endpoint)
            .ok()
            .and_then(|url| url.host_str().map(str::to_lowercase))
            .is_some_and(|host| ["localhost", "127.0.0.1", "[::1]", "::1"].contains(&host.as_str()))
    }

    pub fn key_account(&self) -> String {
        format!("{}:{}", self.agent.raw(), hex::encode(Sha256::digest(self.endpoint.as_bytes())))
    }

    pub fn validate(&self) -> Result<()> {
        let url = Url::parse(&self.endpoint).map_err(|_| Error::invalid("Choose a valid service endpoint."))?;
        let suffix = if self.format == ApiFormat::Anthropic { "/messages" } else { "/chat/completions" };
        let scheme_allowed = url.scheme() == "https" || (url.scheme() == "http" && self.is_local());
        let clean = url.username().is_empty() && url.password().is_none() && url.query().is_none() && url.fragment().is_none();
        if self.agent.is_native()
            || !valid_model_or_empty(&self.model)
            || !(1..=10_000).contains(&self.daily_request_limit)
            || !(1..=32).contains(&self.max_rounds)
            || !scheme_allowed
            || !clean
            || url.host_str().is_none_or(str::is_empty)
            || !url.path().ends_with(suffix)
        {
            return Err(Error::invalid("Choose a valid HTTPS service endpoint, model and request limits. HTTP is allowed only on this computer."));
        }
        if matches!(self.agent, Agent::Ollama | Agent::Lmstudio) && !self.is_local() {
            return Err(Error::invalid("Local assistants must use a loopback address on this computer."));
        }
        let fixed = match self.agent {
            Agent::Zai => Some("api.z.ai"),
            Agent::Minimax => Some("api.minimax.io"),
            Agent::Deepseek => Some("api.deepseek.com"),
            Agent::Openrouter => Some("openrouter.ai"),
            _ => None,
        };
        if fixed.is_some_and(|host| url.host_str() != Some(host)) {
            return Err(Error::invalid("This provider must use its official API host. Choose a custom service for another host."));
        }
        if self.agent == Agent::Openrouter && (self.format != ApiFormat::OpenAi || self.endpoint != "https://openrouter.ai/api/v1/chat/completions") {
            return Err(Error::invalid("OpenRouter must use its official chat endpoint."));
        }
        Ok(())
    }
}

fn valid_model_or_empty(value: &str) -> bool {
    value.is_empty() || valid_model(value)
}

pub struct ApiAssistantStore {
    file: PathBuf,
}

impl ApiAssistantStore {
    pub fn new(root: &Path) -> Self {
        Self { file: root.join("api-assistants.json") }
    }

    pub fn all(&self) -> Result<Vec<ApiAssistant>> {
        let data = match std::fs::read(&self.file) {
            Ok(data) => data,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
            Err(error) => return Err(error.into()),
        };
        if data.len() > 65_536 {
            return Err(Error::invalid("Invalid assistant configuration file."));
        }
        let values: Vec<ApiAssistant> = serde_json::from_slice(&data)?;
        for value in &values {
            value.validate()?;
        }
        Ok(values)
    }

    pub fn load(&self, agent: Agent) -> Result<Option<ApiAssistant>> {
        Ok(self.all()?.into_iter().find(|value| value.agent == agent))
    }

    pub fn save(&self, value: ApiAssistant) -> Result<()> {
        value.validate()?;
        let mut values = self.all()?;
        values.retain(|existing| existing.agent != value.agent);
        values.push(value);
        paths::write_atomic(&self.file, &serde_json::to_vec_pretty(&values)?)
    }

    pub fn remove(&self, agent: Agent) -> Result<()> {
        let values: Vec<_> = self.all()?.into_iter().filter(|value| value.agent != agent).collect();
        paths::write_atomic(&self.file, &serde_json::to_vec_pretty(&values)?)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn missing_state_is_a_fresh_profile() {
        let root = tempfile::tempdir().unwrap();
        let state = WorkshopStore::new(root.path()).load().unwrap();
        assert!(!state.arabic, "English must be the default for new installations");
        assert!(state.team.is_none());
        assert!(!state.allow_paid_fallback, "paid fallback must require an explicit choice");
    }

    #[test]
    fn openrouter_cannot_leave_its_official_endpoint() {
        let mut assistant = ApiAssistant::preset(Agent::Openrouter);
        assistant.model = "openai/gpt".into();
        assert!(assistant.validate().is_ok());
        assistant.endpoint = "https://evil.example/api/v1/chat/completions".into();
        assert!(assistant.validate().is_err());
    }

    #[test]
    fn plain_http_is_loopback_only() {
        let mut assistant = ApiAssistant::preset(Agent::OpenAiApi);
        assistant.endpoint = "http://10.0.0.5/v1/chat/completions".into();
        assert!(assistant.validate().is_err());
        assistant.endpoint = "http://127.0.0.1:8080/v1/chat/completions".into();
        assert!(assistant.validate().is_ok());
    }

    #[test]
    fn endpoints_cannot_carry_credentials() {
        let mut assistant = ApiAssistant::preset(Agent::OpenAiApi);
        assistant.endpoint = "https://user:pw@api.openai.com/v1/chat/completions".into();
        assert!(assistant.validate().is_err());
    }
}
