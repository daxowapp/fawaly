#!/usr/bin/env python3
"""Exercises installed Windows and Linux packages on the system itself.

  smoke APP            launch, relaunch, and check the bundled engine
  onboarding APP       drive the real UI with a fresh profile through tauri-driver,
                       then run a scripted primary over the MCP entry the UI registered

Uses only the standard library. The scripted primary proves the app, engine and
tools work on this OS. It does not prove a real model decides to use them.
"""

import json
import os
import pathlib
import shutil
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


def smoke(app):
    data = pathlib.Path(tempfile.mkdtemp(prefix="sudo-interns-smoke-"))
    env = {**os.environ, "SUDO_INTERNS_DATA_DIR": str(data)}
    engine = engine_beside(app)
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
        try:
            with urllib.request.urlopen(request, timeout=300) as response:
                return json.load(response)["value"]
        except urllib.error.HTTPError as error:
            raise RuntimeError(f"{method} {path}: {error.read().decode(errors='replace')}") from None

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
        element = self.find(testid, timeout)
        while not self.do("GET", f"/element/{element}/enabled"):
            if time.time() > deadline:
                self.screenshot(f"disabled-{testid}")
                raise RuntimeError(f"still disabled: {testid}\n{self.text()}")
            time.sleep(0.5)
            element = self.find(testid, timeout)
        self.do("POST", f"/element/{element}/click", {})

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


def codex_home():
    return pathlib.Path.home() / ".codex"


def onboarding(app):
    app = pathlib.Path(app).resolve()
    data = pathlib.Path(tempfile.mkdtemp(prefix="sudo-interns-e2e-"))
    os.environ["SUDO_INTERNS_DATA_DIR"] = str(data)

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

        driver.click("next")
        driver.find("choice-codex")
        driver.click("choice-codex")
        driver.script("""
            const select = document.querySelector('[data-testid="advisor"]');
            select.value = 'ollama';
            select.dispatchEvent(new Event('change'));
        """)
        driver.click("worker-lmstudio")
        driver.screenshot("03-team")
        driver.click("next")

        log("downloading the official Codex CLI through the app")
        driver.find("next")
        driver.wait_text("Codex")
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
        log("connecting the team to the real Codex CLI")
        driver.click("next", 60)
        driver.find("nav-home", 120)
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


if __name__ == "__main__":
    if len(sys.argv) != 3 or sys.argv[1] not in ("smoke", "onboarding"):
        raise SystemExit(__doc__)
    {"smoke": smoke, "onboarding": onboarding}[sys.argv[1]](sys.argv[2])
