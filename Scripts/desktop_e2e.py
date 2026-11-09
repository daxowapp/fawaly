#!/usr/bin/env python3
"""Exercises installed Windows and Linux packages on the system itself.

  smoke APP [ENGINE]   launch, relaunch, and check the bundled engine
  onboarding APP       drive the real UI with a fresh profile through tauri-driver,
                       then run a scripted primary over the MCP entry the UI registered
  real-primary APP     same setup, then a real Claude Code model leads (needs a token)

Uses only the standard library. The scripted primary proves the app, engine and
tools work on this OS. It does not prove a real model decides to use them.
"""

import http.client
import json
import os
import pathlib
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

WINDOWS = os.name == "nt"
DRIVER = "http://127.0.0.1:4444"
GREETING_DIGEST = "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03"


def log(message):
    print(f"[e2e] {message}", flush=True)


def engine_beside(app):
    name = "sudo-interns-engine.exe" if WINDOWS else "sudo-interns-engine"
    candidate = pathlib.Path(app).resolve().parent / name
    if not candidate.exists():
        raise SystemExit(f"engine not found beside the app: {candidate}")
    return candidate


def mcp_tools(command, env):
    frames = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": "smoke", "version": "1"}}},
        {"jsonrpc": "2.0", "method": "notifications/initialized"},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
    ]
    payload = "".join(json.dumps(frame) + "\n" for frame in frames)
    done = subprocess.run(command, input=payload, capture_output=True, text=True, env=env, timeout=30)
    replies = [json.loads(line) for line in done.stdout.splitlines() if line.strip()]
    listing = next(reply for reply in replies if reply.get("id") == 2)
    return {tool["name"] for tool in listing["result"]["tools"]}


