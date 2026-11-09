use crate::engine::Engine;
use crate::log::{ApiUsage, ConsultLog, TeamJobLog};
use crate::model::*;
use crate::native::{self, WorkerOutcome};
use crate::store::{ApiAssistantStore, WorkshopStore};
use crate::{Error, Result};
use chrono::Utc;
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use uuid::Uuid;

pub type WorkerFn = Arc<dyn Fn(Agent, &str, Option<&Path>, u64, Option<PathBuf>, Option<String>) -> Result<WorkerOutcome> + Send + Sync>;
pub type ReadyFn = Arc<dyn Fn(Agent) -> bool + Send + Sync>;

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Availability {
    pub provider: String,
    pub status: String,
    pub worker_model: Option<String>,
    pub billing: &'static str,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Status {
    pub providers: BTreeMap<String, Availability>,
    pub advisor: AdvisorSettings,
    pub team: Option<TeamSettings>,
    pub delegation: DelegationPolicy,
    pub project_directory: Option<PathBuf>,
    pub active: Vec<String>,
    pub language: &'static str,
    pub allow_paid_fallback: bool,
    pub platform: &'static str,
    pub schema: &'static str,
    pub version: &'static str,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DelegateResult {
    pub status: String,
    pub provider: String,
    pub model: String,
    pub final_message: String,
    pub review_required: bool,
    pub changed_files: Option<Vec<String>>,
    pub schema: &'static str,
    pub job_id: Uuid,
    pub billing: &'static str,
    pub confinement: Option<&'static str>,
    pub git_changes: Vec<String>,
}

#[derive(Clone)]
pub struct Bridge {
    pub engine: Engine,
    pub client: Option<Agent>,
    worker: WorkerFn,
    ready: ReadyFn,
}

pub struct DelegateRequest<'a> {
    pub brief: &'a str,
    pub cwd: Option<&'a str>,
    pub provider: Option<&'a str>,
    pub timeout: Option<u64>,
    pub kind: Option<&'a str>,
    pub title: Option<&'a str>,
}

impl Bridge {
    pub fn new(engine: Engine, client: Option<Agent>) -> Self {
        let for_worker = engine.clone();
        let for_ready = engine.clone();
        Self {
            engine,
            client,
            worker: Arc::new(move |agent, prompt, workspace, timeout, stop, model| native::run(&for_worker, agent, prompt, workspace, timeout, stop, model)),
            ready: Arc::new(move |agent| for_ready.is_ready(agent)),
        }
    }

    pub fn with_doubles(engine: Engine, client: Option<Agent>, worker: WorkerFn, ready: ReadyFn) -> Self {
        Self { engine, client, worker, ready }
    }

    fn state(&self) -> Result<WorkshopState> {
        WorkshopStore::new(&self.engine.root).load()
    }

    fn has_capacity(&self, agent: Agent) -> Result<bool> {
        if agent.is_native() {
            return Ok(true);
        }
        match ApiAssistantStore::new(&self.engine.root).load(agent)? {
            Some(profile) => Ok(ApiUsage::new(&self.engine.root).totals(agent)?.requests < i64::from(profile.daily_request_limit)),
            None => Ok(true),
        }
    }

    fn selected_model(&self, state: &WorkshopState, agent: Agent) -> Result<Option<String>> {
        if let Some(model) = state.worker_models.get(agent.raw()) {
            return Ok(Some(model.clone()));
        }
        if agent.is_native() {
            return Ok(None);
        }
        Ok(ApiAssistantStore::new(&self.engine.root).load(agent)?.map(|profile| profile.model))
    }

