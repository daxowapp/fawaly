use crate::client_link::{launcher_path, ClientLink};
use crate::daily::{self, DailyReadingState, DailySnapshot, DailyStore};
use crate::engine::{same_path, CLAUDE_TOKEN_ACCOUNT};
use crate::http::Transport;
use crate::model::{valid_model, AdvisorMode, Agent, TeamSettings, WorkshopState};
use crate::secrets::{self, SecretStore};
use crate::{paths, Error, Result};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::BTreeSet;
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

/// Records that the user connected the team, and which app version last saw that.
/// An installer's uninstall step removes the registration during an upgrade, so the
/// first launch of a different version puts it back. Within one version a missing
/// registration is the user's own choice. An explicit disconnect clears the marker.
pub struct TeamLinkMarker {
    file: PathBuf,
}

impl TeamLinkMarker {
    pub fn new(root: &Path) -> Self {
        Self { file: root.join("team-link.marker") }
    }

    pub fn present(&self) -> bool {
        self.file.is_file()
    }

    fn from_another_version(&self) -> bool {
        std::fs::read(&self.file).is_ok_and(|recorded| recorded != crate::VERSION.as_bytes())
    }

    pub fn set(&self) -> Result<()> {
        paths::write_atomic(&self.file, crate::VERSION.as_bytes())
    }

    pub fn clear(&self) -> Result<()> {
        match std::fs::remove_file(&self.file) {
            Err(error) if error.kind() != std::io::ErrorKind::NotFound => Err(error.into()),
            _ => Ok(()),
        }
    }
}

/// After an upgrade, reconnects a team whose registration the old uninstaller removed.
/// A registration that exists, even a foreign one, is left alone.
pub fn restore_team_link(link: &ClientLink, engine_source: &Path) -> Result<bool> {
    let engine = &link.engine;
    let marker = TeamLinkMarker::new(&engine.root);
    if !marker.from_another_version() {
        return Ok(false);
    }
    let Some(team) = WorkshopStore::new(&engine.root).load()?.team else {
        return Ok(false);
    };
    let Some(executable) = engine.executable(team.primary) else {
        return Ok(false);
    };
    let missing = link.entry(team.primary, &executable)?.is_none();
    if missing {
        link.connect(team.primary, engine_source)?;
    }
    // Recorded only now, so an upgrade whose reconnect failed is retried next launch.
    let _ = marker.set();
    Ok(missing)
}

/// Saved worker orders outlive a team edit. Workers who left the team are dropped,
/// and a worker who joined goes last, because the Rules page can only reorder.
pub fn apply_team(state: &mut WorkshopState, team: TeamSettings, mode: AdvisorMode) {
    if let Some(policy) = state.delegation_policy.as_mut() {
        policy.orders.retain(|_, order| {
            order.retain(|agent| team.workers.contains(agent));
            !order.is_empty()
        });
        for order in policy.orders.values_mut() {
            let joined: Vec<Agent> = team.workers.iter().copied().filter(|agent| !order.contains(agent)).collect();
            order.extend(joined);
        }
    }
    state.team = Some(team);
    state.advisors.mode = mode;
}

/// A registration that points somewhere else is not ours to remove or to fail on.
fn disconnect_own(link: &ClientLink, primary: Agent) -> Result<bool> {
    let Some(executable) = link.engine.executable(primary) else {
        return Ok(false);
    };
    match link.entry(primary, &executable)? {
        Some(entry) if same_path(Path::new(&entry.command), &launcher_path(&link.engine)) => link.disconnect(primary),
        _ => Ok(false),
    }
}

/// Finishes a team edit. Nothing is saved unless the new primary connects. Returns
/// the previous primary if its old registration could not be removed.
pub fn commit_team(link: &ClientLink, engine_source: &Path, team: TeamSettings, mode: AdvisorMode) -> Result<Option<Agent>> {
    team.validate()?;
    let store = WorkshopStore::new(&link.engine.root);
    let previous = store.load()?.team.map(|saved| saved.primary).filter(|primary| *primary != team.primary);
    link.connect(team.primary, engine_source)?;
    let mut state = store.load()?;
    apply_team(&mut state, team, mode);
    store.save(&state)?;
    // Only an upgrade reads this, and the connection above already succeeded.
    let _ = TeamLinkMarker::new(&link.engine.root).set();
    Ok(previous.filter(|primary| disconnect_own(link, *primary).is_err()))
}

fn in_language(arabic: bool, english: String, egyptian: String) -> Error {
    Error::invalid(if arabic { egyptian } else { english })
}

