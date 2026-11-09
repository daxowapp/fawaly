use crate::bridge::{Bridge, DelegateRequest};
use crate::log::TeamJobLog;
use crate::model::{ConsultDecision, ConsultReason, ReviewDecision, TASK_KINDS};
use crate::store::WorkshopStore;
use crate::{Error, Result};
use serde_json::{json, Map, Value};
use std::collections::HashMap;
use std::io::{BufRead, Write};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc::{sync_channel, RecvTimeoutError};
use std::sync::{Arc, Mutex, OnceLock};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};
use uuid::Uuid;

const FRAME_LIMIT: usize = 512 * 1024;
const CONCURRENCY: usize = 8;
/// Time for a stopped native worker to end and its .git scan to be saved. A
/// model request already in flight cannot be interrupted and is not waited for.
const DRAIN_LIMIT: Duration = Duration::from_secs(5);
const PROTOCOLS: [&str; 4] = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"];
const INSTRUCTIONS: &str = "Fawaly manages your team, and the user set it up to be used. Before you change any file, use the team, unless the change is one obvious line the user spelled out or the user said not to. Do not make the change yourself first. If your own edit tools are denied, delegate instead of stopping. Do this without asking the user to direct each step: (1) Call roster_get. (2) Follow advisor.mode: important means consult the advisor with relevant user-authorized context and a concise proposed plan before committing to it, then record your decision with consult_decide; on_request means consult only when the user asks; off means do not consult. (3) Delegate a bounded implementation or investigation to a configured worker, with a precise deliverable, allowed files, constraints, acceptance checks and a short title in the roster language. A cwd permits edits only in a project the user approved in Fawaly. (4) When the worker returns, inspect the actual changed files yourself, run appropriate checks and repair findings, then call review with the jobId, decision, your own observed evidence and optional score. A worker report is a claim, not proof. Never claim a review you did not perform. Use changes_requested or rejected when checks fail. If a result lists gitChanges, inspect them before accepting. If gitScanIncomplete is true, inspect .git/config and .git/hooks yourself. You remain the primary and own the plan, integration, verification and final decision; do not delegate the whole goal or your final review. Use the saved delegation timeout and ordered workers for the task kind (general, code, research, review); no implicit paid fallback. Keep working until the user's goal is complete. Text-only advice requires no workspace access; workers cannot delegate again.";

fn rpc_error(id: Value, code: i64, message: &str) -> Value {
    json!({"jsonrpc":"2.0","id":id,"error":{"code":code,"message":message}})
}

fn tool(name: &str, description: &str, fields: &[(&str, &str)], required: &[&str], read_only: bool, open_world: bool) -> Value {
    let mut properties = Map::new();
    for (key, kind) in fields {
        let mut property = json!({"type": kind});
        if name == "delegate" && *key == "timeout" {
            property["description"] = json!("Duration from 1 second to 1 hour, e.g. 90s or 15m. A numeric string is seconds. Omit to use the saved worker timeout.");
            property["examples"] = json!(["90s", "15m", "900"]);
        }
        if *key == "kind" && name == "delegate" {
            property["enum"] = json!(TASK_KINDS);
        }
        if *key == "reason" && name == "consult" {
            property["enum"] = json!(ConsultReason::NAMES);
        }
        if *key == "context" && name == "consult" {
            property["description"] = json!("Up to 64 KB.");
        }
        if *key == "decision" && name == "review" {
            property["enum"] = json!(["accepted", "changes_requested", "rejected"]);
        }
        if *key == "decision" && name == "consult_decide" {
            property["enum"] = json!(["adopted", "partly", "rejected"]);
        }
        properties.insert((*key).to_string(), property);
    }
    json!({
        "name": name,
        "description": description,
        "inputSchema": {"type":"object","properties":properties,"required":required,"additionalProperties":false},
        "annotations": {"readOnlyHint":read_only,"openWorldHint":open_world}
    })
}