    pub fn status(&self) -> Result<Status> {
        let state = self.state()?;
        let mut providers = BTreeMap::new();
        for agent in Agent::ALL {
            let configured = if agent.is_native() { None } else { ApiAssistantStore::new(&self.engine.root).load(agent)? };
            let status = if (self.ready)(agent) {
                if !self.has_capacity(agent)? {
                    "local_limit_reached"
                } else if self.engine.is_working(agent) {
                    "busy"
                } else {
                    "available"
                }
            } else if configured.as_ref().is_some_and(|profile| !profile.enabled) {
                "paused"
            } else {
                "authentication_required"
            };
            let worker_model = state.worker_models.get(agent.raw()).cloned().or(configured.map(|profile| profile.model));
            providers.insert(agent.provider_id(), Availability { provider: agent.provider_id(), status: status.to_string(), worker_model, billing: agent.billing() });
        }
        let mut advisor = state.advisors.clone();
        if let Some(team) = &state.team {
            advisor.seats = team
                .advisor
                .map(|agent| {
                    vec![AdvisorSeat {
                        provider: agent.provider_id(),
                        model: providers.get(&agent.provider_id()).and_then(|entry| entry.worker_model.clone()).unwrap_or_else(|| "default".to_string()),
                        enabled: (self.ready)(agent),
                    }]
                })
                .unwrap_or_default();
        }
        let active = TeamJobLog::new(&self.engine.root).recent(50)?.into_iter().filter(|job| job.status == "running").map(|job| job.id.to_string()).collect();
        Ok(Status {
            providers,
            advisor,
            team: state.team.clone(),
            delegation: state.delegation_policy.clone().unwrap_or_default(),
            project_directory: state.project_directory.clone(),
            active,
            language: if state.arabic { "ar" } else { "en" },
            allow_paid_fallback: state.allow_paid_fallback,
            platform: std::env::consts::OS,
            schema: "delegate-relay.availability.v1",
            version: concat!("desktop-", env!("CARGO_PKG_VERSION")),
        })
    }

    fn available(&self, agent: Agent) -> Result<bool> {
        Ok((self.ready)(agent) && !self.engine.is_working(agent) && self.has_capacity(agent)?)
    }

    /// A paid worker is never used as a stand-in for an unavailable one unless
    /// the user switched that on in the app. A model cannot grant this itself.
    fn refuse_paid_fallback(&self, state: &WorkshopState, allowed: &[Agent], candidate: Agent) -> Result<()> {
        let position = allowed.iter().position(|agent| *agent == candidate).unwrap_or(0);
        if position == 0 || candidate.billing() != "provider_account" || state.allow_paid_fallback {
            return Ok(());
        }
        let passed_over = allowed[..position].iter().find_map(|agent| match self.available(*agent) {
            Ok(false) => Some(*agent),
            _ => None,
        });
        match passed_over {
            Some(preferred) => Err(Error::invalid(format!(
                "{} is unavailable and the next assigned worker, {}, bills your provider account. No request was sent. Ask the user first; they can allow paid fallback in Sudo Interns under Delegation rules.",
                preferred.label(),
                candidate.label()
            ))),
            None => Ok(()),
        }
    }

    fn select(&self, pinned: Option<&str>, consultation: bool, kind: Option<&str>) -> Result<Agent> {
        let state = self.state()?;
        if let Some(team) = &state.team {
            team.validate()?;
            if self.client != Some(team.primary) {
                return Err(Error::invalid("Open this team from its configured primary agent."));
            }
            let policy = state.delegation_policy.clone().unwrap_or_default();
            let allowed: Vec<Agent> = if consultation { team.advisor.into_iter().collect() } else { policy.workers(kind, team) };
            let candidate = match pinned {
                Some(value) => Agent::from_provider(value),
                None => {
                    let mut chosen = None;
                    for agent in &allowed {
                        if self.available(*agent)? {
                            chosen = Some(*agent);
                            break;
                        }
                    }
                    chosen
                }
            };
            if pinned.is_none() && candidate.is_none() && allowed.iter().any(|agent| (self.ready)(*agent)) {
                for agent in &allowed {
                    if (self.ready)(*agent) && !self.has_capacity(*agent)? {
                        return Err(Error::invalid("Assigned workers reached their local daily request cap. Adjust it in Sudo Interns or wait for the next UTC day."));
                    }
                }
                return Err(Error::invalid(if consultation { "Your advisor is busy. Retry when its current task finishes." } else { "Your assigned workers are busy. Retry after a current task finishes." }));
            }
            let candidate = candidate.filter(|agent| allowed.contains(agent)).ok_or_else(|| {
                Error::invalid(if consultation { "Choose a connected advisor in team setup." } else { "Choose a worker in team setup before delegating." })
            })?;
            if !(self.ready)(candidate) {
                return Err(Error::invalid(format!("{} is not connected to Sudo Interns.", candidate.label())));
            }
            if !self.has_capacity(candidate)? {
                return Err(Error::invalid("This assistant reached its local daily request cap. No provider request was sent."));
            }
            if !consultation {
                self.refuse_paid_fallback(&state, &allowed, candidate)?;
            }
            return Ok(candidate);
        }
        Err(Error::invalid("Set up your team in Sudo Interns before delegating."))
    }