def launch_once(app, env, seconds):
    process = subprocess.Popen([str(app)], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    time.sleep(seconds)
    alive = process.poll() is None
    if alive:
        process.terminate()
        try:
            process.wait(10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
    return alive, process.stderr.read().decode(errors="replace")[-2000:]


def ui_selftest(app):
    """Proves the page rendered and IPC works in this system WebView, in both languages."""
    folder = pathlib.Path(tempfile.mkdtemp(prefix="sudo-interns-ui-"))
    report = folder / "report.jsonl"
    env = {**os.environ, "SUDO_INTERNS_DATA_DIR": str(folder / "data"), "SUDO_INTERNS_UI_SELFTEST": str(report)}
    process = subprocess.Popen([str(app)], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    deadline = time.time() + 120
    lines = []
    while time.time() < deadline and len(lines) < 2:
        assert process.poll() is None, f"app exited during the UI check\n{process.stderr.read().decode(errors='replace')[-2000:]}"
        lines = report.read_text(encoding="utf-8").splitlines() if report.exists() else []
        time.sleep(0.5)
    process.terminate()
    assert len(lines) >= 2, "the page never reported that it rendered"
    english, arabic = (json.loads(line) for line in lines[:2])
    assert english["dir"] == "ltr" and "Sudo Interns" in english["text"], english
    assert arabic["dir"] == "rtl" and "الفواعلي" in arabic["text"], arabic
    log("UI rendered in English (LTR) and Arabic (RTL)")


def smoke(app, engine_path=None):
    data = pathlib.Path(tempfile.mkdtemp(prefix="sudo-interns-smoke-"))
    env = {**os.environ, "SUDO_INTERNS_DATA_DIR": str(data)}
    engine = pathlib.Path(engine_path) if engine_path else engine_beside(app)
    version = subprocess.run([str(engine), "version"], capture_output=True, text=True, env=env, timeout=30)
    assert version.returncode == 0 and version.stdout.strip(), version
    log(f"engine version {version.stdout.strip()}")
    assert {"roster_get", "consult", "delegate", "review"} <= mcp_tools([str(engine), "mcp", "--client", "claude"], env)
    log("engine answered MCP tools/list")
    for attempt in ("first launch", "relaunch"):
        alive, errors = launch_once(app, env, 12)
        assert alive, f"{attempt}: app exited early\n{errors}"
        log(f"{attempt}: app stayed running")
    launcher = data / "bin" / engine.name
    assert launcher.is_file(), "the app did not create its stable engine launcher"
    log("stable engine launcher exists")
    assert not (data / "workshop.json").exists(), "a fresh profile must stay unconfigured until onboarding"
    assert {"delegate"} <= mcp_tools([str(launcher), "mcp", "--client", "codex"], env)
    ui_selftest(app)
    log("smoke passed")


class FakeModel(BaseHTTPRequestHandler):
    """An OpenAI-format endpoint that plays back a script."""

    replies = {}
    seen = {}

    def do_POST(self):
        port = self.server.server_address[1]
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        FakeModel.seen.setdefault(port, []).append(body)
        answer = json.dumps(FakeModel.replies[port].pop(0)).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(answer)))
        self.end_headers()
        self.wfile.write(answer)

    def log_message(self, *_):
        pass


def text_reply(content):
    return {"choices": [{"message": {"role": "assistant", "content": content}, "finish_reason": "stop"}]}


def tool_reply(call_id, name, arguments):
    return {"choices": [{"message": {"role": "assistant", "content": None, "tool_calls": [{"id": call_id, "type": "function", "function": {"name": name, "arguments": json.dumps(arguments)}}]}}]}


def serve(port, replies):
    FakeModel.replies[port] = replies
    server = ThreadingHTTPServer(("127.0.0.1", port), FakeModel)
    threading.Thread(target=server.serve_forever, daemon=True).start()


class WebDriver:
    def __init__(self, app):
        reply = self.call("POST", "/session", {"capabilities": {"alwaysMatch": {"tauri:options": {"application": str(app)}}}})
        self.session = reply["sessionId"]

    def call(self, method, path, body=None):
        data = None if body is None else json.dumps(body).encode()
        request = urllib.request.Request(DRIVER + path, data=data, method=method, headers={"Content-Type": "application/json"})
        for attempt in range(3):
            try:
                with urllib.request.urlopen(request, timeout=300) as response:
                    return json.load(response)["value"]
            except urllib.error.HTTPError as error:
                raise RuntimeError(f"{method} {path}: {error.read().decode(errors='replace')}") from None
            except (http.client.RemoteDisconnected, ConnectionResetError) as error:
                # tauri-driver can reuse a connection the native driver already closed.
                if attempt == 2:
                    raise
                log(f"driver connection dropped ({error}); retrying {method} {path}")
                time.sleep(1)

    def do(self, method, path, body=None):
        return self.call(method, f"/session/{self.session}{path}", body)

    def find(self, testid, timeout=30):
        deadline = time.time() + timeout
        selector = {"using": "css selector", "value": f'[data-testid="{testid}"]'}
        while True:
            found = self.do("POST", "/elements", selector)
            if found:
                return next(iter(found[0].values()))
            if time.time() > deadline:
                self.screenshot(f"missing-{testid}")
                raise RuntimeError(f"element not found: {testid}\n{self.text()}")
            time.sleep(0.25)

    def click(self, testid, timeout=30):
        deadline = time.time() + timeout
        while True:
            try:
                element = self.find(testid, timeout)
                if self.do("GET", f"/element/{element}/enabled"):
                    self.do("POST", f"/element/{element}/click", {})
                    return
            except RuntimeError as error:
                # The UI redraws often, which can replace an element between steps.
                if "stale" not in str(error):
                    raise
            if time.time() > deadline:
                self.screenshot(f"disabled-{testid}")
                raise RuntimeError(f"still disabled: {testid}\n{self.text()}")
            time.sleep(0.5)

    def type_into(self, testid, value):
        element = self.find(testid)
        self.do("POST", f"/element/{element}/clear", {})
        self.do("POST", f"/element/{element}/value", {"text": value})

    def script(self, source):
        return self.do("POST", "/execute/sync", {"script": source, "args": []})

    def text(self):
        return self.script("return document.body.innerText")

    def screenshot(self, name):
        import base64

        folder = pathlib.Path(os.environ.get("E2E_SCREENSHOTS", "e2e-screenshots"))
        folder.mkdir(parents=True, exist_ok=True)
        try:
            (folder / f"{name}.png").write_bytes(base64.b64decode(self.do("GET", "/screenshot")))
        except Exception as error:  # A failed picture must not hide the real failure.
            log(f"screenshot failed: {error}")

    def wait_text(self, needle, timeout=30):
        deadline = time.time() + timeout
        while needle not in self.text():
            if time.time() > deadline:
                self.screenshot(f"missing-text-{needle[:20]}")
                raise RuntimeError(f"text not found: {needle}\n{self.text()}")
            time.sleep(0.25)

    def quit(self):
        self.do("DELETE", "")


class Primary:
    """Scripted stand-in for Codex or Claude Code, using the registered MCP entry."""

    def __init__(self, command, env):
        self.process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, encoding="utf-8", env=env)
        self.next_id = 1
        self.request("initialize", {"protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": "e2e", "version": "1"}})

    def request(self, method, params):
        request_id = self.next_id
        self.next_id += 1
        self.process.stdin.write(json.dumps({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params}) + "\n")
        self.process.stdin.flush()
        reply = json.loads(self.process.stdout.readline())
        assert reply["id"] == request_id, reply
        return reply["result"]

    def tool(self, name, arguments):
        result = self.request("tools/call", {"name": name, "arguments": arguments})
        assert result["isError"] is False, (name, result)
        return result["structuredContent"]

    def close(self):
        self.process.stdin.close()
        self.process.wait(30)


