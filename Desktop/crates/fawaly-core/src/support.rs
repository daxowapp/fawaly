use crate::confine;
use crate::engine::Engine;
use serde::Serialize;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Level {
    Supported,
    Limited,
    Unavailable,
}

#[derive(Clone, Debug, Serialize)]
pub struct Capability {
    pub id: &'static str,
    pub level: Level,
    pub en: String,
    pub ar: String,
}

fn item(id: &'static str, level: Level, en: &str, ar: &str) -> Capability {
    Capability { id, level, en: en.to_string(), ar: ar.to_string() }
}

/// Never written. Real accounts always contain a colon.
const SECRET_STORE_PROBE: &str = "capability-probe-never-stored";

/// States what this computer provides. The page reads this instead of assuming.
pub fn capabilities(engine: &Engine) -> Vec<Capability> {
    let windows = cfg!(windows);
    let landlock = confine::landlock_available(engine.helper.as_deref());
    let mut list = vec![item(
        "api_workers",
        Level::Supported,
        "API and local assistants can only reach the approved project through the app's file tools. They have no shell.",
        "المساعدين عبر API والموديلات المحلية بيوصلوا للمشروع المسموح من أدوات ملفات التطبيق بس، ومعاهمش Shell.",
    )];
    if windows {
        list.push(item(
            "native_workers",
            Level::Limited,
            "Windows does not let this app enforce a folder boundary on Codex or Claude Code. They are limited by their own settings: Codex uses its sandbox, and Claude Code gets file tools with no shell.",
            "ويندوز مش بيسمح للتطبيق يفرض حدود فولدر على Codex أو Claude Code. الحدود من إعدادات الأداة نفسها: Codex بصندوقه المعزول، وClaude Code بأدوات ملفات من غير Shell.",
        ));
        list.push(item(
            "kimi_project",
            Level::Unavailable,
            "Kimi cannot edit projects on Windows by default, because it has no boundary the app can verify. On text tasks nothing in the OS limits its Read tool, so it could read any file your account can open. You can opt in to project edits from Settings.",
            "Kimi مش بيعدّل مشاريع على ويندوز افتراضيًا، لأن مفيش حدود التطبيق يقدر يتأكد منها. في المهام النصية مفيش حدود من النظام على أداة القراية بتاعته، فممكن يقرا أي ملف حسابك يقدر يفتحه. وتقدر تسمح له بتعديل المشاريع من الإعدادات على مسؤوليتك.",
        ));
    } else if cfg!(target_os = "linux") {
        if landlock {
            list.push(item(
                "native_workers",
                Level::Supported,
                "The Linux kernel (Landlock) keeps native workers inside the approved project. The project's .git folder is inside that boundary: it is monitored and any change is flagged for review, but not blocked.",
                "كيرنل لينكس (Landlock) بيحصر العمال جوّه المشروع المسموح. فولدر .git جوّه نفس الحدود: بنراقبه ونبلّغ عن أي تغيير للمراجعة، بس مش بنمنعه.",
            ));
        } else {
            list.push(item(
                "native_workers",
                Level::Unavailable,
                "This kernel does not provide Landlock, so Codex, Claude Code and Kimi cannot edit projects unless you allow it in Settings. On text tasks nothing in the OS limits Kimi's Read tool. API and local assistants still work.",
                "الكيرنل ده مفيهوش Landlock، فـCodex وClaude Code وKimi مش هيعدّلوا مشاريع إلا لو سمحت من الإعدادات. وفي المهام النصية مفيش حدود من النظام على أداة القراية بتاعة Kimi. مساعدين API والموديلات المحلية شغّالين عادي.",
            ));
        }
    }
    // Reading an account that does not exist reaches the store without ever
    // prompting to unlock it.
    list.push(if engine.secrets.get(SECRET_STORE_PROBE).is_ok() {
        item(
            "secrets",
            Level::Supported,
            if windows { "API keys are kept in Windows Credential Manager, never in a file." } else { "API keys are kept in your Secret Service keyring (GNOME Keyring or KWallet). If it is missing or locked, keys are not saved." },
            if windows { "مفاتيح API محفوظة في Windows Credential Manager، ومش في ملف." } else { "مفاتيح API محفوظة في Secret Service (زي GNOME Keyring أو KWallet). لو مش موجود أو مقفول، المفتاح مش هيتحفظ." },
        )
    } else {
        item(
            "secrets",
            Level::Unavailable,
            if windows { "Windows Credential Manager could not be reached, so API keys cannot be saved. Local assistants still work." } else { "No Secret Service keyring (GNOME Keyring or KWallet) could be reached, so API keys cannot be saved. Local assistants still work." },
            if windows { "مقدرناش نوصل لـWindows Credential Manager، فمفاتيح API مش هتتحفظ. الموديلات المحلية شغّالة عادي." } else { "مقدرناش نوصل لـSecret Service (زي GNOME Keyring أو KWallet)، فمفاتيح API مش هتتحفظ. الموديلات المحلية شغّالة عادي." },
        )
    });
    list.push(item(
        "native_signin",
        Level::Limited,
        "Codex, Claude Code and Kimi keep their own sign-in files in a private app folder. Those are managed by each official tool, not the system keyring.",
        "Codex وClaude Code وKimi بيحفظوا تسجيل الدخول في ملفاتهم الخاصة جوّه فولدر خاص بالتطبيق. دي بتديرها كل أداة رسمية، مش مخزن أسرار النظام.",
    ));
    list.push(item(
        "updates",
        Level::Unavailable,
        "Automatic updates are not available yet. Download new versions from the releases page.",
        "التحديث التلقائي لسه مش متاح. نزّل النسخ الجديدة من صفحة الإصدارات.",
    ));
    list.push(item(
        "compare",
        Level::Unavailable,
        "Side-by-side assistant comparison, menu bar monitoring and preference sync are Mac-only for now.",
        "مقارنة المساعدين ومتابعة شريط القوائم ومزامنة الإعدادات متاحين على الماك بس حاليًا.",
    ));
    list
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::secrets::{MemorySecrets, SecretStore};
    use std::sync::Arc;

    #[test]
    fn every_capability_has_both_languages() {
        let root = tempfile::tempdir().unwrap();
        let engine = Engine::with(root.path().join("d"), root.path().join("h"), Arc::new(MemorySecrets::default()));
        let list = capabilities(&engine);
        assert!(list.iter().all(|entry| !entry.en.is_empty() && !entry.ar.is_empty()));
        assert!(list.iter().any(|entry| entry.id == "updates" && entry.level == Level::Unavailable));
        assert!(list.iter().any(|entry| entry.id == "secrets" && entry.level == Level::Supported));
    }

    struct NoKeyring;

    impl SecretStore for NoKeyring {
        fn get(&self, _: &str) -> crate::Result<Option<String>> {
            Err(crate::Error::invalid("unavailable"))
        }

        fn set(&self, _: &str, _: &str) -> crate::Result<()> {
            Err(crate::Error::invalid("unavailable"))
        }

        fn delete(&self, _: &str) -> crate::Result<()> {
            Err(crate::Error::invalid("unavailable"))
        }
    }

    #[test]
    fn a_missing_secret_store_is_reported_in_both_languages() {
        let root = tempfile::tempdir().unwrap();
        let engine = Engine::with(root.path().join("d"), root.path().join("h"), Arc::new(NoKeyring));
        let list = capabilities(&engine);
        let secrets = list.iter().find(|entry| entry.id == "secrets").unwrap();
        assert_eq!(secrets.level, Level::Unavailable);
        assert!(!secrets.en.is_empty() && !secrets.ar.is_empty());
    }
}