    pub fn delegate(&self, request: DelegateRequest<'_>) -> Result<DelegateResult> {
        let state = self.state()?;
        let policy = state.delegation_policy.clone().unwrap_or_default();
        let timeout = request.timeout.unwrap_or(policy.timeout_seconds);
        if !(1..=3600).contains(&timeout) {
            return Err(Error::invalid("Invalid worker timeout."));
        }
        let agent = self.select(request.provider, false, request.kind)?;
        let workspace = request.cwd.map(|path| self.engine.approved_workspace(path)).transpose()?;
        let title = request.title.map(str::trim).filter(|title| !title.is_empty());
        if title.is_some_and(|title| title.len() > 240 || title.contains('\n')) {
            return Err(Error::invalid("Use a short, single-line task title."));
        }
        let log = TeamJobLog::new(&self.engine.root);
        let mut job = TeamJob {
            id: Uuid::new_v4(),
            primary: self.client,
            worker: agent,
            title: title.map(str::to_string).unwrap_or_else(|| request.brief.chars().take(180).collect()),
            status: "running".to_string(),
            started: Utc::now(),
            finished: None,
            result: None,
            review_required: false,
            reviews: Vec::new(),
            confinement: None,
            git_changes: Vec::new(),
        };
        log.save(&job)?;
        let model = self.selected_model(&state, agent)?;
        let model_label = model.clone().unwrap_or_else(|| "default".to_string());
        let stop = self.engine.stop_file(job.id);
        let outcome = (self.worker)(agent, request.brief, workspace.as_deref(), timeout, Some(stop.clone()), model);
        let _ = std::fs::remove_file(&stop);
        let has_workspace = workspace.is_some();
        job.finished = Some(Utc::now());
        let result = match outcome {
            Ok(outcome) => {
                job.status = if has_workspace { "needs_handoff" } else { "completed" }.to_string();
                job.result = Some(outcome.answer.clone());
                job.review_required = has_workspace;
                job.confinement = Some(outcome.confinement.name().to_string());
                job.git_changes = outcome.git_changes.clone();
                log.save(&job)?;
                return Ok(DelegateResult {
                    status: job.status,
                    provider: agent.provider_id(),
                    model: model_label,
                    final_message: outcome.answer,
                    review_required: has_workspace,
                    changed_files: (!has_workspace).then(Vec::new),
                    schema: "delegate-relay.result.v1",
                    job_id: job.id,
                    billing: agent.billing(),
                    confinement: Some(outcome.confinement.name()),
                    git_changes: outcome.git_changes,
                });
            }
            Err(error) => error,
        };
        let stopped = matches!(result, Error::Stopped | Error::Cancelled);
        job.status = if has_workspace { "needs_handoff" } else if stopped { "cancelled" } else { "failed" }.to_string();
        job.result = Some(result.to_string());
        job.review_required = has_workspace;
        log.save(&job)?;
        if !has_workspace || matches!(result, Error::Cancelled) {
            if matches!(result, Error::Stopped) {
                return Ok(self.stopped_result(&job, agent, model_label, result.to_string()));
            }
            return Err(result);
        }
        let message = if stopped { result.to_string() } else { format!("{result} Review the workspace for partial edits.") };
        Ok(self.stopped_result(&job, agent, model_label, message))
    }

    fn stopped_result(&self, job: &TeamJob, agent: Agent, model: String, message: String) -> DelegateResult {
        DelegateResult {
            status: job.status.clone(),
            provider: agent.provider_id(),
            model,
            final_message: message,
            review_required: job.review_required,
            changed_files: None,
            schema: "delegate-relay.result.v1",
            job_id: job.id,
            billing: agent.billing(),
            confinement: None,
            git_changes: Vec::new(),
        }
    }