def default_data_root():
    if WINDOWS:
        return pathlib.Path(os.environ["APPDATA"]) / "SudoInterns"
    return pathlib.Path(os.environ.get("XDG_DATA_HOME", pathlib.Path.home() / ".local" / "share")) / "SudoInterns"


def codex_home():
    return pathlib.Path.home() / ".codex"


def ui_setup(driver, primary, primary_label):
    """Walks the real onboarding screens: team, official CLI download, accounts, connect."""
    driver.click("next")
    driver.find(f"choice-{primary}")
    driver.click(f"choice-{primary}")
    driver.script("""
        const select = document.querySelector('[data-testid="advisor"]');
        select.value = 'ollama';
        select.dispatchEvent(new Event('change'));
    """)
    driver.click("worker-lmstudio")
    driver.screenshot("03-team")
    driver.click("next")

    log(f"downloading the official {primary_label} CLI through the app")
    driver.find("next")
    driver.wait_text(primary_label)
    driver.click("next", 60)
    driver.find("save-ollama", 600)
    driver.screenshot("04-accounts")

    for agent in ("ollama", "lmstudio"):
        driver.type_into(f"model-{agent}", "local-model")
        driver.click(f"save-{agent}")
        driver.wait_text("Saved.", 30)
        time.sleep(0.5)

    driver.click("next", 30)
    driver.find("next")
    driver.screenshot("05-finish")
    log(f"connecting the team to the real {primary_label} CLI")
    driver.click("next", 60)
    driver.find("nav-home", 120)


