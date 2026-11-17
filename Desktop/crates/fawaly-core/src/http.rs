use crate::{Error, Result};
use std::sync::Arc;
use std::time::Duration;

pub const RESPONSE_LIMIT: u64 = 2 * 1024 * 1024;

#[derive(Clone, Debug)]
pub struct HttpRequest {
    pub method: &'static str,
    pub url: String,
    pub headers: Vec<(String, String)>,
    pub body: Option<Vec<u8>>,
    pub timeout: Duration,
}

impl HttpRequest {
    pub fn get(url: impl Into<String>, timeout: Duration) -> Self {
        Self { method: "GET", url: url.into(), headers: Vec::new(), body: None, timeout }
    }

    pub fn post_json(url: impl Into<String>, body: Vec<u8>, timeout: Duration) -> Self {
        Self {
            method: "POST",
            url: url.into(),
            headers: vec![("Content-Type".into(), "application/json".into())],
            body: Some(body),
            timeout,
        }
    }

    pub fn header(mut self, name: &str, value: impl Into<String>) -> Self {
        self.headers.push((name.to_string(), value.into()));
        self
    }
}

pub type Transport = Arc<dyn Fn(HttpRequest) -> Result<(Vec<u8>, u16)> + Send + Sync>;

pub fn live() -> Transport {
    Arc::new(send)
}

/// No redirects are followed: credentials must never move to another host.
pub fn send(request: HttpRequest) -> Result<(Vec<u8>, u16)> {
    let agent: ureq::Agent = ureq::Agent::config_builder()
        .max_redirects(0)
        .max_redirects_will_error(false)
        .http_status_as_error(false)
        .timeout_global(Some(request.timeout))
        .build()
        .into();
    let failure = |_| Error::invalid("The service could not be reached. No automatic retry or paid fallback was sent.");
    let mut response = match (request.method, request.body) {
        ("POST", Some(body)) => {
            let mut builder = agent.post(&request.url);
            for (name, value) in &request.headers {
                builder = builder.header(name, value);
            }
            builder.send(&body[..]).map_err(failure)?
        }
        _ => {
            let mut builder = agent.get(&request.url);
            for (name, value) in &request.headers {
                builder = builder.header(name, value);
            }
            builder.call().map_err(failure)?
        }
    };
    let status = response.status().as_u16();
    let data = response
        .body_mut()
        .with_config()
        .limit(RESPONSE_LIMIT)
        .read_to_vec()
        .map_err(|_| Error::invalid("The service response exceeded 2 MB or was interrupted."))?;
    Ok((data, status))
}
