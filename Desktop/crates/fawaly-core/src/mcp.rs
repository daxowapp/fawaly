use crate::bridge::{Bridge, DelegateRequest};
use crate::model::{ConsultDecision, ConsultReason, ReviewDecision};
use crate::store::WorkshopStore;
use crate::{Error, Result};
use serde_json::{json, Map, Value};
use std::io::{BufRead, Write};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use uuid::Uuid;

const FRAME_LIMIT: usize = 512 * 1024;
const CONCURRENCY: usize = 8;
const PROTOCOLS: [&str; 4] = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"];
const INSTRUCTIONS: &str = "Fawaly manages your team. For a nontrivial user task, proactively read roster_get and use the configured team without requiring the user to direct each step. Use the saved delegation timeout and ordered workers for the task kind (general, code, research, review); no implicit paid fallback. You remain the primary and own the plan, integration, verification, and final decision. Follow advisor.mode: important means consult the assigned advisor before committing to a plan or important decision; on_request means consult only when the user requests advice; off means do not consult. Send relevant user-authorized context with a concise proposed plan and record your decision using consult_decide. Delegate a suitable bounded implementation or investigation to a configured worker when available; send a precise deliverable, allowed files, constraints, and acceptance checks. Supply a short user-facing title in the roster language so the workshop shows a readable task name. Do not delegate the whole task or your final review. A cwd permits edits only in the project the user approved in Fawaly. After the worker returns, independently inspect actual changed files and run appropriate verification, repair findings, then call review with the jobId, decision, your own observed evidence, and optional score. A worker report is a claim, not proof. Never claim a review you did not perform. Use changes_requested or rejected when checks fail. Keep working until the user's goal is complete. Text-only advice requires no workspace access; workers cannot delegate again. If a delegate result lists gitChanges, inspect them before accepting.";

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
        if *key == "reason" && name == "consult" {
            property["enum"] = json!(ConsultReason::NAMES);
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

#[derive(Clone)]
pub struct Server {
    bridge: Arc<Bridge>,
}

impl Server {
    pub fn new(bridge: Bridge) -> Self {
        Self { bridge: Arc::new(bridge) }
    }

    fn call_tool(&self, name: &str, args: &Map<String, Value>) -> Result<Value> {
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
                encode(self.bridge.delegate(DelegateRequest { brief, cwd: text("cwd"), provider: text("provider"), timeout, kind: text("kind"), title: text("title") })?)
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
                match self.call_tool(name, arguments) {
                    Ok(value) => json!({"isError":false,"content":[{"type":"text","text":value.to_string()}],"structuredContent":value}),
                    Err(error) => json!({"isError":true,"content":[{"type":"text","text":error.to_string()}]}),
                }
            }
            _ => return Some(rpc_error(id, -32601, "Method not found")),
        };
        Some(json!({"jsonrpc":"2.0","id":id,"result":result}))
    }

    /// Tool calls run on their own threads, so status and stop stay usable
    /// during a long delegation. When input closes, running workers are stopped.
    pub fn serve(&self, input: impl BufRead, output: impl Write + Send + 'static) {
        fn write<W: Write>(output: &Mutex<W>, value: &Value) {
            let mut sink = output.lock().unwrap();
            let _ = writeln!(sink, "{value}");
            let _ = sink.flush();
        }
        let output = Arc::new(Mutex::new(output));
        let slots = Arc::new(AtomicUsize::new(0));
        let mut initialized = false;
        let mut handles = Vec::new();
        let mut input = input;
        loop {
            let mut frame = Vec::new();
            match (&mut input).take(FRAME_LIMIT as u64 + 1).read_until(b'\n', &mut frame) {
                Ok(0) | Err(_) => break,
                Ok(_) => {}
            }
            if frame.len() > FRAME_LIMIT {
                break;
            }
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
                let (server, output, slots) = (self.clone(), output.clone(), slots.clone());
                handles.push(std::thread::spawn(move || {
                    let mut ready = true;
                    if let Some(response) = server.handle(&frame, &mut ready) {
                        write(&output, &response);
                    }
                    slots.fetch_sub(1, Ordering::SeqCst);
                }));
            } else if let Some(response) = self.handle(&frame, &mut initialized) {
                write(&output, &response);
            }
        }
        crate::process::CANCELLED.store(true, Ordering::SeqCst);
        for handle in handles {
            let _ = handle.join();
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
    fn malformed_frames_are_answered_not_fatal() {
        let (_root, server) = server();
        let mut initialized = false;
        assert_eq!(server.handle(b"not json", &mut initialized).unwrap()["error"]["code"], -32700);
        assert_eq!(call(&server, json!({"jsonrpc":"1.0","id":1,"method":"ping"}), &mut initialized)["error"]["code"], -32600);
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