pub fn tools() -> &'static Vec<Value> {
    static TOOLS: OnceLock<Vec<Value>> = OnceLock::new();
    TOOLS.get_or_init(|| {
        vec![
            tool("status", "Read native connection status, team roles, advisor policy, and approved project access.", &[], &[], true, false),
            tool("roster_get", "Read the configured primary, advisor, workers, advisor policy, and approved project. Use this at the start of substantial work, then proactively consult and delegate according to those roles.", &[], &[], true, false),
            tool(
                "delegate",
                "Send a task brief to a configured Fawaly worker. A cwd allows edits only in a project approved by the user. Independently inspect changes and verify the result, then record your decision with review and the returned jobId. allowMetered has no effect: only the user can allow paid fallback, in the app.",
                &[("brief", "string"), ("cwd", "string"), ("provider", "string"), ("timeout", "string"), ("lane", "string"), ("kind", "string"), ("title", "string"), ("allowMetered", "boolean")],
                &["brief"],
                false,
                true,
            ),
            tool(
                "consult",
                "Ask the configured Fawaly advisor for a text-only second opinion. Send only context approved by the user.",
                &[("question", "string"), ("context", "string"), ("reason", "string"), ("advisor", "string"), ("consultId", "string")],
                &["question"],
                false,
                true,
            ),
            tool("stop", "Request a stop for this primary's running worker job. File edits may be partial and must be reviewed. Other processes are not stopped.", &[("jobId", "string")], &["jobId"], false, false),
            tool(
                "review",
                "Record the primary's independent review of a finished worker job. Inspect actual files and run appropriate checks first. Decisions: accepted, changes_requested, rejected. Evidence must describe your observations, not repeat the worker's claims.",
                &[("jobId", "string"), ("decision", "string"), ("summary", "string"), ("verification", "string"), ("score", "string")],
                &["jobId", "decision", "summary", "verification"],
                false,
                false,
            ),
            tool("consult_decide", "Record the primary agent's decision for an open consultation.", &[("consultId", "string"), ("decision", "string"), ("summary", "string")], &["consultId", "decision"], false, false),
        ]
    })
}

pub fn parse_seconds(value: &str) -> Result<u64> {
    let invalid = || Error::invalid("Set a timeout between 1s and 1h, such as 2m.");
    if !value.is_empty() && value.bytes().all(|byte| byte.is_ascii_digit()) {
        return value.parse::<u64>().ok().filter(|seconds| (1..=3600).contains(seconds)).ok_or_else(invalid);
    }
    let unit = value.chars().last().ok_or_else(invalid)?;
    let multiplier = match unit {
        's' => 1,
        'm' => 60,
        'h' => 3600,
        _ => return Err(invalid()),
    };
    let amount: u64 = value[..value.len() - 1].parse().map_err(|_| invalid())?;
    if (1..=3600 / multiplier).contains(&amount) {
        Ok(amount * multiplier)
    } else {
        Err(invalid())
    }
}

fn parse_id(value: Option<&str>) -> Result<Option<Uuid>> {
    value.map(|text| Uuid::parse_str(text).map_err(|_| Error::invalid("Invalid record ID."))).transpose()
}

fn encode<T: serde::Serialize>(value: T) -> Result<Value> {
    Ok(serde_json::to_value(value)?)
}

enum Incoming {
    Line(Vec<u8>),
    Oversized,
    Closed,
}

fn discard_line(input: &mut impl BufRead) -> std::io::Result<()> {
    loop {
        let available = input.fill_buf()?;
        if available.is_empty() {
            return Ok(());
        }
        if let Some(index) = available.iter().position(|byte| *byte == b'\n') {
            input.consume(index + 1);
            return Ok(());
        }
        let length = available.len();
        input.consume(length);
    }
}

/// Reads one line without ever holding more than the frame limit in memory.
fn read_frame(input: &mut impl BufRead) -> Incoming {
    let mut frame = Vec::new();
    match input.by_ref().take(FRAME_LIMIT as u64 + 1).read_until(b'\n', &mut frame) {
        Ok(0) | Err(_) => return Incoming::Closed,
        Ok(_) => {}
    }
    if frame.len() <= FRAME_LIMIT {
        return Incoming::Line(frame);
    }
    if frame.last() != Some(&b'\n') && discard_line(input).is_err() {
        return Incoming::Closed;
    }
    Incoming::Oversized
}

/// How far a tool call has got, so a client's cancellation can find its job.
enum Call {
    Starting,
    Running(Uuid),
    CancelledEarly,
}