/// Nothing is deleted unless every registration of this app could be removed, so
/// an agent is never left pointing at a launcher that no longer exists.
pub fn remove_app_data(link: &ClientLink, arabic: bool) -> Result<()> {
    let engine = &link.engine;
    let lock = engine.lock_job().map_err(|_| {
        in_language(
            arabic,
            "Sudo Interns could not confirm that no task is running, so nothing was removed. Retry after any running task finishes.".to_string(),
            "مقدرناش نتأكد إن مفيش مهمة شغّالة، فمفيش حاجة اتمسحت. جرّب تاني لما أي مهمة شغّالة تخلص.".to_string(),
        )
    })?;
    // Cleared first: a removal that stops halfway must not reconnect on the next launch.
    TeamLinkMarker::new(&engine.root).clear()?;
    let remaining: Vec<&str> = Agent::PRIMARY.into_iter().filter(|primary| disconnect_own(link, *primary).is_err()).map(Agent::label).collect();
    if !remaining.is_empty() {
        let names = remaining.join(", ");
        return Err(in_language(
            arabic,
            format!("The team connection in {names} could not be removed, so your data was kept. Check that agent's settings and retry."),
            format!("ربط الفريق في {names} ما اتشالش، فبياناتك لسه زي ما هي. راجع إعدادات الأجنت ده وجرّب تاني."),
        ));
    }
    ApiAssistantStore::new(&engine.root).forget_all_keys(engine.secrets.as_ref())?;
    // Without a working keyring no token can be stored, and removal must still go on.
    let _ = engine.secrets.delete(CLAUDE_TOKEN_ACCOUNT);
    // The launcher may be running in an open agent session and the lock file is held
    // here. Both go last so everything else is already gone if Windows refuses them.
    let mut blocked = false;
    for entry in std::fs::read_dir(&engine.root)?.flatten() {
        let name = entry.file_name();
        if name == "bin" || name == "engine.lock" {
            continue;
        }
        let removed = if entry.file_type().is_ok_and(|kind| kind.is_dir()) { std::fs::remove_dir_all(entry.path()) } else { std::fs::remove_file(entry.path()) };
        blocked |= removed.is_err();
    }
    drop(lock);
    blocked |= std::fs::remove_dir_all(&engine.root).is_err();
    if blocked {
        return Err(in_language(
            arabic,
            "Some files are still in use, so not everything was removed. Close any open Codex or Claude Code sessions and retry.".to_string(),
            "فيه ملفات لسه مستخدمة، فمش كل حاجة اتمسحت. اقفل أي جلسة Codex أو Claude Code مفتوحة وجرّب تاني.".to_string(),
        ));
    }
    Ok(())
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize)]
pub struct DailyIssues {
    pub cache: bool,
    pub save: bool,
    pub reading: bool,
}

#[derive(Clone, Debug, Serialize)]
pub struct DailyPage {
    pub snapshot: DailySnapshot,
    pub reading: DailyReadingState,
    pub issues: DailyIssues,
}

/// What the Saved tab may show. The file on disk is left as it is.
pub fn shown_reading(mut reading: DailyReadingState, now: DateTime<Utc>) -> DailyReadingState {
    let saved = reading.saved.clone();
    reading.bookmarks.retain(|article| saved.contains(&article.url) && daily::valid_bookmark(article, now));
    reading.bookmarks.sort_by(|left, right| right.published.cmp(&left.published));
    reading
}

