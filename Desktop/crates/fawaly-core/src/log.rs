use crate::model::*;
use crate::store::ApiAssistant;
use crate::{Error, Result};
use chrono::{Duration, Utc};
use rusqlite::{params, Connection, OptionalExtension, TransactionBehavior};
use std::path::{Path, PathBuf};
use std::time::Duration as StdDuration;
use uuid::Uuid;

fn open(root: &Path) -> Result<Connection> {
    crate::paths::ensure_private_dir(root)?;
    let connection = Connection::open(root.join("worklog.sqlite"))?;
    connection.busy_timeout(StdDuration::from_secs(3))?;
    connection.execute_batch(
        "CREATE TABLE IF NOT EXISTS team_jobs(id TEXT PRIMARY KEY, started REAL NOT NULL, payload BLOB NOT NULL);
         CREATE TABLE IF NOT EXISTS consults(id TEXT PRIMARY KEY, created REAL NOT NULL, status TEXT NOT NULL, record TEXT NOT NULL);
         CREATE TABLE IF NOT EXISTS api_usage(agent TEXT, day TEXT, requests INTEGER NOT NULL DEFAULT 0, input INTEGER NOT NULL DEFAULT 0, output INTEGER NOT NULL DEFAULT 0, reports INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(agent,day));",
    )?;
    Ok(connection)
}

#[derive(Clone)]
pub struct TeamJobLog {
    root: PathBuf,
}

impl TeamJobLog {
    pub fn new(root: &Path) -> Self {
        Self { root: root.to_path_buf() }
    }

    pub fn save(&self, job: &TeamJob) -> Result<()> {
        open(&self.root)?.execute(
            "INSERT INTO team_jobs(id, started, payload) VALUES (?1, ?2, ?3) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload",
            params![job.id.to_string(), job.started.timestamp_millis() as f64 / 1000.0, serde_json::to_vec(job)?],
        )?;
        Ok(())
    }

    pub fn recent(&self, limit: u32) -> Result<Vec<TeamJob>> {
        let connection = open(&self.root)?;
        let mut statement = connection.prepare("SELECT payload FROM team_jobs ORDER BY started DESC LIMIT ?1")?;
        let rows = statement.query_map([limit.max(1)], |row| row.get::<_, Vec<u8>>(0))?;
        rows.map(|row| Ok(serde_json::from_slice(&row?)?)).collect()
    }

    pub fn get(&self, id: Uuid) -> Result<Option<TeamJob>> {
        let connection = open(&self.root)?;
        let payload: Option<Vec<u8>> = connection
            .query_row("SELECT payload FROM team_jobs WHERE id = ?1", [id.to_string()], |row| row.get(0))
            .optional()?;
        payload.map(|data| Ok(serde_json::from_slice(&data)?)).transpose()
    }

    pub fn record_review(&self, id: Uuid, review: TeamReview) -> Result<TeamJob> {
        if review.summary.trim().is_empty()
            || review.summary.len() > 2_048
            || review.verification.trim().is_empty()
            || review.verification.len() > 12_288
            || review.score.is_some_and(|score| !(1..=5).contains(&score))
        {
            return Err(Error::invalid("Record a review summary, verification evidence, and an optional score from 1 to 5."));
        }
        let mut connection = open(&self.root)?;
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let payload: Option<Vec<u8>> = transaction
            .query_row("SELECT payload FROM team_jobs WHERE id = ?1", [id.to_string()], |row| row.get(0))
            .optional()?;
        let payload = payload.ok_or_else(|| Error::invalid("This worker result is no longer available."))?;
        let mut job: TeamJob = serde_json::from_slice(&payload)?;
        if job.primary != Some(review.primary) || job.finished.is_none() || job.status == "running" {
            return Err(Error::invalid("Only the job's primary can review a finished worker result."));
        }
        let same = job.reviews.last().is_some_and(|last| {
            last.decision == review.decision && last.summary == review.summary && last.verification == review.verification && last.score == review.score
        });
        job.status = match review.decision {
            ReviewDecision::Accepted => "reviewed",
            ReviewDecision::ChangesRequested => "changes_requested",
            ReviewDecision::Rejected => "rejected",
        }
        .to_string();
        job.review_required = review.decision == ReviewDecision::ChangesRequested;
        if !same {
            job.reviews.push(review);
        }
        transaction.execute("UPDATE team_jobs SET payload = ?1 WHERE id = ?2", params![serde_json::to_vec(&job)?, id.to_string()])?;
        transaction.commit()?;
        Ok(job)
    }
}

