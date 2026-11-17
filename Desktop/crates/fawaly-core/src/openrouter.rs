use crate::http::{HttpRequest, Transport};
use crate::{Error, Result};
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine as _;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

/// Only the challenge and a loopback callback leave this process. No code or
/// key is written to a URL log or configuration file.
pub struct Pkce {
    pub verifier: String,
    pub state: String,
    pub path: String,
}

fn random() -> Result<String> {
    let mut bytes = [0_u8; 32];
    getrandom::fill(&mut bytes).map_err(|_| Error::invalid("Secure sign-in could not be prepared."))?;
    Ok(URL_SAFE_NO_PAD.encode(bytes))
}

impl Pkce {
    pub fn new() -> Result<Self> {
        Ok(Self { verifier: random()?, state: random()?, path: format!("/callback/{}", random()?) })
    }

    pub fn challenge(&self) -> String {
        URL_SAFE_NO_PAD.encode(Sha256::digest(self.verifier.as_bytes()))
    }

    pub fn authorization_url(&self, callback: &str, arabic: bool) -> String {
        let os = if cfg!(windows) { "Windows" } else { "Linux" };
        let name = if arabic { "الفواعلي (Fawaly)" } else { "Sudo Interns (Fawaly)" };
        let label = format!("{name} on {os}");
        let mut url = url::Url::parse("https://openrouter.ai/auth").expect("static URL");
        url.query_pairs_mut()
            .append_pair("callback_url", callback)
            .append_pair("code_challenge", &self.challenge())
            .append_pair("code_challenge_method", "S256")
            .append_pair("state", &self.state)
            .append_pair("key_label", &label);
        url.to_string()
    }

    pub fn code_from(&self, target: &str) -> Result<String> {
        let invalid = || Error::invalid("Invalid sign-in callback. No account was connected.");
        if target.len() > 8192 || !target.starts_with(&format!("{}?", self.path)) {
            return Err(invalid());
        }
        let url = url::Url::parse(&format!("http://localhost{target}")).map_err(|_| invalid())?;
        let pairs: Vec<(String, String)> = url.query_pairs().map(|(key, value)| (key.to_string(), value.to_string())).collect();
        let values = |name: &str| pairs.iter().filter(|(key, _)| key == name).map(|(_, value)| value.clone()).collect::<Vec<_>>();
        let (states, codes) = (values("state"), values("code"));
        if url.path() != self.path || states != [self.state.clone()] || codes.len() != 1 {
            return Err(invalid());
        }
        let code = codes.into_iter().next().ok_or_else(invalid)?;
        if code.is_empty() || code.len() > 4096 || code.chars().any(|c| c.is_whitespace() || c.is_control()) {
            return Err(invalid());
        }
        Ok(code)
    }

    pub fn exchange_request(&self, code: &str) -> Result<HttpRequest> {
        let body = json!({"code":code,"code_verifier":self.verifier,"code_challenge_method":"S256"});
        Ok(HttpRequest::post_json("https://openrouter.ai/api/v1/auth/keys", serde_json::to_vec(&body)?, Duration::from_secs(20)))
    }
}

fn request_target(stream: &mut TcpStream) -> Option<String> {
    stream.set_read_timeout(Some(Duration::from_secs(5))).ok()?;
    let mut data = Vec::new();
    let mut buffer = [0_u8; 1024];
    while !data.windows(4).any(|window| window == b"\r\n\r\n") {
        let count = stream.read(&mut buffer).ok()?;
        if count == 0 || data.len() + count >= 8192 {
            return None;
        }
        data.extend_from_slice(&buffer[..count]);
    }
    let text = String::from_utf8_lossy(&data).to_string();
    let parts: Vec<&str> = text.split("\r\n").next()?.split(' ').collect();
    (parts.len() == 3 && parts[0] == "GET" && parts[2] == "HTTP/1.1").then(|| parts[1].to_string())
}

fn respond(stream: &mut TcpStream, success: bool, arabic: bool) {
    let body = match (arabic, success) {
        (true, true) => "وصل تفويض OpenRouter. ارجع للفواعلي واختار الموديل واحفظ الاتصال.",
        (true, false) => "رابط الرجوع غير صالح. ارجع للفواعلي وجرّب تاني.",
        (false, true) => "OpenRouter authorization received. Return to Sudo Interns (Fawaly) to choose your model and save the connection.",
        (false, false) => "Invalid callback. Return to Sudo Interns (Fawaly) to try again.",
    };
    let status = if success { "200 OK" } else { "400 Bad Request" };
    let response = format!(
        "HTTP/1.1 {status}\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'none'\r\n\r\n{body}",
        body.len()
    );
    let _ = stream.write_all(response.as_bytes());
}

pub fn parse_key(data: &[u8], status: u16) -> Result<String> {
    let failure = || Error::invalid("OpenRouter authorization could not be completed. Try again or use an API key.");
    if status != 200 || data.len() > 65_536 {
        return Err(failure());
    }
    let object: Value = serde_json::from_slice(data).map_err(|_| failure())?;
    let key = object.get("key").and_then(Value::as_str).ok_or_else(failure)?;
    crate::secrets::validate_key(key).map_err(|_| failure())?;
    Ok(key.to_string())
}

