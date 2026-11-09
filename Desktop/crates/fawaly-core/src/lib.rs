//! Cross-platform core of Sudo Interns (الفواعلي) for Windows and Linux.
//! The macOS app remains native SwiftUI; this crate reimplements its contracts.

pub mod api_worker;
pub mod bridge;
pub mod client_link;
pub mod confine;
pub mod daily;
pub mod engine;
pub mod error;
pub mod http;
pub mod installer;
pub mod log;
pub mod mcp;
pub mod model;
pub mod native;
pub mod openrouter;
pub mod paths;
pub mod process;
pub mod secrets;
pub mod signin;
pub mod skills;
pub mod store;
pub mod support;
pub mod workspace;

pub use engine::Engine;
pub use error::{Error, Result};

pub const VERSION: &str = env!("CARGO_PKG_VERSION");