def onboarding(app):
    app = pathlib.Path(app).resolve()
    data = default_data_root()
    assert not data.exists(), "onboarding must start from a fresh profile"

    # Another MCP server the user already had. It must survive setup.
    codex_home().mkdir(exist_ok=True)
    config = codex_home() / "config.toml"
    existing = '[mcp_servers.keep_me]\ncommand = "keep-me-command"\nargs = ["--stay"]\n'
    config.write_text(existing, encoding="utf-8")

    project = pathlib.Path.home() / "sudo-interns-e2e-project"
    shutil.rmtree(project, ignore_errors=True)
    project.mkdir()
    (project / "greeting.txt").write_bytes(b"hello\n")

    serve(11434, [text_reply("Plan is sound. Check the file afterwards.")])
    serve(1234, [
        tool_reply("1", "read_file", {"path": "greeting.txt"}),
        tool_reply("2", "write_file", {"path": "greeting.txt", "content": "hello team\n", "expected_sha256": GREETING_DIGEST}),
        tool_reply("3", "write_file", {"path": "../escaped.txt", "content": "nope", "expected_sha256": ""}),
        text_reply("Updated greeting.txt"),
    ])

    driver = WebDriver(app)
    try:
        driver.find("next")
        assert not (data / "workshop.json").exists()
        driver.wait_text("Sudo Interns")
        assert driver.script("return document.documentElement.dir") == "ltr", "English must be the default"
        driver.screenshot("01-welcome-en")

        driver.click("language")
        driver.wait_text("الفواعلي")
        assert driver.script("return document.documentElement.dir") == "rtl"
        driver.screenshot("02-welcome-ar")
        driver.click("language")
        driver.wait_text("Sudo Interns")

        ui_setup(driver, "codex", "Codex")
        driver.screenshot("06-home")
        driver.click("nav-skills")
        driver.wait_text("Skills")
        driver.screenshot("07-skills")
        driver.click("nav-settings")
        driver.wait_text("What works on this computer")
        driver.screenshot("08-settings")
    finally:
        driver.quit()

    state = json.loads((data / "workshop.json").read_text(encoding="utf-8"))
    assert state["team"] == {"primary": "codex", "advisor": "ollama", "workers": ["lmstudio"]}, state["team"]

    text = config.read_text(encoding="utf-8")
    assert "[mcp_servers.keep_me]" in text and "keep-me-command" in text, text
    assert "[mcp_servers.fawaly_team]" in text, text
    log("existing MCP server preserved; team registered in the real Codex config")

    codex_name = "codex.exe" if WINDOWS else "codex"
    runtime = data / "runtimes" / "codex"
    codex = next(path for path in [runtime / codex_name, runtime / "bin" / codex_name] if path.is_file())
    env = {**os.environ, "CODEX_HOME": str(codex_home())}
    entry = json.loads(subprocess.run([str(codex), "mcp", "get", "fawaly_team", "--json"], capture_output=True, text=True, env=env, timeout=30, check=True).stdout)["transport"]
    log(f"Codex reports the team at {entry['command']}")

    launcher = pathlib.Path(entry["command"])
    subprocess.run([str(launcher), "allow-workspace", str(project)], check=True, env=os.environ.copy(), timeout=30)
    primary = Primary([str(launcher), *entry["args"]], os.environ.copy())
    roster = primary.tool("roster_get", {})
    assert roster["team"]["primary"] == "codex", roster
    consult = primary.tool("consult", {"question": "Plan: update the greeting. Sound?", "context": "small change", "reason": "plan"})
    assert "sound" in consult["rounds"][0]["advice"]
    primary.tool("consult_decide", {"consultId": consult["id"], "decision": "adopted", "summary": "Proceed"})
    job = primary.tool("delegate", {"brief": "Change greeting.txt to say hello team", "cwd": str(project), "title": "Update greeting", "kind": "code"})
    assert job["status"] == "needs_handoff" and job["confinement"] == "app_enforced", job
    assert (project / "greeting.txt").read_bytes().replace(b"\r\n", b"\n") == b"hello team\n"
    assert not (project.parent / "escaped.txt").exists(), "a write escaped the approved project"
    reviewed = primary.tool("review", {"jobId": job["jobId"], "decision": "accepted", "summary": "Greeting updated", "verification": "Read greeting.txt and confirmed its contents", "score": "5"})
    assert reviewed["status"] == "reviewed", reviewed
    primary.close()
    log("onboarding, registration, consult, delegate and review passed")

    driver = WebDriver(app)
    try:
        driver.find("nav-tasks")
        driver.click("nav-tasks")
        driver.wait_text("Update greeting")
        driver.screenshot("09-ledger-after-relaunch")
        log("the ledger shows the reviewed task after relaunch")
    finally:
        driver.quit()


def start_driver():
    native = os.environ.get("EDGE_DRIVER")
    process = subprocess.Popen(["tauri-driver", *(["--native-driver", native] if native else [])], env=os.environ.copy())
    time.sleep(3)
    return process


