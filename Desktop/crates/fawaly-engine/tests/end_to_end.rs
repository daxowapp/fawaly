//! Drives the real engine binary over MCP stdio, with a scripted primary and a
//! local fake model. It proves the engine, tools and file boundary on this OS.
//! It does not prove that a real model chooses to consult, delegate or review.

use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpListener;
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::sync::{Arc, Mutex};

struct Mcp {
    child: Child,
    stdin: Option<ChildStdin>,
    stdout: BufReader<ChildStdout>,
    next: u64,
}

impl Mcp {
    fn start(data: &Path, home: &Path, client: &str) -> Self {
        let mut child = Command::new(env!("CARGO_BIN_EXE_sudo-interns-engine"))
            .args(["mcp", "--client", client])
            .env("SUDO_INTERNS_DATA_DIR", data)
            .env("SUDO_INTERNS_HOME", home)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .unwrap();
        let stdin = child.stdin.take();
        let stdout = BufReader::new(child.stdout.take().unwrap());
        let mut session = Self { child, stdin, stdout, next: 1 };
        session.request("initialize", json!({"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"e2e","version":"1"}}));
        writeln!(session.stdin.as_mut().unwrap(), "{}", json!({"jsonrpc":"2.0","method":"notifications/initialized"})).unwrap();
        session
    }

    fn request(&mut self, method: &str, params: Value) -> Value {
        let id = self.next;
        self.next += 1;
        writeln!(self.stdin.as_mut().unwrap(), "{}", json!({"jsonrpc":"2.0","id":id,"method":method,"params":params})).unwrap();
        self.stdin.as_mut().unwrap().flush().unwrap();
        let mut line = String::new();
        self.stdout.read_line(&mut line).unwrap();
        let reply: Value = serde_json::from_str(&line).unwrap();
        assert_eq!(reply["id"], json!(id), "{reply}");
        reply["result"].clone()
    }

    fn tool(&mut self, name: &str, arguments: Value) -> Value {
        let result = self.request("tools/call", json!({"name":name,"arguments":arguments}));
        assert_eq!(result["isError"], json!(false), "{name}: {result}");
        result["structuredContent"].clone()
    }

    fn tool_error(&mut self, name: &str, arguments: Value) -> String {
        let result = self.request("tools/call", json!({"name":name,"arguments":arguments}));
        assert_eq!(result["isError"], json!(true), "{name}: {result}");
        result["content"][0]["text"].as_str().unwrap().to_string()
    }
}

impl Drop for Mcp {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// Answers OpenAI-format chat requests from a script, in order.
fn fake_model(replies: Vec<Value>) -> (u16, Arc<Mutex<Vec<Value>>>) {
    let listener = TcpListener::bind(("127.0.0.1", 0)).unwrap();
    let port = listener.local_addr().unwrap().port();
    let seen = Arc::new(Mutex::new(Vec::new()));
    let observed = seen.clone();
    std::thread::spawn(move || {
        let mut replies = replies.into_iter();
        for stream in listener.incoming() {
            let mut stream = stream.unwrap();
            let mut data = Vec::new();
            let mut buffer = [0_u8; 8192];
            let (header_end, length) = loop {
                let count = stream.read(&mut buffer).unwrap();
                data.extend_from_slice(&buffer[..count]);
                if let Some(end) = data.windows(4).position(|window| window == b"\r\n\r\n") {
                    let head = String::from_utf8_lossy(&data[..end]).to_lowercase();
                    let length: usize = head.lines().find_map(|line| line.strip_prefix("content-length:")).unwrap().trim().parse().unwrap();
                    break (end + 4, length);
                }
            };
            while data.len() < header_end + length {
                let count = stream.read(&mut buffer).unwrap();
                data.extend_from_slice(&buffer[..count]);
            }
            observed.lock().unwrap().push(serde_json::from_slice::<Value>(&data[header_end..]).unwrap());
            let body = replies.next().expect("unexpected model request").to_string();
            write!(stream, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()).unwrap();
        }
    });
    (port, seen)
}

struct Profile {
    _base: tempfile::TempDir,
    data: PathBuf,
    home: PathBuf,
    project: PathBuf,
}

/// A fresh profile: Claude primary, a keyless local assistant as worker and advisor.
fn profile(advisor_port: u16, worker_port: u16) -> Profile {
    let base = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(base.path()).unwrap();
    let root = PathBuf::from(root.to_string_lossy().trim_start_matches(r"\\?\"));
    let home = root.join("home");
    let data = home.join("data-root");
    let project = home.join("code").join("demo");
    std::fs::create_dir_all(&project).unwrap();
    std::fs::create_dir_all(&data).unwrap();
    std::fs::write(project.join("greeting.txt"), "hello\n").unwrap();
    let state = json!({
        "team": {"primary":"claude","advisor":"ollama","workers":["lmstudio"]},
        "advisors": {"mode":"important","maxRounds":3,"timeoutMinutes":1,"seats":[]},
        "onboardingVersion": 1
    });
    std::fs::write(data.join("workshop.json"), serde_json::to_vec(&state).unwrap()).unwrap();
    let assistant = |agent: &str, port: u16| json!({"agent":agent,"endpoint":format!("http://127.0.0.1:{port}/v1/chat/completions"),"model":"local-model","format":"openAI","enabled":true,"dailyRequestLimit":100,"maxRounds":12});
    std::fs::write(data.join("api-assistants.json"), serde_json::to_vec(&json!([assistant("ollama", advisor_port), assistant("lmstudio", worker_port)])).unwrap()).unwrap();
    Profile { _base: base, data, home, project }
}

fn allow(profile: &Profile) {
    let status = Command::new(env!("CARGO_BIN_EXE_sudo-interns-engine"))
        .arg("allow-workspace")
        .arg(&profile.project)
        .env("SUDO_INTERNS_DATA_DIR", &profile.data)
        .env("SUDO_INTERNS_HOME", &profile.home)
        .status()
        .unwrap();
    assert!(status.success());
}

fn tool_call(id: &str, name: &str, arguments: Value) -> Value {
    json!({"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":id,"type":"function","function":{"name":name,"arguments":arguments.to_string()}}]}}]})
}

fn text(content: &str) -> Value {
    json!({"choices":[{"message":{"role":"assistant","content":content},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":5}})
}

#[test]
fn primary_consults_delegates_and_reviews_a_real_file_edit() {
    let digest = "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03"; // sha256("hello\n")
    let (advisor_port, advisor_seen) = fake_model(vec![text("Plan looks sound. Verify the file afterwards.")]);
    let (worker_port, worker_seen) = fake_model(vec![
        tool_call("1", "read_file", json!({"path":"greeting.txt"})),
        tool_call("2", "write_file", json!({"path":"greeting.txt","content":"hello team\n","expected_sha256":digest})),
        tool_call("3", "write_file", json!({"path":"../escaped.txt","content":"nope","expected_sha256":""})),
        text("Updated greeting.txt"),
    ]);
    let profile = profile(advisor_port, worker_port);
    allow(&profile);
    let mut mcp = Mcp::start(&profile.data, &profile.home, "claude");

    let roster = mcp.tool("roster_get", json!({}));
    assert_eq!(roster["team"]["primary"], "claude");
    assert_eq!(roster["advisor"]["mode"], "important");

    let consult = mcp.tool("consult", json!({"question":"Plan: update greeting. Sound?","context":"small change","reason":"plan"}));
    assert_eq!(consult["rounds"][0]["advice"], "Plan looks sound. Verify the file afterwards.");
    mcp.tool("consult_decide", json!({"consultId":consult["id"],"decision":"adopted","summary":"Proceed"}));

    let job = mcp.tool("delegate", json!({"brief":"Change greeting.txt to say hello team","cwd":profile.project,"title":"Update greeting","kind":"code"}));
    assert_eq!(job["status"], "needs_handoff", "{job}");
    assert_eq!(job["reviewRequired"], true);
    assert_eq!(job["confinement"], "app_enforced");

    // The primary's own inspection of the actual file, as a review requires.
    assert_eq!(std::fs::read_to_string(profile.project.join("greeting.txt")).unwrap().replace("\r\n", "\n"), "hello team\n");
    assert!(!profile.project.parent().unwrap().join("escaped.txt").exists(), "a write outside the project must not happen");

    let reviewed = mcp.tool("review", json!({"jobId":job["jobId"],"decision":"accepted","summary":"Greeting updated","verification":"Read greeting.txt and confirmed its contents","score":"5"}));
    assert_eq!(reviewed["status"], "reviewed");
    assert_eq!(reviewed["reviews"][0]["primary"], "claude");

    assert_eq!(advisor_seen.lock().unwrap().len(), 1);
    let worker = worker_seen.lock().unwrap();
    assert_eq!(worker.len(), 4);
    let tool_result = worker[3]["messages"].as_array().unwrap().last().unwrap().clone();
    assert!(tool_result["content"].as_str().unwrap().starts_with("Tool error:"), "{tool_result}");
}

#[test]
fn delegation_outside_the_approved_project_is_refused() {
    let (advisor_port, _) = fake_model(vec![]);
    let (worker_port, seen) = fake_model(vec![]);
    let profile = profile(advisor_port, worker_port);
    let mut mcp = Mcp::start(&profile.data, &profile.home, "claude");
    let error = mcp.tool_error("delegate", json!({"brief":"Edit it","cwd":profile.project}));
    assert!(error.contains("Workspace access is off"), "{error}");
    assert!(seen.lock().unwrap().is_empty(), "no model request may be sent");
}

#[test]
fn another_client_cannot_use_this_team() {
    let (advisor_port, _) = fake_model(vec![]);
    let (worker_port, seen) = fake_model(vec![]);
    let profile = profile(advisor_port, worker_port);
    allow(&profile);
    let mut mcp = Mcp::start(&profile.data, &profile.home, "codex");
    let error = mcp.tool_error("delegate", json!({"brief":"Edit it","cwd":profile.project}));
    assert!(error.contains("configured primary"), "{error}");
    assert!(seen.lock().unwrap().is_empty());
}

#[test]
fn closing_the_client_ends_the_engine() {
    let (advisor_port, _) = fake_model(vec![]);
    let (worker_port, _) = fake_model(vec![]);
    let profile = profile(advisor_port, worker_port);
    let mut session = Mcp::start(&profile.data, &profile.home, "claude");
    drop(session.stdin.take());
    let status = session.child.wait().unwrap();
    assert!(status.success(), "{status:?}");
}
