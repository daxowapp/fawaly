#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use fawaly_core::api_worker::ApiWorker;
use fawaly_core::client_link::{self, ClientLink, ENGINE_NAME};
use fawaly_core::daily::{self, DailyStore};
use fawaly_core::log::{ApiUsage, ConsultLog, TeamJobLog};
use fawaly_core::model::*;
use fawaly_core::signin::NativeSignIn;
use fawaly_core::skills::{self, InstallPlan, ProjectSkills, Scope};
use fawaly_core::store::{ApiAssistant, ApiAssistantStore, WorkshopStore};
use fawaly_core::{installer, openrouter, paths, secrets, support, Engine};
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tauri::{Emitter, Manager, State};
use tauri_plugin_dialog::DialogExt;
use tauri_plugin_opener::OpenerExt;

struct App {
    engine: Engine,
    cancel: Arc<AtomicBool>,
    plans: Mutex<HashMap<String, (InstallPlan, ProjectSkills)>>,
    /// An OpenRouter key from browser sign-in, held until the user saves it.
    pending_openrouter: Mutex<Option<String>>,
}

type Reply<T> = std::result::Result<T, String>;

fn text<E: ToString>(error: E) -> String {
    error.to_string()
}

fn parse_agent(value: &str) -> Reply<Agent> {
    Agent::from_provider(value).ok_or_else(|| "Unknown assistant.".to_string())
}

fn load_state(app: &App) -> Reply<WorkshopState> {
    WorkshopStore::new(&app.engine.root).load().map_err(text)
}

fn update_state(app: &App, change: impl FnOnce(&mut WorkshopState) -> Reply<()>) -> Reply<WorkshopState> {
    let store = WorkshopStore::new(&app.engine.root);
    let mut state = store.load().map_err(text)?;
    change(&mut state)?;
    store.save(&state).map_err(text)?;
    Ok(state)
}

fn engine_source() -> Reply<PathBuf> {
    let current = std::env::current_exe().map_err(text)?;
    let folder = current.parent().ok_or("The application folder could not be located.")?;
    let name = paths::exe_name(ENGINE_NAME);
    let candidates = [folder.join(&name), folder.join("..").join("lib").join("sudo-interns").join(&name), folder.join("resources").join(&name)];
    candidates.into_iter().find(|path| path.is_file()).ok_or_else(|| "The team engine is missing from this installation. Reinstall Sudo Interns.".to_string())
}

fn services(app: &App) -> Reply<Vec<Value>> {
    let store = ApiAssistantStore::new(&app.engine.root);
    let state = load_state(app)?;
    let usage = ApiUsage::new(&app.engine.root);
    Agent::ALL
        .iter()
        .map(|agent| {
            let profile = if agent.is_native() { None } else { store.load(*agent).map_err(text)? };
            let preset = (!agent.is_native()).then(|| ApiAssistant::preset(*agent));
            let totals = if agent.is_native() { None } else { usage.totals(*agent).ok() };
            Ok(json!({
                "agent": agent.raw(),
                "label": agent.label(),
                "native": agent.is_native(),
                "primaryCapable": agent.is_primary(),
                "billing": agent.billing(),
                "installed": app.engine.executable(*agent).is_some(),
                "ready": app.engine.is_ready(*agent),
                "working": app.engine.is_working(*agent),
                "configured": profile.is_some(),
                "enabled": profile.as_ref().is_none_or(|value| value.enabled),
                "local": preset.as_ref().is_some_and(ApiAssistant::is_local),
                "endpoint": profile.as_ref().or(preset.as_ref()).map(|value| value.endpoint.clone()),
                "model": state.worker_models.get(agent.raw()).cloned().or(profile.as_ref().or(preset.as_ref()).map(|value| value.model.clone())),
                "dailyRequestLimit": profile.as_ref().or(preset.as_ref()).map(|value| value.daily_request_limit),
                "usage": totals,
            }))
        })
        .collect()
}

