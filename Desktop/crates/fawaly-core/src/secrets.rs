use crate::{Error, Result};
use std::collections::HashMap;
use std::sync::Mutex;

const SERVICE: &str = "com.daxow.fawaly.desktop";

/// Keys live only in the operating system's secret store; there is no file fallback.
pub trait SecretStore: Send + Sync {
    fn get(&self, account: &str) -> Result<Option<String>>;
    fn set(&self, account: &str, value: &str) -> Result<()>;
    fn delete(&self, account: &str) -> Result<()>;
}

pub struct SystemSecrets;

fn unavailable() -> Error {
    if cfg!(target_os = "linux") {
        Error::invalid("The system keyring is unavailable or locked. Unlock GNOME Keyring, KWallet, or another Secret Service provider and retry. Your key was not saved to a file.")
    } else {
        Error::invalid("Windows Credential Manager is unavailable. Your key was not saved to a file.")
    }
}

impl SecretStore for SystemSecrets {
    fn get(&self, account: &str) -> Result<Option<String>> {
        let entry = keyring::Entry::new(SERVICE, account).map_err(|_| unavailable())?;
        match entry.get_password() {
            Ok(value) => Ok(Some(value)),
            Err(keyring::Error::NoEntry) => Ok(None),
            Err(_) => Err(unavailable()),
        }
    }

    fn set(&self, account: &str, value: &str) -> Result<()> {
        let entry = keyring::Entry::new(SERVICE, account).map_err(|_| unavailable())?;
        entry.set_password(value).map_err(|_| unavailable())
    }

    fn delete(&self, account: &str) -> Result<()> {
        let entry = keyring::Entry::new(SERVICE, account).map_err(|_| unavailable())?;
        match entry.delete_credential() {
            Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
            Err(_) => Err(unavailable()),
        }
    }
}

#[derive(Default)]
pub struct MemorySecrets {
    values: Mutex<HashMap<String, String>>,
}

impl SecretStore for MemorySecrets {
    fn get(&self, account: &str) -> Result<Option<String>> {
        Ok(self.values.lock().unwrap().get(account).cloned())
    }

    fn set(&self, account: &str, value: &str) -> Result<()> {
        self.values.lock().unwrap().insert(account.to_string(), value.to_string());
        Ok(())
    }

    fn delete(&self, account: &str) -> Result<()> {
        self.values.lock().unwrap().remove(account);
        Ok(())
    }
}

pub fn validate_key(key: &str) -> Result<()> {
    if key.is_empty() || key.len() > 16_384 || key.chars().any(|c| c.is_whitespace() || c.is_control()) {
        return Err(Error::invalid("Enter a valid service key."));
    }
    if cfg!(windows) && key.len() > 2_400 {
        return Err(Error::invalid("This key is longer than Windows Credential Manager can store."));
    }
    Ok(())
}