#[derive(Clone)]
pub struct Server {
    bridge: Arc<Bridge>,
    calls: Arc<Mutex<HashMap<String, Call>>>,
}

impl Server {
    pub fn new(bridge: Bridge) -> Self {
        Self { bridge: Arc::new(bridge), calls: Arc::new(Mutex::new(HashMap::new())) }
    }

    fn stop_job(&self, job: Uuid) {
        if let Some(client) = self.bridge.client {
            let _ = self.bridge.engine.request_stop(job, client);
        }
    }

    fn job_started(&self, request: &str, job: Uuid) {
        let cancelled = {
            let mut calls = self.calls.lock().unwrap();
            match calls.get_mut(request) {
                Some(call @ Call::Starting) => {
                    *call = Call::Running(job);
                    false
                }
                Some(Call::CancelledEarly) => true,
                _ => false,
            }
        };
        if cancelled {
            self.stop_job(job);
        }
    }

    /// Only calls made in this session are in the map, so a client cannot stop
    /// another session's work this way.
    fn cancel_call(&self, request: &Value) {
        let job = {
            let mut calls = self.calls.lock().unwrap();
            match calls.get_mut(&request.to_string()) {
                Some(Call::Running(job)) => Some(*job),
                Some(call @ Call::Starting) => {
                    *call = Call::CancelledEarly;
                    None
                }
                _ => None,
            }
        };
        if let Some(job) = job {
            self.stop_job(job);
        }
    }

    fn call_tool(&self, name: &str, args: &Map<String, Value>, request: &str) -> Result<Value> {
        let spec = tools().iter().find(|spec| spec["name"] == name).ok_or_else(|| Error::invalid("Unknown Fawaly tool."))?;
        let fields = spec["inputSchema"]["properties"].as_object().cloned().unwrap_or_default();
        for (key, value) in args {
            let kind = fields.get(key).and_then(|field| field["type"].as_str());
            let matches_kind = match kind {
                Some("string") => value.is_string(),
                Some("boolean") => value.is_boolean(),
                _ => false,
            };
            if !matches_kind {
                return Err(Error::invalid(format!("Unsupported argument or argument type for {key}.")));
            }
            if let (Some(allowed), Some(text)) = (fields.get(key).and_then(|field| field["enum"].as_array()), value.as_str()) {
                if !allowed.iter().any(|item| item.as_str() == Some(text)) {
                    let names: Vec<&str> = allowed.iter().filter_map(Value::as_str).collect();
                    return Err(Error::invalid(format!("Use one of these values for {key}: {}", names.join(", "))));
                }
            }
        }
        for key in spec["inputSchema"]["required"].as_array().into_iter().flatten().filter_map(Value::as_str) {
            if !args.contains_key(key) {
                return Err(Error::invalid(format!("Missing {key}.")));
            }
        }
        let text = |key: &str| args.get(key).and_then(Value::as_str);
        match name {
            "status" | "roster_get" => encode(self.bridge.status()?),
            "delegate" => {
                let brief = text("brief").filter(|brief| !brief.trim().is_empty() && brief.len() <= 120 * 1024).ok_or_else(|| Error::invalid("Enter a brief of up to 120 KB."))?;
                let timeout = text("timeout").map(parse_seconds).transpose()?;
                let delegation = DelegateRequest { brief, cwd: text("cwd"), provider: text("provider"), timeout, kind: text("kind"), title: text("title") };
                encode(self.bridge.delegate_tracked(delegation, &|job| self.job_started(request, job))?)
            }
            "consult" => {
                let reason = ConsultReason::parse(text("reason").unwrap_or("user_request")).ok_or_else(|| Error::invalid("Use a question and a valid consultation reason."))?;
                let question = text("question").ok_or_else(|| Error::invalid("Use a question and a valid consultation reason."))?;
                encode(self.bridge.consult(question, text("context").unwrap_or(""), reason, text("advisor"), parse_id(text("consultId"))?)?)
            }
            "stop" => {
                let (Some(id), Some(client)) = (parse_id(text("jobId"))?, self.bridge.client) else {
                    return Err(Error::invalid("Choose a running job from this primary."));
                };
                self.bridge.engine.request_stop(id, client)?;
                Ok(json!({"jobId":id,"status":"stop_requested"}))
            }
            "review" => {
                let invalid = || Error::invalid("Use a jobId, decision, summary, and independent verification evidence.");
                let id = parse_id(text("jobId"))?.ok_or_else(invalid)?;
                let decision = ReviewDecision::parse(text("decision").unwrap_or("")).ok_or_else(invalid)?;
                let (Some(summary), Some(verification)) = (text("summary"), text("verification")) else {
                    return Err(invalid());
                };
                let score = text("score")
                    .map(|value| value.parse::<u8>().ok().filter(|score| (1..=5).contains(score)).ok_or_else(|| Error::invalid("Review scores range from 1 to 5.")))
                    .transpose()?;
                encode(self.bridge.review(id, decision, summary, verification, score)?)
            }
            "consult_decide" => {
                let invalid = || Error::invalid("Use a consultation ID and adopted, partly, or rejected.");
                let id = parse_id(text("consultId"))?.ok_or_else(invalid)?;
                let decision = match text("decision") {
                    Some("adopted") => ConsultDecision::Adopted,
                    Some("partly") => ConsultDecision::Partly,
                    Some("rejected") => ConsultDecision::Rejected,
                    _ => return Err(invalid()),
                };
                encode(self.bridge.decide(id, decision, text("summary").unwrap_or(""))?)
            }
            _ => Err(Error::invalid("Unknown Fawaly tool.")),
        }
    }