def real_primary(app):
    """A real Claude Code model leads, with no step-by-step direction.

    Only team tools and read-only tools are allowed, so this shows the model
    follows consult, delegate and review. It does not show whether the model
    would choose delegation over editing a file itself. The advisor and worker
    are local stand-ins. The prompt names the goal only.
    """
    # Removed first, so neither the driver nor the app ever inherits it.
    token = os.environ.pop("FAWALY_TEST_CLAUDE_TOKEN", "")
    if not token:
        raise SystemExit("FAWALY_TEST_CLAUDE_TOKEN is not set")
    app = pathlib.Path(app).resolve()
    data = default_data_root()
    assert not data.exists(), "this test must start from a fresh profile"

    project = pathlib.Path.home() / "sudo-interns-real-project"
    shutil.rmtree(project, ignore_errors=True)
    project.mkdir()
    (project / "greeting.txt").write_bytes(b"hello\n")

    advice = text_reply("The plan is sound. Confirm the file contents after the change.")
    done = text_reply("Updated greeting.txt to say hello team.")
    serve(11434, [advice] * 6)
    serve(1234, [
        tool_reply("1", "read_file", {"path": "greeting.txt"}),
        tool_reply("2", "write_file", {"path": "greeting.txt", "content": "hello team\n", "expected_sha256": GREETING_DIGEST}),
        done, done, done, done,
    ])

    driver_process = start_driver()
    driver = WebDriver(app)
    try:
        driver.find("next")
        ui_setup(driver, "claude", "Claude Code")
        driver.screenshot("06-home")
    finally:
        driver.quit()
        driver_process.terminate()

    state_file = data / "workshop.json"
    state = json.loads(state_file.read_text(encoding="utf-8"))
    assert state["team"] == {"primary": "claude", "advisor": "ollama", "workers": ["lmstudio"]}, state["team"]
    assert state["advisors"]["mode"] == "important", state["advisors"]
    state["projectDirectory"] = str(project)  # The folder picker is a native dialog.
    state_file.write_text(json.dumps(state), encoding="utf-8")
    launcher = data / "bin" / ("sudo-interns-engine.exe" if WINDOWS else "sudo-interns-engine")
    subprocess.run([str(launcher), "allow-workspace", str(project)], check=True, timeout=30)

    claude_name = "claude.exe" if WINDOWS else "claude"
    claude = data / "runtimes" / "claude" / claude_name
    tools = [f"mcp__fawaly_team__{name}" for name in ("status", "roster_get", "consult", "consult_decide", "delegate", "review")]
    log("starting the real Claude Code primary")
    done_run = subprocess.run(
        [str(claude), "-p", "Update greeting.txt in this project so it says exactly: hello team", "--output-format", "json", "--max-turns", "30", "--allowedTools", ",".join([*tools, "Read", "Glob", "Grep"])],
        cwd=project,
        env={**os.environ, "CLAUDE_CODE_OAUTH_TOKEN": token, "DISABLE_AUTOUPDATER": "1"},
        capture_output=True,
        text=True,
        encoding="utf-8",
        timeout=900,
    )
    del token
    if done_run.returncode != 0:
        log(f"Claude Code exited with {done_run.returncode}: {done_run.stdout[-1500:]} {done_run.stderr[-1500:]}")
    summary = json.loads(done_run.stdout)
    log(f"turns: {summary.get('num_turns')}; denied tools: {[item.get('tool_name') for item in summary.get('permission_denials', [])]}")
    log(f"final message: {str(summary.get('result'))[:1500]}")

    database = sqlite3.connect(data / "worklog.sqlite")
    consults = [json.loads(row[0]) for row in database.execute("SELECT record FROM consults")]
    jobs = [json.loads(bytes(row[0])) for row in database.execute("SELECT payload FROM team_jobs")]
    database.close()
    for record in consults:
        log(f"consult: {record['question'][:300]!r}; decision: {record.get('decision')}; note: {str(record.get('summary'))[:300]!r}")
    for job in jobs:
        log(f"job: {job['title'][:200]!r}; status: {job['status']}; reviews: {json.dumps(job.get('reviews', []), ensure_ascii=False)[:900]}")

    assert consults, "the primary did not consult its advisor"
    assert jobs, "the primary did not delegate"
    reviewed = [job for job in jobs if job["status"] == "reviewed" and job.get("reviews")]
    assert reviewed, "the primary did not record an accepting review"
    assert all(review["primary"] == "claude" and review["verification"].strip() for job in reviewed for review in job["reviews"])
    assert (project / "greeting.txt").read_bytes().replace(b"\r\n", b"\n") == b"hello team\n"
    log("real primary consulted, delegated, and reviewed the result")


if __name__ == "__main__":
    if len(sys.argv) < 3 or sys.argv[1] not in ("smoke", "onboarding", "real-primary"):
        raise SystemExit(__doc__)
    {"smoke": smoke, "onboarding": onboarding, "real-primary": real_primary}[sys.argv[1]](*sys.argv[2:])
