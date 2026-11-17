use std::fmt;

/// Messages are user-facing and must never include secrets.
#[derive(Debug)]
pub enum Error {
    Invalid(String),
    /// The user stopped this job from the app or the primary called `stop`.
    Stopped,
    Cancelled,
    WorkerAuthentication,
}

pub type Result<T> = std::result::Result<T, Error>;

impl Error {
    pub fn invalid(message: impl Into<String>) -> Self {
        Self::Invalid(message.into())
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Invalid(message) => f.write_str(message),
            Self::Stopped => f.write_str("Stopped by the user. Review any partial changes before continuing."),
            Self::Cancelled => f.write_str("Request stopped. Review any partial workspace changes."),
            Self::WorkerAuthentication => f.write_str("The worker rejected its isolated sign-in. Reconnect it in Services."),
        }
    }
}

impl std::error::Error for Error {}

impl From<std::io::Error> for Error {
    fn from(error: std::io::Error) -> Self {
        Self::Invalid(format!("A local file operation failed: {error}"))
    }
}

impl From<rusqlite::Error> for Error {
    fn from(_: rusqlite::Error) -> Self {
        Self::invalid("The local work log could not be read or saved.")
    }
}

impl From<serde_json::Error> for Error {
    fn from(_: serde_json::Error) -> Self {
        Self::invalid("Saved data has an unexpected format.")
    }
}