#[derive(Clone)]
pub struct ConsultLog {
    root: PathBuf,
}

impl ConsultLog {
    pub fn new(root: &Path) -> Self {
        Self { root: root.to_path_buf() }
    }

    fn status_name(status: ConsultStatus) -> &'static str {
        match status {
            ConsultStatus::Open => "open",
            ConsultStatus::Closed => "closed",
            ConsultStatus::NoDecision => "no_decision",
        }
    }

    pub fn insert(&self, record: &ConsultRecord) -> Result<()> {
        open(&self.root)?.execute(
            "INSERT INTO consults(id, created, status, record) VALUES(?1, ?2, ?3, ?4)",
            params![record.id.to_string(), record.created.timestamp_millis() as f64 / 1000.0, Self::status_name(record.status), serde_json::to_string(record)?],
        )?;
        Ok(())
    }

    /// Compare-and-swap, so two engines cannot both extend the same round.
    pub fn update(&self, record: &ConsultRecord, previous: &ConsultRecord) -> Result<()> {
        let changed = open(&self.root)?.execute(
            "UPDATE consults SET status = ?1, record = ?2 WHERE id = ?3 AND record = ?4",
            params![Self::status_name(record.status), serde_json::to_string(record)?, record.id.to_string(), serde_json::to_string(previous)?],
        )?;
        if changed == 1 {
            Ok(())
        } else {
            Err(Error::invalid("Consultation not saved."))
        }
    }

    pub fn get(&self, id: Uuid) -> Result<Option<ConsultRecord>> {
        let connection = open(&self.root)?;
        let record: Option<String> = connection
            .query_row("SELECT record FROM consults WHERE id = ?1", [id.to_string()], |row| row.get(0))
            .optional()?;
        record.map(|text| Ok(serde_json::from_str(&text)?)).transpose()
    }

    pub fn recent(&self, limit: u32) -> Result<Vec<ConsultRecord>> {
        let connection = open(&self.root)?;
        let mut statement = connection.prepare("SELECT record FROM consults ORDER BY created DESC, id DESC LIMIT ?1")?;
        let rows = statement.query_map([limit.clamp(1, 1000)], |row| row.get::<_, String>(0))?;
        rows.map(|row| Ok(serde_json::from_str(&row?)?)).collect()
    }

    /// Open consultations older than 24 hours become "no decision recorded".
    pub fn expire_open(&self) -> Result<()> {
        let connection = open(&self.root)?;
        let records: Vec<String> = {
            let mut statement = connection.prepare("SELECT record FROM consults WHERE status = 'open'")?;
            let rows = statement.query_map([], |row| row.get::<_, String>(0))?;
            rows.collect::<std::result::Result<_, _>>()?
        };
        let now = Utc::now();
        for text in records {
            let mut record: ConsultRecord = serde_json::from_str(&text)?;
            if now - record.created > Duration::hours(24) {
                record.status = ConsultStatus::NoDecision;
                record.updated = now;
                connection.execute(
                    "UPDATE consults SET status = 'no_decision', record = ?1 WHERE id = ?2",
                    params![serde_json::to_string(&record)?, record.id.to_string()],
                )?;
            }
        }
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, serde::Serialize)]
pub struct UsageTotals {
    pub requests: i64,
    pub input: i64,
    pub output: i64,
    pub reports: i64,
}

#[derive(Clone)]
pub struct ApiUsage {
    root: PathBuf,
}

impl ApiUsage {
    pub fn new(root: &Path) -> Self {
        Self { root: root.to_path_buf() }
    }

    fn day() -> String {
        Utc::now().format("%Y-%m-%d").to_string()
    }