#[tauri::command(async)]
fn bootstrap(app: State<'_, App>) -> Reply<Value> {
    let state = load_state(&app)?;
    Ok(json!({
        "state": state,
        "services": services(&app)?,
        "platform": {"os": std::env::consts::OS, "arch": std::env::consts::ARCH},
        "capabilities": support::capabilities(&app.engine),
        "workspaces": app.engine.workspaces().map_err(text)?,
        "version": fawaly_core::VERSION,
    }))
}

#[tauri::command(async)]
fn set_preferences(app: State<'_, App>, arabic: Option<bool>, appearance: Option<Appearance>) -> Reply<()> {
    update_state(&app, |state| {
        if let Some(arabic) = arabic {
            state.arabic = arabic;
        }
        if let Some(appearance) = appearance {
            state.appearance = appearance;
        }
        Ok(())
    })?;
    Ok(())
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RulesInput {
    mode: AdvisorMode,
    max_rounds: u32,
    timeout_minutes: u64,
    timeout_seconds: u64,
    orders: std::collections::BTreeMap<String, Vec<Agent>>,
    allow_paid_fallback: bool,
    allow_unconfined_windows_kimi: bool,
    allow_unconfined_linux_workers: bool,
}

#[tauri::command(async)]
fn save_team(app: State<'_, App>, team: TeamSettings, mode: AdvisorMode) -> Reply<()> {
    team.validate().map_err(text)?;
    update_state(&app, |state| {
        state.team = Some(team);
        state.advisors.mode = mode;
        state.delegation_policy = None;
        Ok(())
    })?;
    Ok(())
}

#[tauri::command(async)]
fn save_rules(app: State<'_, App>, rules: RulesInput) -> Reply<()> {
    if !(1..=5).contains(&rules.max_rounds) || !(1..=10).contains(&rules.timeout_minutes) {
        return Err("Choose 1 to 5 rounds and 1 to 10 minutes.".to_string());
    }
    update_state(&app, |state| {
        let policy = DelegationPolicy { timeout_seconds: rules.timeout_seconds, orders: rules.orders };
        policy.validate(state.team.as_ref()).map_err(text)?;
        state.delegation_policy = Some(policy);
        state.advisors.mode = rules.mode;
        state.advisors.max_rounds = rules.max_rounds;
        state.advisors.timeout_minutes = rules.timeout_minutes;
        state.allow_paid_fallback = rules.allow_paid_fallback;
        state.allow_unconfined_windows_kimi = rules.allow_unconfined_windows_kimi;
        state.allow_unconfined_linux_workers = rules.allow_unconfined_linux_workers;
        Ok(())
    })?;
    Ok(())
}

#[tauri::command(async)]
fn finish_onboarding(app: State<'_, App>) -> Reply<()> {
    update_state(&app, |state| {
        state.onboarding_version = Some(1);
        Ok(())
    })?;
    Ok(())
}

#[tauri::command(async)]
fn cancel_operation(app: State<'_, App>) {
    app.cancel.store(true, Ordering::SeqCst);
}

#[tauri::command(async)]
fn prepare_service(app: State<'_, App>, agent: String) -> Reply<Value> {
    let agent = parse_agent(&agent)?;
    app.cancel.store(false, Ordering::SeqCst);
    if app.engine.executable(agent).is_none() {
        installer::install(&app.engine, agent, &app.cancel).map_err(text)?;
    }
    let connected = NativeSignIn::new(app.engine.clone()).verify(agent, &app.cancel).unwrap_or(false);
    Ok(json!({"connected": connected}))
}

#[tauri::command(async)]
fn sign_in(window: tauri::Window, app: State<'_, App>, agent: String, region: Option<String>) -> Reply<()> {
    let agent = parse_agent(&agent)?;
    app.cancel.store(false, Ordering::SeqCst);
    let notify = window.clone();
    NativeSignIn::new(app.engine.clone())
        .sign_in(agent, region.as_deref().unwrap_or("global"), &app.cancel, &move |url| {
            let _ = notify.emit("signin-url", url);
        })
        .map_err(text)
}

#[tauri::command(async)]
fn sign_out(app: State<'_, App>, agent: String) -> Reply<()> {
    let agent = parse_agent(&agent)?;
    app.cancel.store(false, Ordering::SeqCst);
    NativeSignIn::new(app.engine.clone()).sign_out(agent, &app.cancel).map_err(text)
}

#[tauri::command(async)]
fn connect_team(app: State<'_, App>) -> Reply<()> {
    let state = load_state(&app)?;
    let team = state.team.ok_or("Choose your team first.")?;
    team.validate().map_err(text)?;
    ClientLink::new(app.engine.clone()).connect(team.primary, &engine_source()?).map_err(text)
}

#[tauri::command(async)]
fn connection_status(app: State<'_, App>) -> Reply<Value> {
    let state = load_state(&app)?;
    let Some(team) = state.team else {
        return Ok(json!({"linked": false}));
    };
    let link = ClientLink::new(app.engine.clone());
    let Some(executable) = app.engine.executable(team.primary) else {
        return Ok(json!({"linked": false, "primary": team.primary, "missing": true}));
    };
    let linked = link.entry(team.primary, &executable).map_err(text)?.is_some_and(|entry| {
        Path::new(&entry.command) == client_link::launcher_path(&app.engine)
    });
    Ok(json!({"linked": linked, "primary": team.primary}))
}

#[tauri::command(async)]
fn disconnect_team(app: State<'_, App>) -> Reply<bool> {
    let state = load_state(&app)?;
    let team = state.team.ok_or("Choose your team first.")?;
    ClientLink::new(app.engine.clone()).disconnect(team.primary).map_err(text)
}

#[tauri::command(async)]
fn choose_project(window: tauri::Window, app: State<'_, App>) -> Reply<Option<String>> {
    let Some(folder) = window.dialog().file().blocking_pick_folder() else {
        return Ok(None);
    };
    let path = folder.into_path().map_err(text)?;
    let approved = app.engine.allow_workspace(&path.to_string_lossy()).map_err(text)?;
    update_state(&app, |state| {
        state.project_directory = Some(approved.clone());
        Ok(())
    })?;
    Ok(Some(approved.to_string_lossy().to_string()))
}

#[tauri::command(async)]
fn pick_folder(window: tauri::Window) -> Reply<Option<String>> {
    let Some(folder) = window.dialog().file().blocking_pick_folder() else {
        return Ok(None);
    };
    Ok(Some(folder.into_path().map_err(text)?.to_string_lossy().to_string()))
}

#[tauri::command(async)]
fn revoke_project(app: State<'_, App>, path: String) -> Reply<()> {
    app.engine.deny_workspace(&path).map_err(text)?;
    update_state(&app, |state| {
        if state.project_directory.as_ref().is_some_and(|known| known.to_string_lossy() == path) {
            state.project_directory = None;
        }
        Ok(())
    })?;
    Ok(())
}

fn official_link(value: &str) -> bool {
    const HOSTS: [&str; 22] = [
        "github.com", "openrouter.ai", "platform.openai.com", "chatgpt.com", "auth.openai.com", "claude.ai", "console.anthropic.com", "platform.claude.com",
        "www.kimi.com", "www.kimi.ai", "kimi.com", "kimi.ai", "auth.kimi.com", "auth.kimi.ai", "z.ai", "docs.z.ai", "platform.minimax.io", "platform.deepseek.com",
        "nagdy.me", "openai.com", "github.blog", "huggingface.co",
    ];
    url::Url::parse(value).is_ok_and(|url| url.scheme() == "https" && url.host_str().is_some_and(|host| HOSTS.contains(&host) || host == "www.openai.com"))
}

#[tauri::command(async)]
fn open_link(window: tauri::Window, url: String) -> Reply<()> {
    if !official_link(&url) {
        return Err("This link is not on the official list.".to_string());
    }
    window.opener().open_url(url, None::<&str>).map_err(text)
}

#[tauri::command(async)]
fn activity(app: State<'_, App>) -> Reply<Value> {
    let log = ConsultLog::new(&app.engine.root);
    let _ = log.expire_open();
    Ok(json!({
        "jobs": TeamJobLog::new(&app.engine.root).recent(500).map_err(text)?,
        "consults": log.recent(200).map_err(text)?,
    }))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct AssistantInput {
    agent: String,
    model: String,
    endpoint: Option<String>,
    key: Option<String>,
    use_pending_openrouter: Option<bool>,
    daily_request_limit: Option<u32>,
    enabled: Option<bool>,
}

#[tauri::command(async)]
fn save_assistant(app: State<'_, App>, input: AssistantInput) -> Reply<()> {
    let agent = parse_agent(&input.agent)?;
    if agent.is_native() {
        return Err("Connect this service from its sign-in button.".to_string());
    }
    let store = ApiAssistantStore::new(&app.engine.root);
    let mut assistant = store.load(agent).map_err(text)?.unwrap_or_else(|| ApiAssistant::preset(agent));
    if let Some(endpoint) = input.endpoint.filter(|value| !value.trim().is_empty()) {
        assistant.endpoint = endpoint.trim().to_string();
    }
    assistant.model = input.model.trim().to_string();
    if !valid_model(&assistant.model) {
        return Err("Choose a model first.".to_string());
    }
    if let Some(limit) = input.daily_request_limit {
        assistant.daily_request_limit = limit;
    }
    if let Some(enabled) = input.enabled {
        assistant.enabled = enabled;
    }
    assistant.validate().map_err(text)?;
    let pending = input.use_pending_openrouter.unwrap_or(false).then(|| app.pending_openrouter.lock().unwrap().take()).flatten();
    let key = pending.or(input.key.filter(|value| !value.is_empty()));
    if let Some(key) = &key {
        secrets::validate_key(key).map_err(text)?;
        app.engine.secrets.set(&assistant.key_account(), key).map_err(text)?;
    } else if !assistant.is_local() && app.engine.secrets.get(&assistant.key_account()).map_err(text)?.is_none() {
        return Err("Enter this service's key first.".to_string());
    }
    store.save(assistant).map_err(text)
}

#[tauri::command(async)]
fn remove_assistant(app: State<'_, App>, agent: String) -> Reply<()> {
    let agent = parse_agent(&agent)?;
    let store = ApiAssistantStore::new(&app.engine.root);
    if let Some(assistant) = store.load(agent).map_err(text)? {
        app.engine.secrets.delete(&assistant.key_account()).map_err(text)?;
    }
    store.remove(agent).map_err(text)
}

/// A real, billed request. It runs only from the explicit Save & test button.
#[tauri::command(async)]
fn test_assistant(app: State<'_, App>, agent: String) -> Reply<String> {
    let agent = parse_agent(&agent)?;
    let assistant = ApiAssistantStore::new(&app.engine.root).load(agent).map_err(text)?.ok_or("Save this assistant first.")?;
    ApiWorker { engine: &app.engine, transport: app.engine.transport.clone(), stop_file: None }
        .run(&assistant, "Reply with exactly: ready", None, 60)
        .map_err(text)
}

#[tauri::command(async)]
fn list_models(app: State<'_, App>, agent: String, key: Option<String>) -> Reply<Vec<String>> {
    let agent = parse_agent(&agent)?;
    let mut assistant = ApiAssistantStore::new(&app.engine.root).load(agent).map_err(text)?.unwrap_or_else(|| ApiAssistant::preset(agent));
    if assistant.model.is_empty() {
        assistant.model = "placeholder".to_string();
    }
    let mut engine = app.engine.clone();
    let supplied = key.filter(|value| !value.is_empty()).or_else(|| app.pending_openrouter.lock().unwrap().clone().filter(|_| agent == Agent::Openrouter));
    if let Some(key) = supplied {
        let scratch = secrets::MemorySecrets::default();
        secrets::SecretStore::set(&scratch, &assistant.key_account(), &key).map_err(text)?;
        engine.secrets = Arc::new(scratch);
    }
    ApiWorker { engine: &engine, transport: engine.transport.clone(), stop_file: None }.models(&assistant).map_err(text)
}

#[tauri::command(async)]
fn set_worker_model(app: State<'_, App>, agent: String, model: Option<String>) -> Reply<()> {
    let agent = parse_agent(&agent)?;
    if model.as_deref().is_some_and(|value| !valid_model(value)) {
        return Err("Invalid worker model identifier.".to_string());
    }
    update_state(&app, |state| {
        match model {
            Some(value) => state.worker_models.insert(agent.raw().to_string(), value),
            None => state.worker_models.remove(agent.raw()),
        };
        Ok(())
    })?;
    Ok(())
}

#[tauri::command(async)]
fn openrouter_sign_in(window: tauri::Window, app: State<'_, App>) -> Reply<()> {
    app.cancel.store(false, Ordering::SeqCst);
    let arabic = load_state(&app)?.arabic;
    let opener = window.clone();
    let open = move |url: &str| opener.opener().open_url(url.to_string(), None::<&str>).is_ok();
    let key = openrouter::sign_in(arabic, Duration::from_secs(180), &open, &app.cancel, &app.engine.transport).map_err(text)?;
    *app.pending_openrouter.lock().unwrap() = Some(key);
    Ok(())
}

fn skills_target(app: &App, scope: Scope, directory: Option<String>) -> Reply<ProjectSkills> {
    match scope {
        Scope::AllProjects => Ok(ProjectSkills::global(&app.engine.home)),
        Scope::Project => {
            let directory = directory.ok_or("Choose a project folder.")?;
            let approved = if app.engine.approved_workspace(&directory).is_ok() { app.engine.approved_workspace(&directory).map_err(text)? } else { app.engine.allow_workspace(&directory).map_err(text)? };
            Ok(ProjectSkills::project(&approved, &app.engine.home))
        }
    }
}

#[tauri::command(async)]
fn skills_list(app: State<'_, App>, scope: Scope, directory: Option<String>) -> Reply<Vec<Value>> {
    let target = match (scope, directory.as_ref()) {
        (Scope::Project, None) => None,
        _ => Some(skills_target(&app, scope, directory)?),
    };
    skills::catalog()
        .map_err(text)?
        .into_iter()
        .map(|item| {
            let status = target.as_ref().map(|target| target.status(&item));
            let mut value = serde_json::to_value(&item).map_err(text)?;
            value["status"] = json!(status);
            value["sourceUrl"] = json!(item.source_url());
            value["fileCount"] = json!(item.files.len());
            Ok(value)
        })
        .collect()
}

#[tauri::command(async)]
fn skills_preview(app: State<'_, App>, id: String, scope: Scope, directory: Option<String>) -> Reply<Value> {
    let catalog = skills::catalog().map_err(text)?;
    let item = catalog.iter().find(|item| item.id == id).ok_or("Unknown skill.")?;
    let target = skills_target(&app, scope, directory)?;
    let contents = item.download(&app.engine.transport).map_err(text)?;
    let plan = target.plan(item, &contents, &catalog).map_err(text)?;
    let reply = json!({
        "id": item.id,
        "name": item.name,
        "author": item.author,
        "license": item.license,
        "sourceUrl": item.source_url(),
        "destination": plan.directory,
        "scope": plan.scope,
        "warnings": plan.warnings,
        "writes": plan.writes.iter().map(|write| write.path.clone()).collect::<Vec<_>>(),
        "preview": fawaly_core::model::cap_text(&plan.preview, 4096).0,
        "hasScripts": item.has_scripts,
        "hasHooks": item.has_hooks,
    });
    app.plans.lock().unwrap().insert(id, (plan, target));
    Ok(reply)
}

#[tauri::command(async)]
fn skills_install(app: State<'_, App>, id: String) -> Reply<()> {
    let (plan, target) = app.plans.lock().unwrap().remove(&id).ok_or("Review the installation again.")?;
    target.install(&plan).map_err(text)
}

#[tauri::command(async)]
fn daily_load(app: State<'_, App>, refresh: bool) -> Reply<Value> {
    let store = DailyStore::new(&app.engine.root);
    let mut snapshot = store.load().map_err(text)?;
    let now = chrono::Utc::now();
    if refresh || snapshot.due(now) {
        snapshot = daily::refresh(&snapshot, &app.engine.transport, now);
        store.save_snapshot(&snapshot).map_err(text)?;
    }
    let names: Value = daily::SOURCES.iter().map(|source| (source.id.to_string(), json!(source.name))).collect::<serde_json::Map<_, _>>().into();
    Ok(json!({"snapshot": snapshot, "reading": store.reading().map_err(text)?, "sources": names}))
}

#[tauri::command(async)]
fn daily_mark(app: State<'_, App>, article: daily::DailyArticle, saved: Option<bool>, read: Option<bool>) -> Reply<Value> {
    let store = DailyStore::new(&app.engine.root);
    let mut reading = store.reading().map_err(text)?;
    if let Some(saved) = saved {
        if saved && daily::valid_bookmark(&article, chrono::Utc::now()) {
            reading.saved.insert(article.url.clone());
            reading.bookmarks.retain(|known| known.url != article.url);
            reading.bookmarks.push(article.clone());
        } else if !saved {
            reading.saved.remove(&article.url);
            reading.bookmarks.retain(|known| known.url != article.url);
        }
    }
    if read == Some(true) {
        reading.read.insert(article.url.clone());
    }
    store.save_reading(&reading).map_err(text)?;
    serde_json::to_value(reading).map_err(text)
}

#[tauri::command(async)]
fn daily_brief(article: daily::DailyArticle, arabic: bool) -> String {
    daily::task_prompt(&article, arabic)
}

#[tauri::command(async)]
fn remove_my_data(app: State<'_, App>) -> Reply<()> {
    let link = ClientLink::new(app.engine.clone());
    for primary in Agent::PRIMARY {
        let _ = link.disconnect(primary);
    }
    let store = ApiAssistantStore::new(&app.engine.root);
    for assistant in store.all().map_err(text)? {
        app.engine.secrets.delete(&assistant.key_account()).map_err(text)?;
    }
    let root = app.engine.root.clone();
    if root.exists() {
        std::fs::remove_dir_all(&root).map_err(text)?;
    }
    Ok(())
}

fn main() {
    let mut engine = Engine::live().expect("application data folder");
    engine.helper = paths::ensure_private_dir(&engine.root).ok().and_then(|()| engine_source().ok()).and_then(|source| client_link::prepare_launcher(&engine, &source).ok());
    let state = App { engine, cancel: Arc::new(AtomicBool::new(false)), plans: Mutex::new(HashMap::new()), pending_openrouter: Mutex::new(None) };
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_opener::init())
        .setup(|app| {
            if let Some(window) = app.get_webview_window("main") {
                let _ = window.set_focus();
            }
            Ok(())
        })
        .manage(state)
        .invoke_handler(tauri::generate_handler![
            bootstrap, set_preferences, save_team, save_rules, finish_onboarding, cancel_operation, prepare_service, sign_in, sign_out, connect_team, connection_status,
            disconnect_team, choose_project, pick_folder, revoke_project, open_link, activity, save_assistant, remove_assistant, test_assistant, list_models,
            set_worker_model, openrouter_sign_in, skills_list, skills_preview, skills_install, daily_load, daily_mark, daily_brief, remove_my_data
        ])
        .run(tauri::generate_context!())
        .expect("error while running the application");
}
