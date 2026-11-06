//! The devices sharing this relay. At most one client is the **executor**: the only one that
//! runs workflows, gets App tokens and pushes subscriptions. Every other client is an observer:
//! it still reads events (to show them), mirrors the executor's workflow configuration and shows
//! the executor's recent runs. With no executor assigned every client runs (the behaviour before
//! devices existed), so assigning one is what stops duplicate runs.
//!
//! Assignment is manual and compare-and-set on `revision`. Handing over from one executor to
//! another records where the new one starts reading events: what the old one confirmed it had
//! handled (`acked`, the `after` of an events poll that says `ack=<revision>`), so nothing is
//! skipped; only a batch handed out while the assignment changes can run on both. A new executor
//! starts with `acked` at its handover (or, coming from no executor, at its own cursor), so a
//! second reassignment before it polls still hands over the right place.
//!
//! An unreadable `fleet.json` is not "no executor" (every device would run): until an executor is
//! assigned again, nobody may act as one and the record says why (`error`).
//!
//! Files in the data directory: `fleet.json` (this state), `fleet-config.toml` (the executor's
//! configuration, Roost's export format), `fleet-runs.json` (its run summaries, opaque here).

use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::value::RawValue;
use sha2::{Digest, Sha256};
use tokio::sync::watch;

/// Upper bound on the configuration text (Roost's export format caps itself at 1 MiB too).
pub const MAX_CONFIG: usize = 1024 * 1024;
/// Upper bound on the serialized run summaries.
pub const MAX_RUNS: usize = 512 * 1024;
const MAX_STATE: u64 = 64 * 1024;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Acked {
    pub store_id: String,
    pub seq: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Executor {
    pub id: String,
    #[serde(default)]
    pub name: Option<String>,
    pub since: DateTime<Utc>,
    /// The cursor this executor starts after when it took over from another one.
    #[serde(default)]
    pub handover: Option<u64>,
    /// Its progress: the last event an events answer handed it.
    #[serde(default)]
    pub acked: Option<Acked>,
}

/// What the executor last uploaded (the content itself is kept beside the state).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Blob {
    pub revision: String,
    pub client: String,
    pub at: DateTime<Utc>,
    pub bytes: usize,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct State {
    /// Bumped whenever the executor changes.
    #[serde(default)]
    pub revision: u64,
    #[serde(default)]
    pub executor: Option<Executor>,
    #[serde(default)]
    pub config: Option<Blob>,
    #[serde(default)]
    pub runs: Option<Blob>,
    /// Why the saved record couldn't be read; set only in memory, cleared by the next assignment.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

#[derive(Debug)]
pub enum FleetError {
    /// The request needs the executor and came from another client (or none is assigned).
    NotExecutor,
    /// `base_revision` is not the current one.
    Conflict(Box<State>),
    TooLarge(usize),
    Io(String),
}

struct Inner {
    state: State,
    config: Option<Arc<str>>,
    runs: Option<Arc<RawValue>>,
}

pub struct Fleet {
    dir: PathBuf,
    inner: Mutex<Inner>,
    /// Bumped when the executor or the configuration changes, so long-polls answer at once.
    wake: watch::Sender<u64>,
    /// Serializes changes: each is written to disk before it is committed in memory.
    writing: tokio::sync::Mutex<()>,
}

fn read_capped(path: &Path, cap: u64) -> Option<Vec<u8>> {
    let f = std::fs::File::open(path).ok()?;
    let mut buf = Vec::new();
    f.take(cap + 1).read_to_end(&mut buf).ok()?;
    (buf.len() as u64 <= cap).then_some(buf)
}

fn revision_of(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes).get(..8).unwrap_or_default())
}

