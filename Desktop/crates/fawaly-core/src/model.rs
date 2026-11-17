use crate::{Error, Result};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::PathBuf;
use uuid::Uuid;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
pub enum Agent {
    #[serde(rename = "codex")]
    Codex,
    #[serde(rename = "claude")]
    Claude,
    #[serde(rename = "kimi")]
    Kimi,
    #[serde(rename = "zai")]
    Zai,
    #[serde(rename = "minimax")]
    Minimax,
    #[serde(rename = "deepseek")]
    Deepseek,
    #[serde(rename = "openrouter")]
    Openrouter,
    #[serde(rename = "anthropicAPI")]
    AnthropicApi,
    #[serde(rename = "openAIAPI")]
    OpenAiApi,
    #[serde(rename = "ollama")]
    Ollama,
    #[serde(rename = "lmstudio")]
    Lmstudio,
}

impl Agent {
    pub const ALL: [Agent; 11] = [
        Agent::Codex,
        Agent::Claude,
        Agent::Kimi,
        Agent::Zai,
        Agent::Minimax,
        Agent::Deepseek,
        Agent::Openrouter,
        Agent::AnthropicApi,
        Agent::OpenAiApi,
        Agent::Ollama,
        Agent::Lmstudio,
    ];
    pub const NATIVE: [Agent; 3] = [Agent::Codex, Agent::Claude, Agent::Kimi];
    pub const PRIMARY: [Agent; 2] = [Agent::Codex, Agent::Claude];