    pub fn consult(&self, question: &str, context: &str, reason: ConsultReason, provider: Option<&str>, continuing: Option<Uuid>) -> Result<ConsultRecord> {
        if question.trim().is_empty() || question.len() > 16 * 1024 {
            return Err(Error::invalid("Enter a question or task of up to 16 KB."));
        }
        if context.len() > 64 * 1024 {
            return Err(Error::invalid("Context can contain up to 64 KB."));
        }
        let client = self.client.ok_or_else(|| Error::invalid("Set the MCP client with --client codex or --client claude."))?;
        let state = self.state()?;
        let settings = state.advisors.clone();
        let log = ConsultLog::new(&self.engine.root);
        log.expire_open()?;
        let started = Utc::now();
        let previous = match continuing {
            Some(id) => {
                let record = log.get(id)?.filter(|record| {
                    record.caller == client
                        && record.status == ConsultStatus::Open
                        && (record.rounds.len() as u32) < settings.max_rounds
                        && provider.is_none_or(|value| Agent::from_provider(value).map(Agent::provider_id).as_deref() == Some(record.provider.as_str()))
                });
                Some(record.ok_or_else(|| Error::invalid("This consultation is unavailable for another round."))?)
            }
            None => None,
        };
        let effective = previous.as_ref().map_or(reason, |record| record.reason);
        if settings.mode == AdvisorMode::Off || (settings.mode != AdvisorMode::Important && effective != ConsultReason::UserRequest) {
            return Err(Error::invalid("The current advisor mode does not allow this request."));
        }
        let agent = self.select(previous.as_ref().map(|record| record.provider.as_str()).or(provider), true, None)?;
        let prompt = consultation_prompt(question, context, previous.as_ref().map_or(&[], |record| record.rounds.as_slice()));
        let configured = self.selected_model(&state, agent)?;
        let model = match &previous {
            Some(record) if record.model_pinned => record.requested_model.clone(),
            _ => configured,
        };
        let outcome = (self.worker)(agent, &prompt, None, settings.timeout_minutes * 60, None, model.clone())?;
        let finished = Utc::now();
        let label = model.clone().unwrap_or_else(|| "default".to_string());
        let mut record = previous.clone().unwrap_or_else(|| ConsultRecord {
            id: Uuid::new_v4(),
            caller: client,
            reason,
            provider: agent.provider_id(),
            model: label.clone(),
            requested_model: None,
            model_pinned: false,
            mode_at_start: settings.mode,
            question: question.to_string(),
            context_sha256: Some(hex::encode(Sha256::digest(context.as_bytes()))),
            context_bytes: context.len(),
            rounds: Vec::new(),
            status: ConsultStatus::Open,
            decision: None,
            summary: None,
            created: started,
            updated: started,
        });
        record.model = label;
        record.requested_model = model;
        record.model_pinned = true;
        let (advice, truncated) = cap_text(&outcome.answer, ADVICE_LIMIT);
        record.rounds.push(ConsultRound { index: record.rounds.len() + 1, prompt: question.to_string(), advice, truncated, status: "completed".to_string(), started_at: started, finished_at: finished });
        record.updated = finished;
        match &previous {
            Some(previous) => log.update(&record, previous)?,
            None => log.insert(&record)?,
        }
        Ok(record)
    }

    pub fn decide(&self, id: Uuid, decision: ConsultDecision, summary: &str) -> Result<ConsultRecord> {
        let log = ConsultLog::new(&self.engine.root);
        log.expire_open()?;
        let client = self.client;
        let previous = log
            .get(id)?
            .filter(|record| Some(record.caller) == client && record.status == ConsultStatus::Open && summary.len() <= 2048)
            .ok_or_else(|| Error::invalid("Choose an open consultation and a summary of at most 2 KB."))?;
        let mut record = previous.clone();
        record.status = ConsultStatus::Closed;
        record.decision = Some(decision);
        record.summary = Some(summary.to_string());
        record.updated = Utc::now();
        log.update(&record, &previous)?;
        Ok(record)
    }

    pub fn review(&self, id: Uuid, decision: ReviewDecision, summary: &str, verification: &str, score: Option<u8>) -> Result<TeamJob> {
        let primary = self.client.filter(|client| self.state().ok().and_then(|state| state.team).is_some_and(|team| team.primary == *client));
        let Some(primary) = primary else {
            return Err(Error::invalid("Only the configured primary can record a worker review."));
        };
        TeamJobLog::new(&self.engine.root).record_review(id, TeamReview { decision, primary, summary: summary.to_string(), verification: verification.to_string(), score, created: Utc::now() })
    }
}