impl Fleet {
    /// Loads the saved state. No file: no executor (every client runs). A file that can't be read
    /// leaves the record in `error` (nobody may act as the executor until one is assigned).
    pub fn open(dir: PathBuf) -> Fleet {
        let path = dir.join("fleet.json");
        let mut state: State = match read_capped(&path, MAX_STATE) {
            Some(b) => serde_json::from_slice(&b).unwrap_or_else(|e| {
                tracing::error!("fleet.json unreadable: {e}; assign the executor again");
                State {
                    error: Some(format!("fleet.json unreadable: {e}")),
                    ..State::default()
                }
            }),
            None if path.exists() => {
                tracing::error!("fleet.json unreadable or too large; assign the executor again");
                State {
                    error: Some("fleet.json unreadable or too large".into()),
                    ..State::default()
                }
            }
            None => State::default(),
        };
        let config = state.config.as_ref().and_then(|meta| {
            let b = read_capped(&dir.join("fleet-config.toml"), MAX_CONFIG as u64)?;
            let text = String::from_utf8(b).ok()?;
            (revision_of(text.as_bytes()) == meta.revision).then(|| Arc::<str>::from(text))
        });
        if config.is_none() {
            state.config = None;
        }
        let runs = state.runs.as_ref().and_then(|meta| {
            let b = read_capped(&dir.join("fleet-runs.json"), MAX_RUNS as u64)?;
            let raw: Box<RawValue> = serde_json::from_slice(&b).ok()?;
            (revision_of(raw.get().as_bytes()) == meta.revision).then(|| Arc::<RawValue>::from(raw))
        });
        if runs.is_none() {
            state.runs = None;
        }
        Fleet {
            dir,
            inner: Mutex::new(Inner {
                state,
                config,
                runs,
            }),
            wake: watch::channel(0).0,
            writing: tokio::sync::Mutex::new(()),
        }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(|p| p.into_inner())
    }

    pub fn state(&self) -> State {
        self.lock().state.clone()
    }

    pub fn subscribe(&self) -> watch::Receiver<u64> {
        self.wake.subscribe()
    }

    fn bump(&self) {
        self.wake.send_modify(|n| *n = n.wrapping_add(1));
    }

    /// Whether `client` may act as the executor: anyone while none is assigned (and the record
    /// was readable).
    pub fn allows(&self, client: Option<&str>) -> bool {
        let g = self.lock();
        match (&g.state.executor, &g.state.error) {
            (_, Some(_)) => false,
            (None, None) => true,
            (Some(ex), None) => client == Some(ex.id.as_str()),
        }
    }

    fn is_executor(&self, client: &str) -> bool {
        self.lock()
            .state
            .executor
            .as_ref()
            .is_some_and(|ex| ex.id == client)
    }

    async fn save_state(&self, state: &State) -> Result<(), FleetError> {
        let bytes = serde_json::to_vec_pretty(state).map_err(|e| FleetError::Io(e.to_string()))?;
        crate::util::write_atomic(&self.dir.join("fleet.json"), &bytes)
            .await
            .map_err(|e| FleetError::Io(format!("cannot write fleet.json: {e}")))
    }

    /// Makes `client` the executor when `base` is the current revision. Taking over from another
    /// executor starts the new one after what the old one confirmed on `store_id`; coming from no
    /// executor (everyone ran), after `own_cursor`, the new one's last poll.
    pub async fn assign(
        &self,
        client: &str,
        name: Option<String>,
        base: u64,
        store_id: &str,
        own_cursor: Option<u64>,
    ) -> Result<State, FleetError> {
        let _w = self.writing.lock().await;
        let cur = self.state();
        if cur.revision != base {
            return Err(FleetError::Conflict(Box::new(cur)));
        }
        if cur.error.is_none() && cur.executor.as_ref().is_some_and(|ex| ex.id == client) {
            return Ok(cur);
        }
        let handover = cur
            .executor
            .as_ref()
            .and_then(|ex| ex.acked.as_ref())
            .filter(|a| a.store_id == store_id)
            .map(|a| a.seq);
        let start = if cur.executor.is_some() {
            handover
        } else {
            own_cursor
        };
        let mut next = cur;
        next.revision += 1;
        next.error = None;
        next.executor = Some(Executor {
            id: client.to_string(),
            name,
            since: Utc::now(),
            handover,
            acked: start.map(|seq| Acked {
                store_id: store_id.to_string(),
                seq,
            }),
        });
        self.save_state(&next).await?;
        self.lock().state = next.clone();
        self.bump();
        tracing::info!(
            client,
            ?handover,
            revision = next.revision,
            "executor assigned"
        );
        Ok(next)
    }