/// A damaged cache or reading file, or a full disk, must not take the news away.
pub fn load_daily(store: &DailyStore, transport: &Transport, force: bool, now: DateTime<Utc>) -> DailyPage {
    let mut issues = DailyIssues::default();
    let mut snapshot = store.load().unwrap_or_else(|_| {
        issues.cache = true;
        DailySnapshot::default()
    });
    if force || snapshot.due(now) {
        snapshot = daily::refresh(&snapshot, transport, now);
        issues.save = store.save_snapshot(&snapshot).is_err();
    }
    let reading = store.reading().map(|reading| shown_reading(reading, now)).unwrap_or_else(|_| {
        issues.reading = true;
        DailyReadingState::default()
    });
    DailyPage { snapshot, reading, issues }
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

    /// The assistant as the form shows it, checked before a typed key is attached.
    pub fn with_form_endpoint(mut self, endpoint: Option<&str>) -> Result<Self> {
        if let Some(endpoint) = endpoint {
            self.endpoint = endpoint.trim().to_string();
        }
        self.validate()?;
        Ok(self)
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
    /// Hashed account names of keys that were written, so removal can find a key
    /// whose endpoint is no longer in any profile. Holds no key material.
    accounts: PathBuf,
}

impl ApiAssistantStore {
    pub fn new(root: &Path) -> Self {
        Self { file: root.join("api-assistants.json"), accounts: root.join("api-key-accounts.json") }
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

    fn known_accounts(&self) -> BTreeSet<String> {
        std::fs::read(&self.accounts).ok().and_then(|data| serde_json::from_slice(&data).ok()).unwrap_or_default()
    }

    fn write_accounts(&self, accounts: &BTreeSet<String>) -> Result<()> {
        paths::write_atomic(&self.accounts, &serde_json::to_vec_pretty(accounts)?)
    }

    /// Stores the key and the profile. A key left under a previous endpoint is
    /// deleted once the new profile is safely saved.
    pub fn save_with_key(&self, secrets: &dyn SecretStore, value: ApiAssistant, key: Option<&str>) -> Result<()> {
        value.validate()?;
        let account = value.key_account();
        let previous = self.load(value.agent)?.map(|old| old.key_account()).filter(|old| *old != account);
        if let Some(key) = key {
            secrets::validate_key(key)?;
            // Listed first so a stored key is never unlisted. A key that was not stored
            // comes off the list, or removal would stop on a key that never existed.
            let mut accounts = self.known_accounts();
            let added = accounts.insert(account.clone());
            self.write_accounts(&accounts)?;
            if let Err(error) = secrets.set(&account, key) {
                if added {
                    accounts.remove(&account);
                    let _ = self.write_accounts(&accounts);
                }
                return Err(error);
            }
        } else if !value.is_local() && secrets.get(&account)?.is_none() {
            return Err(Error::invalid("Enter this service's key first."));
        }
        self.save(value)?;
        if let Some(old) = previous {
            // The profile is already saved. A key that cannot be deleted now stays
            // listed so that removing the service or the data can try again.
            let mut accounts = self.known_accounts();
            if secrets.delete(&old).is_ok() {
                accounts.remove(&old);
            } else {
                accounts.insert(old);
            }
            let _ = self.write_accounts(&accounts);
        }
        Ok(())
    }

    /// Removes the profile and every key this agent has stored.
    pub fn remove_with_key(&self, secrets: &dyn SecretStore, agent: Agent) -> Result<()> {
        let prefix = format!("{}:", agent.raw());
        self.forget_keys(secrets, |account| account.starts_with(&prefix))?;
        self.remove(agent)
    }

    pub fn forget_all_keys(&self, secrets: &dyn SecretStore) -> Result<()> {
        self.forget_keys(secrets, |_| true)
    }

    /// A local assistant works without a keyring, so a missing keyring must not
    /// block removing one. Any other key that cannot be deleted stops the removal.
    fn forget_keys(&self, secrets: &dyn SecretStore, wanted: impl Fn(&str) -> bool) -> Result<()> {
        let assistants = self.all()?;
        let local: BTreeSet<String> = assistants.iter().filter(|value| value.is_local()).map(ApiAssistant::key_account).collect();
        let known = self.known_accounts();
        let mut accounts = known.clone();
        accounts.extend(assistants.iter().map(ApiAssistant::key_account));
        let mut remaining = known.clone();
        for account in accounts.iter().filter(|account| wanted(account)) {
            match secrets.delete(account) {
                Ok(()) => {
                    remaining.remove(account);
                }
                Err(_) if local.contains(account) => {}
                Err(error) => return Err(error),
            }
        }
        if remaining != known {
            self.write_accounts(&remaining)?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api_worker::ApiWorker;
    use crate::client_link::{prepare_launcher, Execute, SERVER_NAME};
    use crate::daily::{DailyArticle, DailyTopic};
    use crate::engine::Engine;
    use crate::model::DelegationPolicy;
    use crate::process::LoginReply;
    use crate::secrets::MemorySecrets;
    use chrono::Duration;
    use serde_json::json;
    use std::collections::BTreeMap;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::{Arc, Mutex};

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

    /// A keyring that can be made to refuse deletes, or everything.
    #[derive(Default)]
    struct Keyring {
        inner: MemorySecrets,
        refuse_delete: AtomicBool,
        unavailable: AtomicBool,
    }

    impl SecretStore for Keyring {
        fn get(&self, account: &str) -> Result<Option<String>> {
            if self.unavailable.load(Ordering::SeqCst) {
                return Err(Error::invalid("keyring unavailable"));
            }
            self.inner.get(account)
        }

        fn set(&self, account: &str, value: &str) -> Result<()> {
            if self.unavailable.load(Ordering::SeqCst) {
                return Err(Error::invalid("keyring unavailable"));
            }
            self.inner.set(account, value)
        }

        fn delete(&self, account: &str) -> Result<()> {
            if self.unavailable.load(Ordering::SeqCst) || self.refuse_delete.load(Ordering::SeqCst) {
                return Err(Error::invalid("keyring unavailable"));
            }
            self.inner.delete(account)
        }
    }

    fn custom(endpoint: &str) -> ApiAssistant {
        let mut assistant = ApiAssistant::preset(Agent::OpenAiApi);
        assistant.endpoint = endpoint.into();
        assistant.model = "m".into();
        assistant
    }

    const ENDPOINT_A: &str = "https://a.example/v1/chat/completions";
    const ENDPOINT_B: &str = "https://b.example/v1/chat/completions";
    const LOOPBACK: &str = "http://127.0.0.1:4000/v1/chat/completions";

    #[test]
    fn a_typed_key_goes_only_to_the_endpoint_in_the_form() {
        let root = tempfile::tempdir().unwrap();
        let assistant = ApiAssistant::preset(Agent::OpenAiApi).with_form_endpoint(Some(ENDPOINT_A)).unwrap();
        let scratch = MemorySecrets::default();
        scratch.set(&assistant.key_account(), "typed").unwrap();
        let mut engine = Engine::with(root.path().join("d"), root.path().join("h"), Arc::new(scratch));
        let requests = Arc::new(Mutex::new(Vec::new()));
        let seen = requests.clone();
        engine.transport = Arc::new(move |request| {
            seen.lock().unwrap().push((request.url.clone(), request.headers.clone()));
            Ok((b"{\"data\":[]}".to_vec(), 200))
        });
        ApiWorker { engine: &engine, transport: engine.transport.clone(), stop_file: None }.models(&assistant).unwrap();
        let requests = requests.lock().unwrap();
        assert_eq!(requests.len(), 1);
        assert_eq!(requests[0].0, "https://a.example/v1/models");
        assert!(requests[0].1.iter().any(|(_, value)| value == "Bearer typed"));
    }

    #[test]
    fn a_form_endpoint_is_checked_before_any_key_is_attached() {
        assert!(ApiAssistant::preset(Agent::OpenAiApi).with_form_endpoint(Some("http://10.0.0.5/v1/chat/completions")).is_err());
        assert!(ApiAssistant::preset(Agent::OpenAiApi).with_form_endpoint(Some("  ")).is_err(), "a blank field must not fall back to the saved host");
        assert!(ApiAssistant::preset(Agent::Deepseek).with_form_endpoint(Some(ENDPOINT_A)).is_err());
        let unchanged = ApiAssistant::preset(Agent::Deepseek).with_form_endpoint(None).unwrap();
        assert_eq!(unchanged.endpoint, ApiAssistant::preset(Agent::Deepseek).endpoint);
    }

    #[test]
    fn changing_an_endpoint_deletes_the_key_saved_for_the_old_one() {
        let root = tempfile::tempdir().unwrap();
        let store = ApiAssistantStore::new(root.path());
        let keys = Keyring::default();
        store.save_with_key(&keys, custom(ENDPOINT_A), Some("key-a")).unwrap();
        store.save_with_key(&keys, custom(ENDPOINT_B), Some("key-b")).unwrap();
        assert_eq!(keys.get(&custom(ENDPOINT_A).key_account()).unwrap(), None);
        assert_eq!(keys.get(&custom(ENDPOINT_B).key_account()).unwrap().as_deref(), Some("key-b"));
    }

    #[test]
    fn a_key_that_could_not_be_deleted_is_still_removed_with_the_data() {
        let root = tempfile::tempdir().unwrap();
        let store = ApiAssistantStore::new(root.path());
        let keys = Keyring::default();
        store.save_with_key(&keys, custom(ENDPOINT_A), Some("key-a")).unwrap();
        keys.refuse_delete.store(true, Ordering::SeqCst);
        store.save_with_key(&keys, custom(ENDPOINT_B), Some("key-b")).unwrap();
        assert!(keys.get(&custom(ENDPOINT_A).key_account()).unwrap().is_some());
        keys.refuse_delete.store(false, Ordering::SeqCst);
        store.forget_all_keys(&keys).unwrap();
        assert_eq!(keys.get(&custom(ENDPOINT_A).key_account()).unwrap(), None);
        assert_eq!(keys.get(&custom(ENDPOINT_B).key_account()).unwrap(), None);
    }

    #[test]
    fn removing_a_loopback_service_deletes_its_key() {
        let root = tempfile::tempdir().unwrap();
        let store = ApiAssistantStore::new(root.path());
        let keys = Keyring::default();
        store.save_with_key(&keys, custom(LOOPBACK), Some("proxy-key")).unwrap();
        store.remove_with_key(&keys, Agent::OpenAiApi).unwrap();
        assert_eq!(keys.get(&custom(LOOPBACK).key_account()).unwrap(), None);
        assert!(store.load(Agent::OpenAiApi).unwrap().is_none());
    }

    #[test]
    fn a_missing_keyring_blocks_removing_only_keys_that_need_it() {
        let root = tempfile::tempdir().unwrap();
        let store = ApiAssistantStore::new(root.path());
        let keys = Keyring::default();
        store.save_with_key(&keys, custom(LOOPBACK), None).unwrap();
        keys.unavailable.store(true, Ordering::SeqCst);
        store.remove_with_key(&keys, Agent::OpenAiApi).unwrap();
        assert!(store.load(Agent::OpenAiApi).unwrap().is_none());
        keys.unavailable.store(false, Ordering::SeqCst);
        store.save_with_key(&keys, custom(ENDPOINT_A), Some("key-a")).unwrap();
        keys.unavailable.store(true, Ordering::SeqCst);
        assert!(store.remove_with_key(&keys, Agent::OpenAiApi).is_err());
        assert!(store.load(Agent::OpenAiApi).unwrap().is_some(), "the profile stays until its key is gone");
    }

    #[test]
    fn a_failed_key_write_saves_nothing() {
        let root = tempfile::tempdir().unwrap();
        let store = ApiAssistantStore::new(root.path());
        let keys = Keyring::default();
        keys.unavailable.store(true, Ordering::SeqCst);
        let mut assistant = ApiAssistant::preset(Agent::Openrouter);
        assistant.model = "openai/gpt".into();
        assert!(store.save_with_key(&keys, assistant, Some("sk-or")).is_err());
        assert!(store.load(Agent::Openrouter).unwrap().is_none());
    }

    #[test]
    fn a_key_that_was_never_stored_does_not_block_removing_data() {
        let root = tempfile::tempdir().unwrap();
        let store = ApiAssistantStore::new(root.path());
        let keys = Keyring::default();
        keys.unavailable.store(true, Ordering::SeqCst);
        assert!(store.save_with_key(&keys, custom(ENDPOINT_A), Some("key-a")).is_err());
        assert!(store.known_accounts().is_empty());
        store.forget_all_keys(&keys).unwrap();
    }

    #[test]
    fn a_failed_key_write_keeps_a_key_stored_earlier_listed() {
        let root = tempfile::tempdir().unwrap();
        let store = ApiAssistantStore::new(root.path());
        let keys = Keyring::default();
        store.save_with_key(&keys, custom(ENDPOINT_A), Some("key-a")).unwrap();
        keys.unavailable.store(true, Ordering::SeqCst);
        assert!(store.save_with_key(&keys, custom(ENDPOINT_A), Some("key-a2")).is_err());
        assert!(store.known_accounts().contains(&custom(ENDPOINT_A).key_account()));
        keys.unavailable.store(false, Ordering::SeqCst);
        store.forget_all_keys(&keys).unwrap();
        assert_eq!(keys.get(&custom(ENDPOINT_A).key_account()).unwrap(), None);
    }

    #[test]
    fn saved_orders_follow_the_team() {
        let mut state = WorkshopState::default();
        let orders = BTreeMap::from([("code".to_string(), vec![Agent::Zai, Agent::Kimi]), ("review".to_string(), vec![Agent::Minimax])]);
        state.delegation_policy = Some(DelegationPolicy { timeout_seconds: 120, orders });
        apply_team(&mut state, TeamSettings { primary: Agent::Codex, advisor: None, workers: vec![Agent::Kimi, Agent::Zai, Agent::Deepseek] }, AdvisorMode::Off);
        let policy = state.delegation_policy.clone().unwrap();
        assert_eq!(policy.timeout_seconds, 120);
        assert_eq!(policy.orders["code"], [Agent::Zai, Agent::Kimi, Agent::Deepseek]);
        assert!(!policy.orders.contains_key("review"), "an order with nobody left falls back to the team");
        policy.validate(state.team.as_ref()).unwrap();
    }

    struct Rig {
        _root: tempfile::TempDir,
        link: ClientLink,
        calls: Arc<Mutex<Vec<Vec<String>>>>,
        source: PathBuf,
        codex_registered: Arc<AtomicBool>,
        refuse_add: Arc<AtomicBool>,
        refuse_remove: Arc<AtomicBool>,
    }

    /// Stands in for the official CLIs and the launcher's engine check.
    fn rig() -> Rig {
        let root = tempfile::tempdir().unwrap();
        let home = root.path().join("home");
        std::fs::create_dir_all(&home).unwrap();
        let engine = Engine::with(root.path().join("data"), home.clone(), Arc::new(MemorySecrets::default()));
        for agent in Agent::PRIMARY {
            let runtime = engine.runtime_dir(agent);
            std::fs::create_dir_all(&runtime).unwrap();
            std::fs::write(runtime.join(paths::exe_name(agent.raw())), "x").unwrap();
        }
        let source = root.path().join("source-engine");
        std::fs::write(&source, "engine").unwrap();
        let launcher = launcher_path(&engine).to_string_lossy().to_string();
        let calls = Arc::new(Mutex::new(Vec::new()));
        let (codex_registered, refuse_add, refuse_remove) = (Arc::new(AtomicBool::new(false)), Arc::new(AtomicBool::new(false)), Arc::new(AtomicBool::new(false)));
        let (seen, codex, no_add, no_remove) = (calls.clone(), codex_registered.clone(), refuse_add.clone(), refuse_remove.clone());
        let file = home.join(".claude.json");
        let execute: Execute = Arc::new(move |command, _| {
            if command.input.is_some() {
                return Ok(LoginReply { output: "{\"id\":2,\"result\":{\"tools\":[{\"name\":\"roster_get\"},{\"name\":\"consult\"},{\"name\":\"delegate\"}]}}\n".into(), ..Default::default() });
            }
            seen.lock().unwrap().push(command.arguments.clone());
            let arguments: Vec<&str> = command.arguments.iter().map(String::as_str).collect();
            let refused = LoginReply { exit_code: 1, ..Default::default() };
            Ok(match arguments.as_slice() {
                ["mcp", "get", ..] if codex.load(Ordering::SeqCst) => LoginReply { output: json!({"transport": {"command": launcher, "args": ["mcp", "--client", "codex"]}}).to_string(), ..Default::default() },
                ["mcp", "get", ..] => LoginReply { exit_code: 1, error_output: "No MCP server named".into(), ..Default::default() },
                ["mcp", "add", ..] if no_add.load(Ordering::SeqCst) => refused,
                ["mcp", "add", "--scope", ..] => {
                    std::fs::write(&file, json!({"mcpServers": {SERVER_NAME: {"command": launcher, "args": ["mcp", "--client", "claude"]}}}).to_string()).unwrap();
                    LoginReply::default()
                }
                ["mcp", "add", ..] => {
                    codex.store(true, Ordering::SeqCst);
                    LoginReply::default()
                }
                ["mcp", "remove", ..] if no_remove.load(Ordering::SeqCst) => refused,
                ["mcp", "remove", "--scope", ..] => {
                    std::fs::remove_file(&file).unwrap();
                    LoginReply::default()
                }
                ["mcp", "remove", ..] => {
                    codex.store(false, Ordering::SeqCst);
                    LoginReply::default()
                }
                _ => LoginReply::default(),
            })
        });
        Rig { _root: root, link: ClientLink { engine, execute, write_codex_timeout: false }, calls, source, codex_registered, refuse_add, refuse_remove }
    }

    impl Rig {
        fn root(&self) -> &Path {
            &self.link.engine.root
        }

        fn claude_is_registered(&self) -> bool {
            self.link.engine.home.join(".claude.json").exists()
        }

        fn save_team(&self, team: TeamSettings) {
            let state = WorkshopState { team: Some(team), delegation_policy: Some(DelegationPolicy { timeout_seconds: 300, orders: BTreeMap::new() }), ..Default::default() };
            WorkshopStore::new(self.root()).save(&state).unwrap();
        }

        fn saved_team(&self) -> Option<TeamSettings> {
            WorkshopStore::new(self.root()).load().unwrap().team
        }

        fn mark_connected_by_an_older_version(&self) {
            std::fs::write(self.root().join("team-link.marker"), "0.0.1").unwrap();
        }

        fn add_calls(&self) -> usize {
            self.calls.lock().unwrap().iter().filter(|call| call[1] == "add").count()
        }
    }

    fn claude_team() -> TeamSettings {
        TeamSettings { primary: Agent::Claude, advisor: None, workers: vec![Agent::Kimi] }
    }

    fn codex_team() -> TeamSettings {
        TeamSettings { primary: Agent::Codex, advisor: None, workers: vec![Agent::Kimi] }
    }

    #[test]
    fn a_marked_team_is_reconnected_after_an_upgrade_removed_it() {
        let rig = rig();
        rig.save_team(claude_team());
        rig.mark_connected_by_an_older_version();
        assert!(restore_team_link(&rig.link, &rig.source).unwrap());
        assert!(rig.claude_is_registered());
    }

    #[test]
    fn a_registration_the_user_removed_is_not_put_back() {
        let rig = rig();
        rig.save_team(codex_team());
        TeamLinkMarker::new(rig.root()).set().unwrap();
        assert!(!restore_team_link(&rig.link, &rig.source).unwrap());
        assert_eq!(rig.add_calls(), 0);
    }

    #[test]
    fn an_upgrade_reconnects_once() {
        let rig = rig();
        rig.save_team(codex_team());
        rig.mark_connected_by_an_older_version();
        assert!(restore_team_link(&rig.link, &rig.source).unwrap());
        rig.codex_registered.store(false, Ordering::SeqCst);
        assert!(!restore_team_link(&rig.link, &rig.source).unwrap());
        assert_eq!(rig.add_calls(), 1);
    }

    #[test]
    fn an_upgrade_that_found_the_team_connected_is_recorded() {
        let rig = rig();
        rig.save_team(codex_team());
        rig.mark_connected_by_an_older_version();
        rig.codex_registered.store(true, Ordering::SeqCst);
        assert!(!restore_team_link(&rig.link, &rig.source).unwrap());
        rig.codex_registered.store(false, Ordering::SeqCst);
        assert!(!restore_team_link(&rig.link, &rig.source).unwrap());
        assert_eq!(rig.add_calls(), 0);
    }

    #[test]
    fn a_failed_reconnect_is_retried_at_the_next_launch() {
        let rig = rig();
        rig.save_team(codex_team());
        rig.mark_connected_by_an_older_version();
        rig.refuse_add.store(true, Ordering::SeqCst);
        assert!(restore_team_link(&rig.link, &rig.source).is_err());
        rig.refuse_add.store(false, Ordering::SeqCst);
        assert!(restore_team_link(&rig.link, &rig.source).unwrap());
    }

    #[test]
    fn nothing_reconnects_without_the_marker() {
        let rig = rig();
        rig.save_team(claude_team());
        assert!(!restore_team_link(&rig.link, &rig.source).unwrap());
        assert!(!rig.claude_is_registered());
        assert!(rig.calls.lock().unwrap().is_empty());
    }

    #[test]
    fn the_marker_can_be_set_and_cleared_repeatedly() {
        let folder = tempfile::tempdir().unwrap();
        let marker = TeamLinkMarker::new(folder.path());
        marker.set().unwrap();
        assert!(marker.present());
        marker.clear().unwrap();
        marker.clear().unwrap();
        assert!(!marker.present());
    }

    #[test]
    fn an_existing_registration_is_left_alone_and_a_failed_reconnect_is_only_an_error() {
        let rig = rig();
        rig.save_team(codex_team());
        rig.mark_connected_by_an_older_version();
        rig.codex_registered.store(true, Ordering::SeqCst);
        assert!(!restore_team_link(&rig.link, &rig.source).unwrap());
        assert_eq!(rig.add_calls(), 0);
        rig.mark_connected_by_an_older_version();
        rig.codex_registered.store(false, Ordering::SeqCst);
        rig.refuse_add.store(true, Ordering::SeqCst);
        assert!(restore_team_link(&rig.link, &rig.source).is_err());
    }

    #[test]
    fn a_team_edit_is_not_saved_unless_the_new_primary_connects() {
        let rig = rig();
        rig.save_team(codex_team());
        rig.codex_registered.store(true, Ordering::SeqCst);
        rig.refuse_add.store(true, Ordering::SeqCst);
        assert!(commit_team(&rig.link, &rig.source, claude_team(), AdvisorMode::Off).is_err());
        assert_eq!(rig.saved_team(), Some(codex_team()));
        assert!(rig.codex_registered.load(Ordering::SeqCst), "the working connection must survive");
    }

    #[test]
    fn committing_a_new_primary_disconnects_the_previous_one() {
        let rig = rig();
        rig.save_team(codex_team());
        rig.codex_registered.store(true, Ordering::SeqCst);
        assert_eq!(commit_team(&rig.link, &rig.source, claude_team(), AdvisorMode::Off).unwrap(), None);
        assert_eq!(rig.saved_team(), Some(claude_team()));
        assert!(rig.claude_is_registered());
        assert!(!rig.codex_registered.load(Ordering::SeqCst));
        assert!(TeamLinkMarker::new(rig.root()).present());
        assert_eq!(WorkshopStore::new(rig.root()).load().unwrap().delegation_policy.unwrap().timeout_seconds, 300);
    }

    #[test]
    fn a_previous_primary_that_stays_registered_is_reported() {
        let rig = rig();
        rig.save_team(codex_team());
        rig.codex_registered.store(true, Ordering::SeqCst);
        rig.refuse_remove.store(true, Ordering::SeqCst);
        assert_eq!(commit_team(&rig.link, &rig.source, claude_team(), AdvisorMode::Off).unwrap(), Some(Agent::Codex));
        assert_eq!(rig.saved_team(), Some(claude_team()));
    }

    #[test]
    fn a_failed_disconnect_keeps_the_data_and_is_reported() {
        let rig = rig();
        rig.save_team(codex_team());
        rig.codex_registered.store(true, Ordering::SeqCst);
        rig.refuse_remove.store(true, Ordering::SeqCst);
        let store = ApiAssistantStore::new(rig.root());
        store.save_with_key(rig.link.engine.secrets.as_ref(), custom(ENDPOINT_A), Some("key-a")).unwrap();
        let error = remove_app_data(&rig.link, false).unwrap_err().to_string();
        assert!(error.contains("Codex"), "{error}");
        assert!(remove_app_data(&rig.link, true).unwrap_err().to_string().contains("بياناتك"));
        assert!(rig.saved_team().is_some());
        assert!(rig.link.engine.secrets.get(&custom(ENDPOINT_A).key_account()).unwrap().is_some());
    }

    #[test]
    fn data_is_not_removed_while_a_job_runs() {
        let rig = rig();
        rig.save_team(codex_team());
        rig.codex_registered.store(true, Ordering::SeqCst);
        let running = rig.link.engine.lock_worker_access().unwrap();
        assert!(remove_app_data(&rig.link, false).unwrap_err().to_string().contains("running"));
        assert!(rig.saved_team().is_some());
        assert!(rig.codex_registered.load(Ordering::SeqCst));
        assert!(rig.calls.lock().unwrap().is_empty());
        drop(running);
    }

    #[test]
    fn removing_data_clears_the_connection_keys_and_folder() {
        let rig = rig();
        rig.save_team(codex_team());
        rig.codex_registered.store(true, Ordering::SeqCst);
        TeamLinkMarker::new(rig.root()).set().unwrap();
        let store = ApiAssistantStore::new(rig.root());
        let secrets = rig.link.engine.secrets.clone();
        store.save_with_key(secrets.as_ref(), custom(ENDPOINT_A), Some("key-a")).unwrap();
        secrets.set(CLAUDE_TOKEN_ACCOUNT, "token").unwrap();
        prepare_launcher(&rig.link.engine, &rig.source).unwrap();
        remove_app_data(&rig.link, false).unwrap();
        assert!(!rig.root().exists());
        assert!(!rig.codex_registered.load(Ordering::SeqCst));
        assert_eq!(secrets.get(&custom(ENDPOINT_A).key_account()).unwrap(), None);
        assert_eq!(secrets.get(CLAUDE_TOKEN_ACCOUNT).unwrap(), None);
    }

    fn offline() -> Transport {
        Arc::new(|_| Ok((Vec::new(), 503)))
    }

    #[test]
    fn a_damaged_news_cache_is_replaced_by_a_refresh() {
        let root = tempfile::tempdir().unwrap();
        std::fs::write(root.path().join("developer-daily.json"), "{not json").unwrap();
        let store = DailyStore::new(root.path());
        let page = load_daily(&store, &offline(), false, Utc::now());
        assert_eq!(page.issues, DailyIssues { cache: true, save: false, reading: false });
        assert!(page.snapshot.checked_at.is_some());
        assert!(store.load().is_ok(), "the damaged file must be overwritten");
    }

    #[test]
    fn a_damaged_reading_file_is_reported_and_left_in_place() {
        let root = tempfile::tempdir().unwrap();
        let file = root.path().join("developer-daily-reading.json");
        std::fs::write(&file, "{not json").unwrap();
        let page = load_daily(&DailyStore::new(root.path()), &offline(), false, Utc::now());
        assert!(page.issues.reading);
        assert_eq!(std::fs::read_to_string(file).unwrap(), "{not json");
    }

    #[test]
    fn news_that_cannot_be_saved_is_still_shown() {
        let root = tempfile::tempdir().unwrap();
        let blocked = root.path().join("file");
        std::fs::write(&blocked, "").unwrap();
        let page = load_daily(&DailyStore::new(&blocked), &offline(), true, Utc::now());
        assert!(page.issues.save);
        assert!(page.snapshot.checked_at.is_some());
    }

    #[test]
    fn saved_articles_stay_after_they_leave_the_news_window() {
        let root = tempfile::tempdir().unwrap();
        let now = Utc::now();
        let article = |path: &str, age: i64| DailyArticle { source_id: "github".into(), title: "Title".into(), url: format!("https://github.blog/{path}"), published: now - Duration::days(age), topic: DailyTopic::Coding };
        let (old, older, unsaved) = (article("old", 30), article("older", 90), article("unsaved", 30));
        let mut tampered = article("tampered", 30);
        tampered.url = "https://evil.example/x".into();
        let store = DailyStore::new(root.path());
        let reading = DailyReadingState {
            saved: [&old, &older, &tampered].into_iter().map(|item| item.url.clone()).collect(),
            read: BTreeSet::new(),
            bookmarks: vec![older.clone(), tampered, unsaved, old.clone()],
        };
        store.save_reading(&reading).unwrap();
        let page = load_daily(&store, &offline(), false, now);
        assert_eq!(page.reading.bookmarks, [old, older]);
        assert_eq!(store.reading().unwrap().bookmarks.len(), 4, "filtering is for display only");
    }
}
