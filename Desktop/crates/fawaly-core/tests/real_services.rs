//! Talks to the real news feeds and the real skill sources. Network dependent,
//! so it is ignored by default and run on purpose in CI. Every location is a
//! temporary folder: the real home, data folder and keyring are never touched.

use chrono::{Duration, Utc};
use fawaly_core::daily::{DailySource, DailyStore, SOURCES};
use fawaly_core::http::{HttpRequest, Transport};
use fawaly_core::secrets::MemorySecrets;
use fawaly_core::skills::{self, ProjectSkills, SkillPackage, SkillStatus};
use fawaly_core::store::load_daily;
use fawaly_core::workspace::digest;
use fawaly_core::Engine;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

/// Small, has more than one file, and is a real upstream skill with an author.
const SKILL_ID: &str = "superpowers-verify";

struct Exchange {
    url: String,
    outcome: Result<(Vec<u8>, u16), String>,
}

type Exchanges = Arc<Mutex<Vec<Exchange>>>;

/// Passes every request to the real network and keeps what came back, because
/// the app's refresh reports only which source failed and not why.
fn recording(inner: Transport) -> (Transport, Exchanges) {
    let exchanges: Exchanges = Arc::default();
    let sink = Arc::clone(&exchanges);
    let transport: Transport = Arc::new(move |request: HttpRequest| {
        let url = request.url.clone();
        let reply = inner(request);
        let outcome = match &reply {
            Ok((data, status)) => Ok((data.clone(), *status)),
            Err(error) => Err(error.to_string()),
        };
        sink.lock().unwrap().push(Exchange { url, outcome });
        reply
    });
    (transport, exchanges)
}

/// The layout the app sees: a data folder and a project inside the user's home.
fn temporary_engine() -> (tempfile::TempDir, Engine, PathBuf) {
    let base = tempfile::tempdir().unwrap();
    let temporary = dunce::canonicalize(base.path()).unwrap();
    let home = temporary.join("home");
    let root = home.join(".local/share/SudoInterns");
    let project = home.join("code/project");
    std::fs::create_dir_all(&root).unwrap();
    std::fs::create_dir_all(&project).unwrap();
    let engine = Engine::with(root, home, Arc::new(MemorySecrets::default()));
    assert!(engine.root.starts_with(&temporary) && engine.home.starts_with(&temporary), "the test must stay inside its temporary folder");
    (base, engine, project)
}

fn describe(source: &DailySource, exchanges: &[Exchange]) -> String {
    match exchanges.iter().find(|exchange| exchange.url == source.feed).map(|exchange| &exchange.outcome) {
        Some(Ok((data, status))) => format!("HTTP {status}, {} bytes", data.len()),
        Some(Err(error)) => format!("no response: {error}"),
        None => "never requested".to_string(),
    }
}