    /// Records that the executor of `revision` has handled the events up to `seq` (it polls after
    /// them). Ignored from anyone else, or for an assignment that is no longer current. Kept in
    /// memory when it can't be saved (only a restart would forget it).
    pub async fn ack(&self, client: &str, revision: u64, store_id: &str, seq: u64) {
        let _w = self.writing.lock().await;
        let mut next = self.state();
        if next.revision != revision {
            return;
        }
        let acked = Acked {
            store_id: store_id.to_string(),
            seq,
        };
        let Some(ex) = next.executor.as_mut().filter(|ex| ex.id == client) else {
            return;
        };
        if ex.acked.as_ref() == Some(&acked) {
            return;
        }
        ex.acked = Some(acked);
        if let Err(FleetError::Io(e)) = self.save_state(&next).await {
            tracing::warn!("cannot record executor progress: {e}");
        }
        self.lock().state = next;
    }

    pub fn config(&self) -> (Option<Blob>, Option<Arc<str>>) {
        let g = self.lock();
        (g.state.config.clone(), g.config.clone())
    }

    pub fn runs(&self) -> (Option<Blob>, Option<Arc<RawValue>>) {
        let g = self.lock();
        (g.state.runs.clone(), g.runs.clone())
    }

    /// Stores the executor's configuration. Unchanged text writes nothing.
    pub async fn put_config(&self, client: &str, text: String) -> Result<Blob, FleetError> {
        if text.len() > MAX_CONFIG {
            return Err(FleetError::TooLarge(MAX_CONFIG));
        }
        let _w = self.writing.lock().await;
        if !self.is_executor(client) {
            return Err(FleetError::NotExecutor);
        }
        let revision = revision_of(text.as_bytes());
        let mut next = self.state();
        if let Some(b) = next.config.as_ref().filter(|b| b.revision == revision) {
            return Ok(b.clone());
        }
        crate::util::write_atomic(&self.dir.join("fleet-config.toml"), text.as_bytes())
            .await
            .map_err(|e| FleetError::Io(format!("cannot write fleet-config.toml: {e}")))?;
        let blob = Blob {
            revision,
            client: client.to_string(),
            at: Utc::now(),
            bytes: text.len(),
        };
        next.config = Some(blob.clone());
        self.save_state(&next).await?;
        {
            let mut g = self.lock();
            g.state = next;
            g.config = Some(Arc::from(text));
        }
        self.bump();
        Ok(blob)
    }