    pub fn handle(&self, frame: &[u8], initialized: &mut bool) -> Option<Value> {
        if frame.len() >= FRAME_LIMIT {
            return Some(rpc_error(Value::Null, -32700, "Invalid JSON"));
        }
        let Ok(Value::Object(request)) = serde_json::from_slice::<Value>(frame) else {
            return Some(rpc_error(Value::Null, -32700, "Invalid JSON"));
        };
        let method = request.get("method").and_then(Value::as_str);
        let (true, Some(method)) = (request.get("jsonrpc").and_then(Value::as_str) == Some("2.0"), method) else {
            return Some(rpc_error(Value::Null, -32600, "Invalid request"));
        };
        if method == "notifications/cancelled" && !request.contains_key("id") {
            if let Some(target) = request.get("params").and_then(|params| params.get("requestId")) {
                self.cancel_call(target);
            }
            return None;
        }
        let id = request.get("id")?.clone();
        if !(id.is_string() || id.is_number()) {
            return Some(rpc_error(Value::Null, -32600, "Invalid request ID"));
        }
        let empty = Map::new();
        let params = request.get("params").and_then(Value::as_object).unwrap_or(&empty);
        let result = match method {
            "initialize" => {
                let requested = params.get("protocolVersion").and_then(Value::as_str).unwrap_or("");
                let version = if PROTOCOLS.contains(&requested) { requested } else { PROTOCOLS[0] };
                let arabic = WorkshopStore::new(&self.bridge.engine.root).load().is_ok_and(|state| state.arabic);
                let name = if arabic { "الفواعلي (Fawaly)" } else { "Sudo Interns (Fawaly)" };
                *initialized = true;
                json!({"protocolVersion":version,"capabilities":{"tools":{"listChanged":false}},"serverInfo":{"name":name,"title":name,"version":crate::VERSION},"instructions":INSTRUCTIONS})
            }
            "ping" => json!({}),
            "tools/list" | "tools/call" if !*initialized => return Some(rpc_error(id, -32002, "Initialize the Fawaly session first")),
            "tools/list" => json!({"tools":tools()}),
            "tools/call" => {
                let Some(name) = params.get("name").and_then(Value::as_str) else {
                    return Some(rpc_error(id, -32602, "Expected a tool name"));
                };
                let arguments = match params.get("arguments") {
                    None => &empty,
                    Some(Value::Object(arguments)) => arguments,
                    Some(_) => return Some(rpc_error(id, -32602, "Tool arguments must be an object")),
                };
                match self.call_tool(name, arguments, &id.to_string()) {
                    Ok(value) => json!({"isError":false,"content":[{"type":"text","text":value.to_string()}],"structuredContent":value}),
                    Err(error) => json!({"isError":true,"content":[{"type":"text","text":error.to_string()}]}),
                }
            }
            _ => return Some(rpc_error(id, -32601, "Method not found")),
        };
        Some(json!({"jsonrpc":"2.0","id":id,"result":result}))
    }