    pub fn totals(&self, agent: Agent) -> Result<UsageTotals> {
        Self::totals_on(&open(&self.root)?, agent)
    }

    fn totals_on(connection: &Connection, agent: Agent) -> Result<UsageTotals> {
        Ok(connection
            .query_row(
                "SELECT requests,input,output,reports FROM api_usage WHERE agent=?1 AND day=?2",
                params![agent.raw(), Self::day()],
                |row| Ok(UsageTotals { requests: row.get(0)?, input: row.get(1)?, output: row.get(2)?, reports: row.get(3)? }),
            )
            .optional()?
            .unwrap_or_default())
    }

    /// Reserves a request before it is sent, so concurrent engines share one cap.
    pub fn reserve(&self, assistant: &ApiAssistant) -> Result<()> {
        let mut connection = open(&self.root)?;
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        if Self::totals_on(&transaction, assistant.agent)?.requests >= i64::from(assistant.daily_request_limit) {
            return Err(Error::invalid("This assistant reached your local daily API-request cap. Change the cap in Sudo Interns or wait until the next UTC day. No fallback was sent."));
        }
        transaction.execute(
            "INSERT INTO api_usage(agent,day,requests) VALUES (?1,?2,1) ON CONFLICT(agent,day) DO UPDATE SET requests=requests+1",
            params![assistant.agent.raw(), Self::day()],
        )?;
        transaction.commit()?;
        Ok(())
    }

    pub fn record(&self, agent: Agent, input: i64, output: i64) -> Result<()> {
        if !(0..=1_000_000_000).contains(&input) || !(0..=1_000_000_000).contains(&output) {
            return Ok(());
        }
        open(&self.root)?.execute(
            "UPDATE api_usage SET input=input+?1, output=output+?2, reports=reports+1 WHERE agent=?3 AND day=?4",
            params![input, output, agent.raw(), Self::day()],
        )?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::ApiAssistant;

    fn job() -> TeamJob {
        TeamJob {
            id: Uuid::new_v4(),
            primary: Some(Agent::Codex),
            worker: Agent::Kimi,
            title: "t".into(),
            status: "needs_handoff".into(),
            started: Utc::now(),
            finished: Some(Utc::now()),
            result: Some("done".into()),
            review_required: true,
            reviews: vec![],
            confinement: None,
            git_changes: vec![],
        }
    }

    fn review(primary: Agent, decision: ReviewDecision) -> TeamReview {
        TeamReview { decision, primary, summary: "s".into(), verification: "v".into(), score: Some(4), created: Utc::now() }
    }

    #[test]
    fn review_requires_the_jobs_primary_and_updates_status() {
        let root = tempfile::tempdir().unwrap();
        let log = TeamJobLog::new(root.path());
        let job = job();
        log.save(&job).unwrap();
        assert!(log.record_review(job.id, review(Agent::Claude, ReviewDecision::Accepted)).is_err());
        let updated = log.record_review(job.id, review(Agent::Codex, ReviewDecision::Accepted)).unwrap();
        assert_eq!(updated.status, "reviewed");
        assert!(!updated.review_required);
        assert_eq!(updated.reviews.len(), 1);
    }

    #[test]
    fn running_jobs_cannot_be_reviewed() {
        let root = tempfile::tempdir().unwrap();
        let log = TeamJobLog::new(root.path());
        let mut running = job();
        running.status = "running".into();
        running.finished = None;
        log.save(&running).unwrap();
        assert!(log.record_review(running.id, review(Agent::Codex, ReviewDecision::Accepted)).is_err());
    }

    #[test]
    fn usage_cap_is_enforced_before_sending() {
        let root = tempfile::tempdir().unwrap();
        let usage = ApiUsage::new(root.path());
        let mut assistant = ApiAssistant::preset(Agent::Deepseek);
        assistant.daily_request_limit = 1;
        usage.reserve(&assistant).unwrap();
        assert!(usage.reserve(&assistant).is_err());
        assert_eq!(usage.totals(Agent::Deepseek).unwrap().requests, 1);
    }
}