/// Opens the browser, waits for the loopback callback, and exchanges the code.
/// Saving the key and any paid test are separate, explicit user actions.
pub fn sign_in(arabic: bool, timeout: Duration, open: &dyn Fn(&str) -> bool, cancel: &AtomicBool, transport: &Transport) -> Result<String> {
    let pkce = Pkce::new()?;
    let listener = TcpListener::bind(("127.0.0.1", 0)).map_err(|_| Error::invalid("The local sign-in callback could not start."))?;
    listener.set_nonblocking(true).map_err(|_| Error::invalid("The local sign-in callback could not start."))?;
    let port = listener.local_addr().map_err(|_| Error::invalid("The local sign-in callback could not start."))?.port();
    let callback = format!("http://localhost:{port}{}", pkce.path);
    if !open(&pkce.authorization_url(&callback, arabic)) {
        return Err(Error::invalid("Open your browser to connect OpenRouter."));
    }
    let deadline = Instant::now() + timeout.clamp(Duration::from_secs(1), Duration::from_secs(600));
    let code = loop {
        if cancel.load(Ordering::Relaxed) {
            return Err(Error::Cancelled);
        }
        if Instant::now() >= deadline {
            return Err(Error::invalid("OpenRouter sign-in timed out. Try again."));
        }
        match listener.accept() {
            Ok((mut stream, _)) => {
                let _ = stream.set_nonblocking(false);
                let code = request_target(&mut stream).and_then(|target| pkce.code_from(&target).ok());
                respond(&mut stream, code.is_some(), arabic);
                if let Some(code) = code {
                    break code;
                }
            }
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => std::thread::sleep(Duration::from_millis(50)),
            Err(_) => return Err(Error::invalid("The local sign-in callback could not start.")),
        }
    };
    let (data, status) = transport(pkce.exchange_request(&code)?)?;
    parse_key(&data, status)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Mutex};

    #[test]
    fn challenge_follows_s256() {
        let mut pkce = Pkce::new().unwrap();
        pkce.verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk".into();
        assert_eq!(pkce.challenge(), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM");
    }

    #[test]
    fn callback_requires_exact_state_and_path() {
        let pkce = Pkce::new().unwrap();
        let good = format!("{}?state={}&code=abc", pkce.path, pkce.state);
        assert_eq!(pkce.code_from(&good).unwrap(), "abc");
        for bad in [
            format!("{}?state=wrong&code=abc", pkce.path),
            format!("/other?state={}&code=abc", pkce.state),
            format!("{}?state={}", pkce.path, pkce.state),
            format!("{0}?state={1}&state={1}&code=abc", pkce.path, pkce.state),
            format!("{}?state={}&code=a%20b", pkce.path, pkce.state),
        ] {
            assert!(pkce.code_from(&bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn full_loopback_flow_returns_the_key() {
        let seen = Arc::new(Mutex::new(None));
        let observed = seen.clone();
        let transport: Transport = Arc::new(move |request: HttpRequest| {
            *observed.lock().unwrap() = Some(serde_json::from_slice::<Value>(request.body.as_ref().unwrap()).unwrap());
            Ok((br#"{"key":"sk-or-test"}"#.to_vec(), 200))
        });
        let never = AtomicBool::new(false);
        let open = |url: &str| {
            let parsed = url::Url::parse(url).unwrap();
            let pairs: std::collections::HashMap<_, _> = parsed.query_pairs().into_owned().collect();
            let callback = url::Url::parse(&pairs["callback_url"]).unwrap();
            let request = format!("GET {}?state={}&code=the-code HTTP/1.1\r\nHost: localhost\r\n\r\n", callback.path(), pairs["state"]);
            let port = callback.port().unwrap();
            std::thread::spawn(move || {
                let mut stream = TcpStream::connect(("127.0.0.1", port)).unwrap();
                stream.write_all(request.as_bytes()).unwrap();
                let mut reply = String::new();
                let _ = stream.read_to_string(&mut reply);
                assert!(reply.starts_with("HTTP/1.1 200"));
            });
            true
        };
        assert_eq!(sign_in(false, Duration::from_secs(10), &open, &never, &transport).unwrap(), "sk-or-test");
        assert_eq!(seen.lock().unwrap().as_ref().unwrap()["code"], "the-code");
    }

    #[test]
    fn cancellation_stops_waiting() {
        let cancel = AtomicBool::new(true);
        let transport: Transport = Arc::new(|_| panic!("no exchange after cancel"));
        assert!(matches!(sign_in(false, Duration::from_secs(5), &|_| true, &cancel, &transport), Err(Error::Cancelled)));
    }

    #[test]
    fn malformed_key_responses_are_refused() {
        assert!(parse_key(br#"{"key":"has space"}"#, 200).is_err());
        assert!(parse_key(br#"{"key":"ok"}"#, 500).is_err());
    }
}