#[test]
#[ignore = "uses the real network"]
fn the_real_developer_daily_feeds_refresh() {
    let (_base, engine, _project) = temporary_engine();
    let (transport, exchanges) = recording(engine.transport.clone());
    let store = DailyStore::new(&engine.root);
    let now = Utc::now();

    let page = load_daily(&store, &transport, true, now);

    let snapshot = &page.snapshot;
    let exchanges = exchanges.lock().unwrap();
    let mut working = Vec::new();
    let mut report = Vec::new();
    for source in &SOURCES {
        let count = snapshot.articles.iter().filter(|article| article.source_id == source.id).count();
        let failed = snapshot.failures.iter().any(|id| id == source.id);
        let line = format!("{}: {} ({}), {count} recent article(s)", source.id, if failed { "FAILED" } else { "ok" }, describe(source, &exchanges));
        println!("{line}");
        // The workflow turns these lines into warnings on the run page.
        if failed {
            println!("source failure: {line}");
        }
        report.push(line);
        if !failed && count > 0 {
            working.push(source.id);
        }
        // Nothing was saved before this run, so a failed source has nothing to keep.
        if failed {
            assert_eq!(count, 0, "{} failed but still has articles", source.id);
            assert!(!snapshot.source_updated_at.contains_key(source.id), "{} failed but was marked updated", source.id);
        } else {
            assert_eq!(snapshot.source_updated_at.get(source.id), Some(&now), "{} succeeded but was not marked updated", source.id);
        }
    }
    println!("failed sources: {:?}", snapshot.failures);

    assert_eq!(exchanges.len(), SOURCES.len(), "each feed must be requested exactly once");
    assert!(SOURCES.iter().all(|source| exchanges.iter().any(|exchange| exchange.url == source.feed)), "{report:#?}");
    assert!(!working.is_empty(), "no source returned articles:\n{report:#?}");
    assert_eq!(snapshot.checked_at, Some(now));
    assert!(!snapshot.due(now), "a refreshed snapshot must not be due again");

    for article in &snapshot.articles {
        let source = article.source().unwrap_or_else(|| panic!("unknown source on {article:?}"));
        let url = url::Url::parse(&article.url).unwrap_or_else(|error| panic!("invalid URL on {article:?}: {error}"));
        assert_eq!(url.scheme(), "https", "{article:?}");
        assert!(url.host_str().is_some_and(|host| source.hosts.contains(&host)), "{article:?}");
        assert!(!article.title.trim().is_empty(), "{article:?}");
        assert!(article.published <= now + Duration::minutes(10) && article.published >= now - Duration::days(14), "{article:?}");
    }

    assert!(!page.issues.save && !page.issues.cache && !page.issues.reading, "{:?}", page.issues);
    let saved = store.load().unwrap();
    assert!(!saved.articles.is_empty(), "the refreshed articles were not saved");
    assert!(saved.articles.iter().all(|article| snapshot.articles.iter().any(|known| known.url == article.url)));
    println!("{} article(s) from {working:?}, saved and reloaded", snapshot.articles.len());
}

/// What the app does across its preview and install commands.
fn download_and_install(target: &ProjectSkills, item: &SkillPackage, catalog: &[SkillPackage], engine: &Engine) {
    let (transport, exchanges) = recording(engine.transport.clone());
    assert_eq!(target.status(item), SkillStatus::Absent, "the destination must start without this skill");

    let contents = item.download(&transport).unwrap_or_else(|error| panic!("download failed: {error}"));

    // The bytes that really arrived must be the ones the manifest pins.
    let exchanges = exchanges.lock().unwrap();
    assert_eq!(exchanges.len(), item.files.len(), "each file must be requested exactly once");
    for file in &item.files {
        let url = format!("https://raw.githubusercontent.com/{}/{}/{}", item.repo, item.revision, file.source);
        let exchange = exchanges.iter().find(|exchange| exchange.url == url).unwrap_or_else(|| panic!("never requested {url}"));
        let (data, status) = exchange.outcome.as_ref().unwrap_or_else(|error| panic!("{url}: {error}"));
        assert_eq!(*status, 200, "{url}");
        assert_eq!(data.len(), file.bytes, "{url}");
        assert_eq!(digest(data), file.sha256, "{url}");
        assert_eq!(contents[&file.path].as_bytes(), &data[..], "{url}");
    }

    let plan = target.plan(item, &contents, catalog).unwrap_or_else(|error| panic!("plan failed: {error}"));
    assert!(!plan.writes.is_empty(), "the plan must write files");
    target.install(&plan).unwrap_or_else(|error| panic!("install failed: {error}"));
    assert_eq!(target.status(item), SkillStatus::Installed);

    let receipt = target.receipt(item).unwrap().expect("a completed install leaves a receipt");
    assert!(receipt.complete);
    assert_eq!((receipt.author.as_str(), receipt.license.as_str(), receipt.source.as_str()), (item.author.as_str(), item.license.as_str(), item.repo.as_str()));
    println!("installed {} into {} with {} write(s)", item.id, target.directory.display(), plan.writes.len());
}

fn assert_skill_files_and_credit(folder: &Path, item: &SkillPackage) {
    for destination in [".agents/skills", ".claude/skills"] {
        let skill = folder.join(destination).join(&item.skill_name);
        for file in &item.files {
            let data = std::fs::read(skill.join(&file.path)).unwrap_or_else(|error| panic!("{}: {error}", file.path));
            assert_eq!(digest(&data), file.sha256, "{destination}/{}", file.path);
        }
        let credit = std::fs::read_to_string(skill.join("Fawaly-CREDITS.md")).unwrap();
        for expected in [item.author.as_str(), item.license.as_str(), item.revision.as_str(), item.source_url().as_str()] {
            assert!(credit.contains(expected), "credit in {destination} is missing {expected}:\n{credit}");
        }
    }
}