pub fn consultation_prompt(question: &str, context: &str, previous: &[ConsultRound]) -> String {
    let header = "Give an independent, text-only second opinion. Identify risks and a concrete verification step. Use only the supplied text.".to_string();
    let current = format!("Question:\n{question}");
    let supplied = (!context.is_empty()).then(|| format!("Context supplied by the caller:\n{context}"));
    let mut parts = vec![header.clone()];
    parts.extend(previous.iter().map(|round| format!("Prior question:\n{}\nPrior advice:\n{}", round.prompt, round.advice)));
    parts.push(current.clone());
    parts.extend(supplied.clone());
    let text = parts.join("\n\n");
    if text.len() <= 120 * 1024 {
        return text;
    }
    // Keep the current question and context. Earlier rounds remain in the log.
    let mut short = vec![header, current];
    short.extend(supplied);
    short.join("\n\n")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::confine::Confinement;
    use crate::secrets::MemorySecrets;
    use std::sync::Mutex;

    struct Harness {
        _root: tempfile::TempDir,
        engine: Engine,
        project: PathBuf,
        calls: Arc<Mutex<Vec<(Agent, Option<PathBuf>)>>>,
    }

    impl Harness {
        fn new(team: TeamSettings) -> Self {
            let root = tempfile::tempdir().unwrap();
            let home = dunce::canonicalize(root.path()).unwrap().join("home");
            let project = home.join("code/demo");
            std::fs::create_dir_all(&project).unwrap();
            let engine = Engine::with(home.join(".local/share/data"), home, Arc::new(MemorySecrets::default()));
            engine.allow_workspace(&project.to_string_lossy()).unwrap();
            let state = WorkshopState { team: Some(team), advisors: AdvisorSettings { mode: AdvisorMode::Important, ..Default::default() }, ..Default::default() };
            WorkshopStore::new(&engine.root).save(&state).unwrap();
            Self { _root: root, engine, project, calls: Arc::new(Mutex::new(Vec::new())) }
        }

        fn bridge(&self, primary: Agent, unavailable: &[Agent]) -> Bridge {
            let calls = self.calls.clone();
            let worker: WorkerFn = Arc::new(move |agent, _prompt, workspace, _timeout, _stop, _model| {
                calls.lock().unwrap().push((agent, workspace.map(Path::to_path_buf)));
                Ok(WorkerOutcome { answer: "finished".to_string(), confinement: Confinement::AppEnforced, git_changes: vec![] })
            });
            let unavailable = unavailable.to_vec();
            let ready: ReadyFn = Arc::new(move |agent| !unavailable.contains(&agent));
            Bridge::with_doubles(self.engine.clone(), Some(primary), worker, ready)
        }

        fn delegate<'a>(&'a self, brief: &'a str) -> DelegateRequest<'a> {
            DelegateRequest { brief, cwd: self.project.to_str(), provider: None, timeout: None, kind: None, title: Some("Demo") }
        }
    }

    fn team() -> TeamSettings {
        TeamSettings { primary: Agent::Claude, advisor: Some(Agent::Codex), workers: vec![Agent::Kimi, Agent::Deepseek] }
    }

    #[test]
    fn full_primary_consults_delegates_and_reviews() {
        let harness = Harness::new(team());
        let bridge = harness.bridge(Agent::Claude, &[]);
        let consult = bridge.consult("Is the plan sound?", "ctx", ConsultReason::Plan, None, None).unwrap();
        assert_eq!(consult.provider, "codex-official");
        assert_eq!(consult.context_bytes, 3);
        bridge.decide(consult.id, ConsultDecision::Adopted, "ok").unwrap();
        let result = bridge.delegate(harness.delegate("Do it")).unwrap();
        assert_eq!(result.status, "needs_handoff");
        assert!(result.review_required);
        assert_eq!(result.provider, "kimi-official");
        let job = bridge.review(result.job_id, ReviewDecision::Accepted, "looks right", "ran tests myself", Some(5)).unwrap();
        assert_eq!(job.status, "reviewed");
    }

    #[test]
    fn a_worker_cannot_be_used_without_an_approved_project() {
        let harness = Harness::new(team());
        let bridge = harness.bridge(Agent::Claude, &[]);
        let other = harness.project.parent().unwrap().join("unapproved");
        std::fs::create_dir_all(&other).unwrap();
        let request = DelegateRequest { brief: "x", cwd: other.to_str(), provider: None, timeout: None, kind: None, title: None };
        assert!(bridge.delegate(request).is_err());
        assert!(harness.calls.lock().unwrap().is_empty());
    }

    #[test]
    fn busy_subscription_worker_does_not_roll_over_to_a_paid_one() {
        let harness = Harness::new(team());
        let bridge = harness.bridge(Agent::Claude, &[Agent::Kimi]);
        let error = bridge.delegate(harness.delegate("Do it")).err().expect("must refuse").to_string();
        assert!(error.contains("No request was sent"), "{error}");
        assert!(harness.calls.lock().unwrap().is_empty());
    }

    #[test]
    fn pinning_cannot_bypass_the_paid_fallback_gate() {
        let harness = Harness::new(team());
        let bridge = harness.bridge(Agent::Claude, &[Agent::Kimi]);
        let request = DelegateRequest { brief: "x", cwd: harness.project.to_str(), provider: Some("deepseek-official"), timeout: None, kind: None, title: None };
        assert!(bridge.delegate(request).is_err());
        assert!(harness.calls.lock().unwrap().is_empty());
    }

    #[test]
    fn paid_fallback_works_after_the_user_enables_it() {
        let harness = Harness::new(team());
        let mut state = WorkshopStore::new(&harness.engine.root).load().unwrap();
        state.allow_paid_fallback = true;
        WorkshopStore::new(&harness.engine.root).save(&state).unwrap();
        let bridge = harness.bridge(Agent::Claude, &[Agent::Kimi]);
        assert_eq!(bridge.delegate(harness.delegate("Do it")).unwrap().provider, "deepseek-official");
    }

    #[test]
    fn a_paid_worker_the_user_put_first_needs_no_extra_approval() {
        let harness = Harness::new(TeamSettings { primary: Agent::Claude, advisor: None, workers: vec![Agent::Deepseek] });
        assert_eq!(harness.bridge(Agent::Claude, &[]).delegate(harness.delegate("x")).unwrap().provider, "deepseek-official");
    }

    #[test]
    fn only_the_configured_primary_can_use_the_team() {
        let harness = Harness::new(team());
        let bridge = harness.bridge(Agent::Codex, &[]);
        assert!(bridge.delegate(harness.delegate("x")).is_err());
    }

    #[test]
    fn advisor_policy_is_enforced() {
        let harness = Harness::new(team());
        let mut state = WorkshopStore::new(&harness.engine.root).load().unwrap();
        state.advisors.mode = AdvisorMode::OnRequest;
        WorkshopStore::new(&harness.engine.root).save(&state).unwrap();
        let bridge = harness.bridge(Agent::Claude, &[]);
        assert!(bridge.consult("q", "", ConsultReason::Plan, None, None).is_err());
        assert!(bridge.consult("q", "", ConsultReason::UserRequest, None, None).is_ok());
        state.advisors.mode = AdvisorMode::Off;
        WorkshopStore::new(&harness.engine.root).save(&state).unwrap();
        assert!(bridge.consult("q", "", ConsultReason::UserRequest, None, None).is_err());
    }

    #[test]
    fn consultation_rounds_stop_at_the_limit() {
        let harness = Harness::new(team());
        let bridge = harness.bridge(Agent::Claude, &[]);
        let first = bridge.consult("q", "", ConsultReason::Plan, None, None).unwrap();
        bridge.consult("q2", "", ConsultReason::Plan, None, Some(first.id)).unwrap();
        bridge.consult("q3", "", ConsultReason::Plan, None, Some(first.id)).unwrap();
        assert!(bridge.consult("q4", "", ConsultReason::Plan, None, Some(first.id)).is_err());
    }

    #[test]
    fn review_rejects_empty_evidence_and_other_primaries() {
        let harness = Harness::new(team());
        let bridge = harness.bridge(Agent::Claude, &[]);
        let result = bridge.delegate(harness.delegate("x")).unwrap();
        assert!(bridge.review(result.job_id, ReviewDecision::Accepted, "s", "  ", None).is_err());
        assert!(harness.bridge(Agent::Codex, &[]).review(result.job_id, ReviewDecision::Accepted, "s", "v", None).is_err());
    }

    #[test]
    fn status_reports_the_roster_schema() {
        let harness = Harness::new(team());
        let status = serde_json::to_value(harness.bridge(Agent::Claude, &[]).status().unwrap()).unwrap();
        assert_eq!(status["schema"], "delegate-relay.availability.v1");
        assert_eq!(status["team"]["primary"], "claude");
        assert_eq!(status["providers"]["deepseek-official"]["billing"], "provider_account");
        assert_eq!(status["advisor"]["seats"][0]["provider"], "codex-official");
    }
}