    pub fn raw(self) -> &'static str {
        match self {
            Agent::Codex => "codex",
            Agent::Claude => "claude",
            Agent::Kimi => "kimi",
            Agent::Zai => "zai",
            Agent::Minimax => "minimax",
            Agent::Deepseek => "deepseek",
            Agent::Openrouter => "openrouter",
            Agent::AnthropicApi => "anthropicAPI",
            Agent::OpenAiApi => "openAIAPI",
            Agent::Ollama => "ollama",
            Agent::Lmstudio => "lmstudio",
        }
    }
    pub fn provider_id(self) -> String {
        format!("{}-official", self.raw())
    }
    pub fn label(self) -> &'static str {
        match self {
            Agent::Codex => "Codex",
            Agent::Claude => "Claude Code",
            Agent::Kimi => "Kimi",
            Agent::Zai => "Z.AI (GLM)",
            Agent::Minimax => "MiniMax",
            Agent::Deepseek => "DeepSeek",
            Agent::Openrouter => "OpenRouter",
            Agent::AnthropicApi => "Anthropic-compatible API",
            Agent::OpenAiApi => "OpenAI-compatible API",
            Agent::Ollama => "Ollama",
            Agent::Lmstudio => "LM Studio",
        }
    }
    pub fn is_native(self) -> bool {
        Self::NATIVE.contains(&self)
    }
    pub fn is_primary(self) -> bool {
        Self::PRIMARY.contains(&self)
    }
    pub fn billing(self) -> &'static str {
        if self.is_native() {
            "subscription"
        } else if matches!(self, Agent::Ollama | Agent::Lmstudio) {
            "local_endpoint"
        } else {
            "provider_account"
        }
    }
    pub fn from_provider(value: &str) -> Option<Agent> {
        Self::ALL.iter().copied().find(|agent| agent.provider_id() == value || agent.raw() == value)
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AdvisorMode {
    Off,
    #[default]
    OnRequest,
    Important,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct AdvisorSeat {
    pub provider: String,
    pub model: String,
    pub enabled: bool,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct AdvisorSettings {
    pub mode: AdvisorMode,
    pub max_rounds: u32,
    pub timeout_minutes: u64,
    pub seats: Vec<AdvisorSeat>,
}

impl Default for AdvisorSettings {
    fn default() -> Self {
        Self { mode: AdvisorMode::OnRequest, max_rounds: 3, timeout_minutes: 2, seats: Vec::new() }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct TeamSettings {
    pub primary: Agent,
    pub advisor: Option<Agent>,
    pub workers: Vec<Agent>,
}

impl TeamSettings {
    pub fn validate(&self) -> Result<()> {
        let mut seen = self.workers.clone();
        seen.sort();
        seen.dedup();
        let unique = seen.len() == self.workers.len();
        let separated = self.advisor != Some(self.primary)
            && !self.workers.contains(&self.primary)
            && self.advisor.is_none_or(|advisor| !self.workers.contains(&advisor));
        if self.primary.is_primary() && unique && separated {
            Ok(())
        } else {
            Err(Error::invalid("Choose a different agent for each team role."))
        }
    }

    pub fn supporters(&self) -> Vec<Agent> {
        Agent::ALL.iter().copied().filter(|agent| self.advisor == Some(*agent) || self.workers.contains(agent)).collect()
    }
}

pub const TASK_KINDS: [&str; 4] = ["general", "code", "research", "review"];

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct DelegationPolicy {
    pub timeout_seconds: u64,
    pub orders: BTreeMap<String, Vec<Agent>>,
}

impl Default for DelegationPolicy {
    fn default() -> Self {
        Self { timeout_seconds: 900, orders: BTreeMap::new() }
    }
}

impl DelegationPolicy {
    pub fn validate(&self, team: Option<&TeamSettings>) -> Result<()> {
        let valid_orders = self.orders.iter().all(|(kind, order)| {
            let mut unique = order.clone();
            unique.sort();
            unique.dedup();
            TASK_KINDS.contains(&kind.as_str())
                && unique.len() == order.len()
                && order.iter().all(|agent| team.is_some_and(|team| team.workers.contains(agent)))
        });
        if (1..=3600).contains(&self.timeout_seconds) && valid_orders {
            Ok(())
        } else {
            Err(Error::invalid("Choose a timeout from 1 to 3600 seconds and an order of assigned workers."))
        }
    }

    pub fn workers(&self, kind: Option<&str>, team: &TeamSettings) -> Vec<Agent> {
        let order = self.orders.get(kind.unwrap_or("general")).cloned().unwrap_or_default();
        if order.is_empty() {
            team.workers.clone()
        } else {
            order.into_iter().filter(|agent| team.workers.contains(agent)).collect()
        }
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Appearance {
    #[default]
    System,
    Light,
    Dark,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct WorkshopState {
    pub arabic: bool,
    pub advisors: AdvisorSettings,
    pub onboarding_version: Option<u32>,
    pub team: Option<TeamSettings>,
    pub project_directory: Option<PathBuf>,
    pub kimi_region: Option<String>,
    pub worker_models: BTreeMap<String, String>,
    pub delegation_policy: Option<DelegationPolicy>,
    pub appearance: Appearance,
    /// Off by default: a busy assigned worker never rolls over to a paid one.
    pub allow_paid_fallback: bool,
    /// Off by default: Kimi on Windows has no enforceable file boundary.
    pub allow_unconfined_windows_kimi: bool,
    /// Off by default: without Landlock, native workers cannot edit a project.
    pub allow_unconfined_linux_workers: bool,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ReviewDecision {
    Accepted,
    ChangesRequested,
    Rejected,
}

impl ReviewDecision {
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "accepted" => Some(Self::Accepted),
            "changes_requested" => Some(Self::ChangesRequested),
            "rejected" => Some(Self::Rejected),
            _ => None,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct TeamReview {
    pub decision: ReviewDecision,
    pub primary: Agent,
    pub summary: String,
    pub verification: String,
    pub score: Option<u8>,
    pub created: DateTime<Utc>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TeamJob {
    pub id: Uuid,
    pub primary: Option<Agent>,
    pub worker: Agent,
    pub title: String,
    pub status: String,
    pub started: DateTime<Utc>,
    pub finished: Option<DateTime<Utc>>,
    pub result: Option<String>,
    pub review_required: bool,
    #[serde(default)]
    pub reviews: Vec<TeamReview>,
    #[serde(default)]
    pub confinement: Option<String>,
    #[serde(default)]
    pub git_changes: Vec<String>,
    /// The project was too large to check every .git file.
    #[serde(default)]
    pub git_scan_incomplete: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ConsultReason {
    UserRequest,
    Plan,
    RiskyChange,
    DisputedReview,
}

impl ConsultReason {
    pub const NAMES: [&'static str; 4] = ["user_request", "plan", "risky_change", "disputed_review"];
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "user_request" => Some(Self::UserRequest),
            "plan" => Some(Self::Plan),
            "risky_change" => Some(Self::RiskyChange),
            "disputed_review" => Some(Self::DisputedReview),
            _ => None,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ConsultDecision {
    Adopted,
    Partly,
    Rejected,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ConsultStatus {
    Open,
    Closed,
    NoDecision,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ConsultRound {
    pub index: usize,
    pub prompt: String,
    pub advice: String,
    pub truncated: bool,
    pub status: String,
    pub started_at: DateTime<Utc>,
    pub finished_at: DateTime<Utc>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ConsultRecord {
    pub id: Uuid,
    pub caller: Agent,
    pub reason: ConsultReason,
    pub provider: String,
    pub model: String,
    pub requested_model: Option<String>,
    pub model_pinned: bool,
    pub mode_at_start: AdvisorMode,
    pub question: String,
    /// Only a fingerprint and size of the shared context are kept.
    #[serde(rename = "contextSHA256")]
    pub context_sha256: Option<String>,
    pub context_bytes: usize,
    pub rounds: Vec<ConsultRound>,
    pub status: ConsultStatus,
    pub decision: Option<ConsultDecision>,
    pub summary: Option<String>,
    pub created: DateTime<Utc>,
    pub updated: DateTime<Utc>,
    /// What limited the advisor's latest round. Left out when absent, so a
    /// record saved before this field still matches its stored text on update.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub confinement: Option<String>,
}

pub const ADVICE_LIMIT: usize = 64 * 1024;

/// Truncates on a character boundary.
pub fn cap_text(text: &str, limit: usize) -> (String, bool) {
    if text.len() <= limit {
        return (text.to_string(), false);
    }
    let mut end = limit;
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    (text[..end].to_string(), true)
}

pub fn valid_model(value: &str) -> bool {
    let mut characters = value.chars();
    let starts_well = characters.next().is_some_and(|c| c.is_ascii_alphanumeric());
    starts_well
        && value.len() <= 128
        && characters.all(|c| c.is_ascii_alphanumeric() || "._:/[]-".contains(c))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn team_rejects_duplicate_roles() {
        let team = TeamSettings { primary: Agent::Codex, advisor: Some(Agent::Claude), workers: vec![Agent::Claude] };
        assert!(team.validate().is_err());
        let team = TeamSettings { primary: Agent::Kimi, advisor: None, workers: vec![] };
        assert!(team.validate().is_err());
        let team = TeamSettings { primary: Agent::Claude, advisor: Some(Agent::Codex), workers: vec![Agent::Kimi, Agent::Zai] };
        assert!(team.validate().is_ok());
    }

    #[test]
    fn agent_wire_names_match_the_mac_engine() {
        assert_eq!(serde_json::to_string(&Agent::AnthropicApi).unwrap(), "\"anthropicAPI\"");
        assert_eq!(Agent::from_provider("openrouter-official"), Some(Agent::Openrouter));
        assert_eq!(Agent::from_provider("kimi"), Some(Agent::Kimi));
        assert_eq!(serde_json::to_string(&AdvisorMode::OnRequest).unwrap(), "\"on_request\"");
    }

    #[test]
    fn caps_text_on_a_character_boundary() {
        let (text, truncated) = cap_text("فواعلي", 3);
        assert!(truncated);
        assert_eq!(text, "ف");
    }

    #[test]
    fn model_ids_are_bounded() {
        assert!(valid_model("nvidia/nemotron-3.5-lightning:free"));
        assert!(!valid_model("bad model"));
        assert!(!valid_model("-leading"));
    }
}