fn assert_instructions_kept(folder: &Path, path: &str, before: &str, item: &SkillPackage) {
    let text = std::fs::read_to_string(folder.join(path)).unwrap();
    assert!(text.starts_with(before), "{path} lost its existing instructions:\n{text}");
    assert!(text.contains(&format!("<!-- fawaly:skill:{}:begin -->", item.id)), "{path} has no skill section:\n{text}");
    assert!(text.contains(&item.author), "{path} does not credit the author:\n{text}");
}

#[test]
#[ignore = "uses the real network"]
fn a_real_skill_is_verified_and_installed_in_a_project_and_globally() {
    let (_base, engine, project) = temporary_engine();
    let catalog = skills::catalog().unwrap();
    let item = catalog.iter().find(|item| item.id == SKILL_ID).unwrap_or_else(|| panic!("{SKILL_ID} is not in the bundled catalog"));
    assert_eq!(item.kind, "skill");
    assert!(!item.author.is_empty() && !item.license.is_empty());

    let project_rules = "# My project rules\nKeep this line.\n";
    let agents_rules = "# My agent notes\nAlso keep this.\n";
    let global_rules = "# My global rules\nKeep this too.\n";
    std::fs::write(project.join("CLAUDE.md"), project_rules).unwrap();
    std::fs::write(project.join("AGENTS.md"), agents_rules).unwrap();
    std::fs::create_dir_all(engine.home.join(".claude")).unwrap();
    std::fs::write(engine.home.join(".claude/CLAUDE.md"), global_rules).unwrap();

    let in_project = ProjectSkills::validated_project(&engine, project.to_str().unwrap()).unwrap();
    let everywhere = ProjectSkills::global(&engine.home);

    // Real bytes with one bit changed must be refused, and nothing installed.
    let real = engine.transport.clone();
    let tampered: Transport = Arc::new(move |request: HttpRequest| {
        let (mut data, status) = real(request)?;
        assert_eq!(status, 200, "the tamper check needs the real file");
        assert!(!data.is_empty(), "the tamper check needs the real file");
        data[0] ^= 1;
        Ok((data, status))
    });
    let refused = item.download(&tampered).expect_err("a changed file must be refused").to_string();
    assert!(refused.contains("pinned checksum"), "{refused}");
    assert_eq!(in_project.status(item), SkillStatus::Absent, "a refused download must install nothing");
    println!("a file with one changed bit was refused: {refused}");

    download_and_install(&in_project, item, &catalog, &engine);

    // The plan checks again, so a change after the download is also refused.
    let mut altered = item.download(&engine.transport).unwrap();
    altered.get_mut("SKILL.md").expect("the skill has a SKILL.md").push('\n');
    assert!(everywhere.plan(item, &altered, &catalog).is_err(), "changed contents must fail the plan");

    download_and_install(&everywhere, item, &catalog, &engine);

    assert_eq!(in_project.status(item), SkillStatus::Installed, "the project copy must stay installed");
    assert_skill_files_and_credit(&project, item);
    assert_skill_files_and_credit(&engine.home, item);
    assert_instructions_kept(&project, "CLAUDE.md", project_rules, item);
    assert_instructions_kept(&project, "AGENTS.md", agents_rules, item);
    assert_instructions_kept(&engine.home, ".claude/CLAUDE.md", global_rules, item);
    assert_instructions_kept(&engine.home, ".codex/AGENTS.md", "", item);
    let backup = project.join(format!(".fawaly/skills/backups/{}/CLAUDE.md.before", item.id));
    assert_eq!(std::fs::read_to_string(backup).unwrap(), project_rules, "the original instructions must be backed up");
    let backup = engine.home.join(format!(".fawaly/skills-global/backups/{}/.claude/CLAUDE.md.before", item.id));
    assert_eq!(std::fs::read_to_string(backup).unwrap(), global_rules, "the original global instructions must be backed up");
}