    /// Tool calls run on their own threads, so status and stop stay usable
    /// during a long delegation. When input closes or a shutdown is requested,
    /// running workers are stopped.
    pub fn serve(&self, input: impl BufRead + Send + 'static, output: impl Write + Send + 'static) {
        fn write<W: Write>(output: &Mutex<W>, value: &Value) {
            let mut sink = output.lock().unwrap();
            let _ = writeln!(sink, "{value}");
            let _ = sink.flush();
        }
        let output = Arc::new(Mutex::new(output));
        let slots = Arc::new(AtomicUsize::new(0));
        let mut initialized = false;
        let mut handles = Vec::new();
        // A blocked read cannot notice a shutdown request, so it gets its own thread.
        let (frames, incoming) = sync_channel(CONCURRENCY);
        std::thread::spawn(move || {
            let mut input = input;
            loop {
                let frame = read_frame(&mut input);
                let closed = matches!(frame, Incoming::Closed);
                if frames.send(frame).is_err() || closed {
                    return;
                }
            }
        });
        while !crate::process::CANCELLED.load(Ordering::SeqCst) {
            let mut frame = match incoming.recv_timeout(Duration::from_millis(50)) {
                Ok(Incoming::Line(frame)) => frame,
                Ok(Incoming::Oversized) => {
                    write(&output, &rpc_error(Value::Null, -32700, "Message too large. Send at most 512 KB, with up to 64 KB of consult context."));
                    continue;
                }
                Ok(Incoming::Closed) | Err(RecvTimeoutError::Disconnected) => break,
                Err(RecvTimeoutError::Timeout) => continue,
            };
            while frame.last().is_some_and(|byte| *byte == b'\n' || *byte == b'\r') {
                frame.pop();
            }
            if frame.is_empty() {
                continue;
            }
            let parsed = serde_json::from_slice::<Value>(&frame).ok();
            let is_call = parsed.as_ref().and_then(|value| value["method"].as_str()) == Some("tools/call");
            let id = parsed.as_ref().and_then(|value| value.get("id")).cloned();
            if initialized && is_call && id.is_some() {
                if slots.fetch_add(1, Ordering::SeqCst) >= CONCURRENCY {
                    slots.fetch_sub(1, Ordering::SeqCst);
                    write(&output, &rpc_error(id.unwrap_or(Value::Null), -32000, "Too many concurrent team requests. Please retry."));
                    continue;
                }
                // Registered before the thread starts, so an immediate cancellation is seen.
                let key = id.unwrap_or(Value::Null).to_string();
                self.calls.lock().unwrap().insert(key.clone(), Call::Starting);
                let (server, output, slots) = (self.clone(), output.clone(), slots.clone());
                handles.push(std::thread::spawn(move || {
                    let mut ready = true;
                    let response = server.handle(&frame, &mut ready);
                    server.calls.lock().unwrap().remove(&key);
                    if let Some(response) = response {
                        write(&output, &response);
                    }
                    slots.fetch_sub(1, Ordering::SeqCst);
                }));
            } else if let Some(response) = self.handle(&frame, &mut initialized) {
                write(&output, &response);
            }
        }
        crate::process::CANCELLED.store(true, Ordering::SeqCst);
        self.drain(&handles);
    }

    /// Gives running calls a bounded time to finish. A call still blocked after
    /// that is abandoned with the process, so its job is closed here.
    fn drain(&self, handles: &[JoinHandle<()>]) {
        let finished = || handles.iter().all(JoinHandle::is_finished);
        let deadline = Instant::now() + DRAIN_LIMIT;
        while !finished() && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(20));
        }
        if finished() {
            return;
        }
        let log = TeamJobLog::new(&self.bridge.engine.root);
        for call in self.calls.lock().unwrap().values() {
            if let Call::Running(job) = call {
                let _ = log.mark_interrupted(*job);
            }
        }
    }
}

use std::io::Read as _;

#[cfg(test)]
mod tests {
    use super::*;
    use crate::secrets::MemorySecrets;
    use crate::Engine;

    fn server() -> (tempfile::TempDir, Server) {
        let root = tempfile::tempdir().unwrap();
        let engine = Engine::with(root.path().join("d"), root.path().join("h"), Arc::new(MemorySecrets::default()));
        (root, Server::new(Bridge::new(engine, Some(crate::model::Agent::Claude))))
    }