    /// Stores the executor's run summaries (any JSON; the plugin defines the shape).
    pub async fn put_runs(&self, client: &str, raw: Box<RawValue>) -> Result<Blob, FleetError> {
        let bytes = raw.get().len();
        if bytes > MAX_RUNS {
            return Err(FleetError::TooLarge(MAX_RUNS));
        }
        let _w = self.writing.lock().await;
        if !self.is_executor(client) {
            return Err(FleetError::NotExecutor);
        }
        let revision = revision_of(raw.get().as_bytes());
        let mut next = self.state();
        if let Some(b) = next.runs.as_ref().filter(|b| b.revision == revision) {
            return Ok(b.clone());
        }
        crate::util::write_atomic(&self.dir.join("fleet-runs.json"), raw.get().as_bytes())
            .await
            .map_err(|e| FleetError::Io(format!("cannot write fleet-runs.json: {e}")))?;
        let blob = Blob {
            revision,
            client: client.to_string(),
            at: Utc::now(),
            bytes,
        };
        next.runs = Some(blob.clone());
        self.save_state(&next).await?;
        {
            let mut g = self.lock();
            g.state = next;
            g.runs = Some(Arc::from(raw));
        }
        Ok(blob)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn raw(s: &str) -> Box<RawValue> {
        RawValue::from_string(s.to_string()).unwrap()
    }

    #[tokio::test]
    async fn assignment_hands_over_what_the_old_executor_confirmed_and_survives_reopen() {
        let dir = tempfile::tempdir().unwrap();
        let f = Fleet::open(dir.path().to_path_buf());
        assert!(
            f.allows(Some("a")) && f.allows(None),
            "no executor: everyone runs"
        );

        // From no executor: a starts where its own polls were.
        let s = f
            .assign("a", Some("mac".into()), 0, "st", Some(4))
            .await
            .unwrap();
        let ex = s.executor.as_ref().unwrap();
        assert_eq!((s.revision, ex.handover), (1, None));
        assert_eq!(ex.acked.as_ref().map(|a| a.seq), Some(4));
        assert!(f.allows(Some("a")) && !f.allows(Some("b")) && !f.allows(None));
        assert!(matches!(
            f.assign("b", None, 0, "st", None).await,
            Err(FleetError::Conflict(_))
        ));

        f.ack("b", 1, "st", 9).await; // not the executor: ignored
        f.ack("a", 0, "st", 8).await; // an old assignment: ignored
        f.ack("a", 1, "st", 7).await;
        let s = f.assign("b", None, 1, "st", Some(30)).await.unwrap();
        assert_eq!(s.executor.as_ref().unwrap().handover, Some(7));

        // b never polled as the executor: c still starts after 7, not at its own cursor.
        let s = f.assign("c", None, 2, "st", Some(40)).await.unwrap();
        assert_eq!(s.executor.as_ref().unwrap().handover, Some(7));

        // A cursor on another store says nothing about this one.
        f.ack("c", 3, "old", 3).await;
        let s = f.assign("a", None, 3, "st", None).await.unwrap();
        assert_eq!(s.executor.as_ref().unwrap().handover, None);

        let again = Fleet::open(dir.path().to_path_buf());
        assert_eq!(again.state().revision, 4);
        assert!(again.allows(Some("a")) && !again.allows(Some("b")));

        // An unreadable record lets nobody act as the executor until one is assigned again.
        std::fs::write(dir.path().join("fleet.json"), "{ truncated").unwrap();
        let broken = Fleet::open(dir.path().to_path_buf());
        assert!(broken.state().error.is_some());
        assert!(!broken.allows(Some("a")) && !broken.allows(None));
        let s = broken.assign("a", None, 0, "st", None).await.unwrap();
        assert!(s.error.is_none() && broken.allows(Some("a")));
    }

    #[tokio::test]
    async fn uploads_need_the_executor_and_keep_revisions() {
        let dir = tempfile::tempdir().unwrap();
        let f = Fleet::open(dir.path().to_path_buf());
        assert!(matches!(
            f.put_config("a", "x".into()).await,
            Err(FleetError::NotExecutor)
        ));
        f.assign("a", None, 0, "st", None).await.unwrap();
        assert!(matches!(
            f.put_config("b", "x".into()).await,
            Err(FleetError::NotExecutor)
        ));
        let mut rx = f.subscribe();
        rx.borrow_and_update();
        let b1 = f.put_config("a", "[roost]\n".into()).await.unwrap();
        assert!(
            rx.has_changed().unwrap(),
            "a new configuration wakes long-polls"
        );
        let b2 = f.put_config("a", "[roost]\n".into()).await.unwrap();
        assert_eq!(
            (b1.revision.clone(), b1.at),
            (b2.revision, b2.at),
            "unchanged"
        );
        assert!(matches!(
            f.put_config("a", "x".repeat(MAX_CONFIG + 1)).await,
            Err(FleetError::TooLarge(_))
        ));
        let r = f.put_runs("a", raw(r#"{"runs":[1]}"#)).await.unwrap();

        let again = Fleet::open(dir.path().to_path_buf());
        let (meta, text) = again.config();
        assert_eq!(meta.unwrap().revision, b1.revision);
        assert_eq!(text.as_deref(), Some("[roost]\n"));
        let (meta, body) = again.runs();
        assert_eq!(meta.unwrap().revision, r.revision);
        assert_eq!(body.unwrap().get(), r#"{"runs":[1]}"#);

        // A content file that no longer matches its recorded revision is dropped.
        std::fs::write(dir.path().join("fleet-config.toml"), "tampered").unwrap();
        assert!(Fleet::open(dir.path().to_path_buf()).config().0.is_none());
    }
}