    fn call(server: &Server, frame: Value, initialized: &mut bool) -> Value {
        server.handle(frame.to_string().as_bytes(), initialized).unwrap()
    }

    #[test]
    fn tools_require_initialization() {
        let (_root, server) = server();
        let mut initialized = false;
        assert_eq!(call(&server, json!({"jsonrpc":"2.0","id":1,"method":"tools/list"}), &mut initialized)["error"]["code"], -32002);
        let reply = call(&server, json!({"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}), &mut initialized);
        assert_eq!(reply["result"]["protocolVersion"], "2025-06-18");
        assert_eq!(reply["result"]["serverInfo"]["name"], "Sudo Interns (Fawaly)");
        let reply = call(&server, json!({"jsonrpc":"2.0","id":3,"method":"tools/list"}), &mut initialized);
        let names: Vec<_> = reply["result"]["tools"].as_array().unwrap().iter().map(|tool| tool["name"].as_str().unwrap()).collect();
        assert_eq!(names, ["status", "roster_get", "delegate", "consult", "stop", "review", "consult_decide"]);
    }

    #[test]
    fn notifications_get_no_reply() {
        let (_root, server) = server();
        let mut initialized = false;
        assert!(server.handle(br#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#, &mut initialized).is_none());
    }

    #[test]
    fn rejects_unknown_arguments_and_bad_enums() {
        let (_root, server) = server();
        let mut initialized = true;
        let reply = call(&server, json!({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"status","arguments":{"surprise":"x"}}}), &mut initialized);
        assert_eq!(reply["result"]["isError"], true);
        let reply = call(&server, json!({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"consult","arguments":{"question":"q","reason":"whim"}}}), &mut initialized);
        assert!(reply["result"]["content"][0]["text"].as_str().unwrap().contains("Use one of these values"));
    }

    #[test]
    fn task_kinds_are_limited_in_the_schema_and_at_the_call() {
        let (_root, server) = server();
        let delegate = tools().iter().find(|tool| tool["name"] == "delegate").unwrap();
        assert_eq!(delegate["inputSchema"]["properties"]["kind"]["enum"], json!(TASK_KINDS));
        let mut initialized = true;
        let reply = call(&server, json!({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"delegate","arguments":{"brief":"b","kind":"bugfix"}}}), &mut initialized);
        assert!(reply["result"]["content"][0]["text"].as_str().unwrap().contains("Use one of these values for kind"));
    }

    #[test]
    fn an_oversized_line_is_dropped_and_the_next_one_is_read() {
        let mut data = vec![b'x'; FRAME_LIMIT + 4096];
        data.extend_from_slice(b"\n{\"next\":1}\n");
        let mut input = std::io::BufReader::with_capacity(1024, std::io::Cursor::new(data));
        assert!(matches!(read_frame(&mut input), Incoming::Oversized));
        assert!(matches!(read_frame(&mut input), Incoming::Line(line) if line == b"{\"next\":1}\n"));
        assert!(matches!(read_frame(&mut input), Incoming::Closed));
    }

    #[test]
    fn the_frame_limit_counts_the_newline() {
        let mut data = vec![b'x'; FRAME_LIMIT];
        data.push(b'\n');
        data.extend_from_slice(b"y\n");
        let mut input = std::io::Cursor::new(data);
        assert!(matches!(read_frame(&mut input), Incoming::Oversized), "the newline is the byte over the limit");
        assert!(matches!(read_frame(&mut input), Incoming::Line(line) if line == b"y\n"), "and nothing after it is lost");
        let mut data = vec![b'x'; FRAME_LIMIT - 1];
        data.push(b'\n');
        assert!(matches!(read_frame(&mut std::io::Cursor::new(data)), Incoming::Line(line) if line.len() == FRAME_LIMIT));
    }

    /// A worker that runs until its job's stop file appears, as native workers do.
    fn waiting_server() -> (tempfile::TempDir, Server) {
        use crate::confine::Confinement;
        use crate::model::{Agent, AdvisorSettings, TeamSettings, WorkshopState};
        use crate::native::WorkerOutcome;
        let root = tempfile::tempdir().unwrap();
        let engine = Engine::with(root.path().join("d"), root.path().join("h"), Arc::new(MemorySecrets::default()));
        let team = TeamSettings { primary: Agent::Claude, advisor: None, workers: vec![Agent::Kimi] };
        WorkshopStore::new(&engine.root).save(&WorkshopState { team: Some(team), advisors: AdvisorSettings::default(), ..Default::default() }).unwrap();
        let worker: crate::bridge::WorkerFn = Arc::new(move |_, _, _, _, stop, _| {
            let stop = stop.unwrap();
            let deadline = std::time::Instant::now() + Duration::from_secs(20);
            while !stop.exists() {
                assert!(std::time::Instant::now() < deadline, "the stop was never requested");
                std::thread::sleep(Duration::from_millis(10));
            }
            Ok(WorkerOutcome { answer: Err(Error::Stopped), confinement: Confinement::ToolLevel, git_changes: vec![], git_scan_incomplete: false })
        });
        let bridge = Bridge::with_doubles(engine, Some(Agent::Claude), worker, Arc::new(|_| true));
        (root, Server::new(bridge))
    }

    fn cancellation_of(id: u64) -> Vec<u8> {
        json!({"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":id,"reason":"user interrupted"}}).to_string().into_bytes()
    }

    fn delegation_of(id: u64) -> Vec<u8> {
        json!({"jsonrpc":"2.0","id":id,"method":"tools/call","params":{"name":"delegate","arguments":{"brief":"long job"}}}).to_string().into_bytes()
    }

    #[test]
    fn a_cancelled_delegate_stops_its_job() {
        let (_root, server) = waiting_server();
        server.calls.lock().unwrap().insert("7".to_string(), Call::Starting);
        let running = server.clone();
        let call = std::thread::spawn(move || running.handle(&delegation_of(7), &mut true).unwrap());
        let deadline = std::time::Instant::now() + Duration::from_secs(10);
        while !matches!(server.calls.lock().unwrap().get("7"), Some(Call::Running(_))) {
            assert!(std::time::Instant::now() < deadline, "the job never started");
            std::thread::sleep(Duration::from_millis(5));
        }
        assert!(server.handle(&cancellation_of(99), &mut true).is_none(), "an unknown call is ignored");
        assert!(server.handle(&cancellation_of(7), &mut true).is_none(), "a notification has no reply");
        let reply = call.join().unwrap();
        assert_eq!(reply["result"]["structuredContent"]["status"], "cancelled", "{reply}");
        assert_eq!(reply["result"]["structuredContent"]["confinement"], "tool_level");
    }

    #[test]
    fn a_cancellation_that_arrives_first_still_stops_the_job() {
        let (_root, server) = waiting_server();
        server.calls.lock().unwrap().insert("8".to_string(), Call::Starting);
        assert!(server.handle(&cancellation_of(8), &mut true).is_none());
        let reply = server.handle(&delegation_of(8), &mut true).unwrap();
        assert_eq!(reply["result"]["structuredContent"]["status"], "cancelled", "{reply}");
    }

    #[test]
    fn malformed_frames_are_answered_not_fatal() {
        let (_root, server) = server();
        let mut initialized = false;
        assert_eq!(server.handle(b"not json", &mut initialized).unwrap()["error"]["code"], -32700);
        assert_eq!(call(&server, json!({"jsonrpc":"1.0","id":1,"method":"ping"}), &mut initialized)["error"]["code"], -32600);
    }

    #[test]
    fn team_instructions_fit_and_lead_with_using_the_team() {
        assert!(INSTRUCTIONS.len() < 2048, "clients may cut longer instructions: {}", INSTRUCTIONS.len());
        assert!(INSTRUCTIONS[..200].contains("Before you change any file, use the team"));
    }

    #[test]
    fn parses_durations() {
        assert_eq!(parse_seconds("90s").unwrap(), 90);
        assert_eq!(parse_seconds("15m").unwrap(), 900);
        assert_eq!(parse_seconds("1h").unwrap(), 3600);
        assert_eq!(parse_seconds("900").unwrap(), 900);
        for bad in ["0", "3601", "2h", "61m", "abc", ""] {
            assert!(parse_seconds(bad).is_err(), "{bad}");
        }
    }
}
