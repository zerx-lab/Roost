//! The devices sharing this relay and which of them runs what.
//!
//! Every client reads every event and decides from this record which workflows are its own.
//! `owners["*"]` names the **default device**: it runs every workflow not assigned elsewhere (none
//! assigned: every device runs everything, the behaviour before devices existed).
//! `owners[<workflow id>]` gives one workflow to one device. Each list is that assignment's
//! history, oldest first: an entry's `seq` is the event store's head when it was made, so events
//! after it are that entry's and earlier ones the previous entry's (before the first entry: the
//! default device's, or for `*` every device's). A device catching up on a backlog thus runs
//! exactly what was its own when each event arrived, and reassigning never skips or doubles an
//! event. Entries no stored event needs any more are pruned.
//!
//! The workflow configuration is shared: any device uploads it, compare-and-set on the revision it
//! last had, and the others apply it. Each device uploads its own run summaries.
//!
//! An unreadable `fleet.json` is not "nothing assigned" (every device would run everything): until
//! a default device is assigned again nobody runs, and the record says why (`error`).
//!
//! Files in the data directory: `fleet.json` (this state), `fleet-config.toml` (the shared
//! configuration, Roost's export format), `fleet-runs-<hex client id>.json` (one device's run
//! summaries, opaque here).

use std::collections::BTreeMap;
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
/// Upper bound on one device's serialized run summaries.
pub const MAX_RUNS: usize = 512 * 1024;
const MAX_STATE: u64 = 4 * 1024 * 1024;
/// The `owners` key of the default device.
pub const DEFAULT: &str = "*";
/// Entries kept per assignment (older ones go first even when stored events still need them).
const MAX_HISTORY: usize = 8;
/// Workflows that may have an assignment of their own.
pub const MAX_ASSIGNED: usize = 512;
/// Devices whose run summaries are kept (the one that uploaded longest ago goes first).
pub const MAX_DEVICES: usize = 16;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Owner {
    /// The device. None: the workflow follows the default device; for `*`, every device runs.
    #[serde(default)]
    pub client: Option<String>,
    #[serde(default)]
    pub name: Option<String>,
    /// The event store's head when this was assigned: later events are this owner's.
    pub seq: u64,
    pub at: DateTime<Utc>,
}

/// The default device now (the last entry of `owners["*"]`), kept for display.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Executor {
    pub id: String,
    #[serde(default)]
    pub name: Option<String>,
    pub since: DateTime<Utc>,
}

/// What a device last uploaded (the content itself is kept beside the state).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Blob {
    pub revision: String,
    pub client: String,
    pub at: DateTime<Utc>,
    pub bytes: usize,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct State {
    /// Bumped whenever an assignment changes.
    #[serde(default)]
    pub revision: u64,
    #[serde(default)]
    pub executor: Option<Executor>,
    #[serde(default)]
    pub owners: BTreeMap<String, Vec<Owner>>,
    /// The event store the `seq`s count in.
    #[serde(default)]
    pub store: Option<String>,
    #[serde(default)]
    pub config: Option<Blob>,
    /// Each device's run summaries, by client id.
    #[serde(default)]
    pub uploads: BTreeMap<String, Blob>,
    /// Why the saved record couldn't be read; set only in memory, cleared by the next assignment
    /// of the default device.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

#[derive(Debug)]
pub enum FleetError {
    /// The record is unreadable: nothing but assigning the default device is accepted.
    Broken,
    /// `base_revision` is not the current one.
    Conflict(Box<State>),
    /// The configuration changed since the uploader last had it (the current one, if any).
    ConfigConflict(Option<Blob>),
    TooLarge(usize),
    TooMany(usize),
    Io(String),
}

struct Inner {
    state: State,
    config: Option<Arc<str>>,
    runs: BTreeMap<String, Arc<RawValue>>,
}

pub struct Fleet {
    dir: PathBuf,
    store_id: String,
    inner: Mutex<Inner>,
    /// Bumped when an assignment or the configuration changes, so long-polls answer at once.
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

fn runs_file(client: &str) -> String {
    format!("fleet-runs-{}.json", hex::encode(client.as_bytes()))
}

/// The default device as the last entry of `owners["*"]` says.
fn executor_of(owners: &BTreeMap<String, Vec<Owner>>) -> Option<Executor> {
    let o = owners.get(DEFAULT)?.last()?;
    Some(Executor {
        id: o.client.clone()?,
        name: o.name.clone(),
        since: o.at,
    })
}

/// Drops what no stored event needs: an entry covers the events after its `seq` up to the next
/// entry's, so a first entry whose successor starts before `oldest` covers none of them. A list
/// left with one "follow the default" entry says nothing and goes too.
fn prune(owners: &mut BTreeMap<String, Vec<Owner>>, oldest: u64) {
    for list in owners.values_mut() {
        while list.get(1).is_some_and(|next| next.seq < oldest) || list.len() > MAX_HISTORY {
            list.drain(..1);
        }
    }
    owners.retain(|_, list| match list.as_slice() {
        [] => false,
        [only] => only.client.is_some(),
        _ => true,
    });
}

impl Fleet {
    /// Loads the saved state. No file: nothing assigned (every client runs everything). A file that
    /// can't be read leaves the record in `error`. Assignments made on another event store (its
    /// sequence numbers started again) keep only their current entry.
    pub fn open(dir: PathBuf, store_id: &str) -> Fleet {
        let path = dir.join("fleet.json");
        let mut state: State = match read_capped(&path, MAX_STATE) {
            Some(b) => serde_json::from_slice(&b).unwrap_or_else(|e| {
                tracing::error!("fleet.json unreadable: {e}; assign the default device again");
                State {
                    error: Some(format!("fleet.json unreadable: {e}")),
                    ..State::default()
                }
            }),
            None if path.exists() => {
                tracing::error!(
                    "fleet.json unreadable or too large; assign the default device again"
                );
                State {
                    error: Some("fleet.json unreadable or too large".into()),
                    ..State::default()
                }
            }
            None => State::default(),
        };
        // A record from before assignments had a history: its executor is the default device.
        if !state.owners.contains_key(DEFAULT)
            && let Some(ex) = state.executor.clone()
        {
            state.owners.insert(
                DEFAULT.to_string(),
                vec![Owner {
                    client: Some(ex.id),
                    name: ex.name,
                    seq: 0,
                    at: ex.since,
                }],
            );
        }
        if state.store.as_deref() != Some(store_id) {
            for list in state.owners.values_mut() {
                if let Some(mut last) = list.pop() {
                    last.seq = 0;
                    *list = vec![last];
                }
            }
            state
                .owners
                .retain(|_, l| l.iter().any(|o| o.client.is_some()));
            state.store = Some(store_id.to_string());
        }
        state.executor = executor_of(&state.owners);
        let config = state.config.as_ref().and_then(|meta| {
            let b = read_capped(&dir.join("fleet-config.toml"), MAX_CONFIG as u64)?;
            let text = String::from_utf8(b).ok()?;
            (revision_of(text.as_bytes()) == meta.revision).then(|| Arc::<str>::from(text))
        });
        if config.is_none() {
            state.config = None;
        }
        // The single executor's run summaries, from before each device uploaded its own.
        let _ = std::fs::remove_file(dir.join("fleet-runs.json"));
        let mut runs = BTreeMap::new();
        state.uploads.retain(|client, meta| {
            let loaded = read_capped(&dir.join(runs_file(client)), MAX_RUNS as u64)
                .and_then(|b| serde_json::from_slice::<Box<RawValue>>(&b).ok())
                .filter(|raw| revision_of(raw.get().as_bytes()) == meta.revision);
            match loaded {
                Some(raw) => {
                    runs.insert(client.clone(), Arc::<RawValue>::from(raw));
                    true
                }
                None => false,
            }
        });
        Fleet {
            dir,
            store_id: store_id.to_string(),
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

    /// Whether devices may act at all: not while the record is unreadable.
    pub fn usable(&self) -> bool {
        self.lock().state.error.is_none()
    }

    /// The name the record has for `client`, when it appears in it.
    pub fn known(&self, client: &str) -> Option<Option<String>> {
        let g = self.lock();
        g.state
            .owners
            .values()
            .flatten()
            .rev()
            .find(|o| o.client.as_deref() == Some(client))
            .map(|o| o.name.clone())
    }

    async fn save_state(&self, state: &State) -> Result<(), FleetError> {
        let bytes = serde_json::to_vec_pretty(state).map_err(|e| FleetError::Io(e.to_string()))?;
        crate::util::write_atomic(&self.dir.join("fleet.json"), &bytes)
            .await
            .map_err(|e| FleetError::Io(format!("cannot write fleet.json: {e}")))
    }

    /// Gives `key` (a workflow id, or `DEFAULT`) to `client` (None: a workflow follows the default
    /// device again; the default cleared: every device runs) from the events after the store's
    /// head on, when `base` is the current revision. `store` gives the head and the oldest stored
    /// event (what the history must still cover); it is read once the change holds the lock, so
    /// only events pushed during the write itself can still be seen under the old record. Only
    /// the default device may be assigned while the record is unreadable.
    pub async fn assign(
        &self,
        key: &str,
        client: Option<&str>,
        name: Option<String>,
        base: u64,
        store: impl FnOnce() -> (u64, u64),
    ) -> Result<State, FleetError> {
        let _w = self.writing.lock().await;
        let cur = self.state();
        if cur.revision != base {
            return Err(FleetError::Conflict(Box::new(cur)));
        }
        let broken = cur.error.is_some();
        if broken && key != DEFAULT {
            return Err(FleetError::Broken);
        }
        let now_owner = cur
            .owners
            .get(key)
            .and_then(|l| l.last())
            .and_then(|o| o.client.as_deref());
        if !broken && now_owner == client {
            return Ok(cur);
        }
        if key != DEFAULT
            && !cur.owners.contains_key(key)
            && cur.owners.keys().filter(|k| *k != DEFAULT).count() >= MAX_ASSIGNED
        {
            return Err(FleetError::TooMany(MAX_ASSIGNED));
        }
        let (head, oldest) = store();
        let mut next = cur;
        next.owners.entry(key.to_string()).or_default().push(Owner {
            client: client.map(str::to_string),
            name: client.and(name),
            seq: head,
            at: Utc::now(),
        });
        prune(&mut next.owners, oldest);
        next.executor = executor_of(&next.owners);
        next.revision += 1;
        next.error = None;
        next.store = Some(self.store_id.clone());
        self.save_state(&next).await?;
        self.lock().state = next.clone();
        self.bump();
        tracing::info!(key, ?client, head, revision = next.revision, "assigned");
        Ok(next)
    }

    pub fn config(&self) -> (Option<Blob>, Option<Arc<str>>) {
        let g = self.lock();
        (g.state.config.clone(), g.config.clone())
    }

    pub fn runs(&self, client: &str) -> (Option<Blob>, Option<Arc<RawValue>>) {
        let g = self.lock();
        (
            g.state.uploads.get(client).cloned(),
            g.runs.get(client).cloned(),
        )
    }

    /// Stores the shared configuration when `base` is the revision the relay holds (None: it holds
    /// none). The text it already holds is accepted whatever `base` says.
    pub async fn put_config(
        &self,
        client: &str,
        text: String,
        base: Option<&str>,
    ) -> Result<Blob, FleetError> {
        if text.len() > MAX_CONFIG {
            return Err(FleetError::TooLarge(MAX_CONFIG));
        }
        let _w = self.writing.lock().await;
        let mut next = self.state();
        if next.error.is_some() {
            return Err(FleetError::Broken);
        }
        let revision = revision_of(text.as_bytes());
        if let Some(b) = next.config.as_ref().filter(|b| b.revision == revision) {
            return Ok(b.clone());
        }
        if next.config.as_ref().map(|b| b.revision.as_str()) != base {
            return Err(FleetError::ConfigConflict(next.config));
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

    /// Stores `client`'s run summaries (any JSON; the plugin defines the shape). A new device over
    /// MAX_DEVICES pushes out the one that uploaded longest ago.
    pub async fn put_runs(&self, client: &str, raw: Box<RawValue>) -> Result<Blob, FleetError> {
        let bytes = raw.get().len();
        if bytes > MAX_RUNS {
            return Err(FleetError::TooLarge(MAX_RUNS));
        }
        let _w = self.writing.lock().await;
        let revision = revision_of(raw.get().as_bytes());
        let mut next = self.state();
        if let Some(b) = next.uploads.get(client).filter(|b| b.revision == revision) {
            return Ok(b.clone());
        }
        let mut evicted = None;
        if !next.uploads.contains_key(client)
            && next.uploads.len() >= MAX_DEVICES
            && let Some(old) = next
                .uploads
                .iter()
                .min_by_key(|(_, b)| b.at)
                .map(|(c, _)| c.clone())
        {
            next.uploads.remove(&old);
            evicted = Some(old);
        }
        crate::util::write_atomic(&self.dir.join(runs_file(client)), raw.get().as_bytes())
            .await
            .map_err(|e| FleetError::Io(format!("cannot write the run summaries: {e}")))?;
        let blob = Blob {
            revision,
            client: client.to_string(),
            at: Utc::now(),
            bytes,
        };
        next.uploads.insert(client.to_string(), blob.clone());
        self.save_state(&next).await?;
        {
            let mut g = self.lock();
            g.state = next;
            g.runs.insert(client.to_string(), Arc::from(raw));
            if let Some(old) = &evicted {
                g.runs.remove(old);
            }
        }
        if let Some(old) = evicted {
            let _ = tokio::fs::remove_file(self.dir.join(runs_file(&old))).await;
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

    fn owners_of(s: &State, key: &str) -> Vec<(Option<String>, u64)> {
        s.owners
            .get(key)
            .map(|l| l.iter().map(|o| (o.client.clone(), o.seq)).collect())
            .unwrap_or_default()
    }

    #[tokio::test]
    async fn assignments_keep_the_history_stored_events_need_and_survive_reopen() {
        let dir = tempfile::tempdir().unwrap();
        let f = Fleet::open(dir.path().to_path_buf(), "st");
        assert!(f.usable());

        let s = f
            .assign(DEFAULT, Some("a"), Some("mac".into()), 0, || (4, 1))
            .await
            .unwrap();
        assert_eq!(s.revision, 1);
        assert_eq!(s.executor.as_ref().map(|e| e.id.as_str()), Some("a"));
        assert!(matches!(
            f.assign("wf", Some("b"), None, 0, || (5, 1)).await,
            Err(FleetError::Conflict(_))
        ));
        let s = f.assign("wf", Some("b"), None, 1, || (6, 1)).await.unwrap();
        // The same owner again changes nothing.
        let same = f.assign("wf", Some("b"), None, 2, || (9, 1)).await.unwrap();
        assert_eq!(same.revision, 2);
        let s = f
            .assign("wf", None, None, s.revision, || (10, 1))
            .await
            .unwrap();
        assert_eq!(owners_of(&s, "wf"), vec![(Some("b".into()), 6), (None, 10)]);
        // Once no stored event is at or before 10, b's entry covers nothing.
        let s = f
            .assign(DEFAULT, Some("c"), None, s.revision, || (12, 11))
            .await
            .unwrap();
        assert!(
            !s.owners.contains_key("wf"),
            "following the default says nothing"
        );
        assert_eq!(
            owners_of(&s, DEFAULT),
            vec![(Some("a".into()), 4), (Some("c".into()), 12)]
        );

        let again = Fleet::open(dir.path().to_path_buf(), "st");
        assert_eq!(again.state().revision, s.revision);
        assert_eq!(again.state().executor.unwrap().id, "c");
        assert_eq!(again.known("a"), Some(Some("mac".into())));

        // Another event store: sequence numbers start again, only current owners stay.
        let other = Fleet::open(dir.path().to_path_buf(), "new");
        assert_eq!(
            owners_of(&other.state(), DEFAULT),
            vec![(Some("c".into()), 0)]
        );

        // An unreadable record: nothing goes until the default device is assigned again.
        std::fs::write(dir.path().join("fleet.json"), "{ truncated").unwrap();
        let broken = Fleet::open(dir.path().to_path_buf(), "st");
        assert!(!broken.usable());
        assert!(matches!(
            broken.assign("wf", Some("a"), None, 0, || (1, 1)).await,
            Err(FleetError::Broken)
        ));
        assert!(matches!(
            broken.put_config("a", "x".into(), None).await,
            Err(FleetError::Broken)
        ));
        let s = broken
            .assign(DEFAULT, Some("a"), None, 0, || (1, 1))
            .await
            .unwrap();
        assert!(s.error.is_none() && broken.usable());
    }

    #[tokio::test]
    async fn an_old_record_makes_its_executor_the_default_device() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(
            dir.path().join("fleet.json"),
            r#"{"revision":3,"executor":{"id":"a","name":"mac","since":"2026-11-06T00:00:00Z","handover":7,"acked":{"store_id":"st","seq":9}},"runs":{"revision":"x","client":"a","at":"2026-11-06T00:00:00Z","bytes":1}}"#,
        )
        .unwrap();
        let f = Fleet::open(dir.path().to_path_buf(), "st");
        let s = f.state();
        assert!(s.error.is_none());
        assert_eq!(owners_of(&s, DEFAULT), vec![(Some("a".into()), 0)]);
        assert_eq!(s.executor.unwrap().name.as_deref(), Some("mac"));
    }

    #[tokio::test]
    async fn the_configuration_is_compare_and_set_and_runs_are_per_device() {
        let dir = tempfile::tempdir().unwrap();
        let f = Fleet::open(dir.path().to_path_buf(), "st");
        let mut rx = f.subscribe();
        rx.borrow_and_update();
        let b1 = f.put_config("a", "[roost]\n".into(), None).await.unwrap();
        assert!(
            rx.has_changed().unwrap(),
            "a new configuration wakes long-polls"
        );
        // The same text is accepted whatever base it comes with.
        let b2 = f.put_config("b", "[roost]\n".into(), None).await.unwrap();
        assert_eq!((b1.revision.clone(), b1.at), (b2.revision, b2.at));
        // An edit made on an older revision is refused with the current one.
        match f.put_config("b", "two".into(), None).await {
            Err(FleetError::ConfigConflict(Some(cur))) => assert_eq!(cur.revision, b1.revision),
            other => panic!("{other:?}"),
        }
        let b3 = f
            .put_config("b", "two".into(), Some(&b1.revision))
            .await
            .unwrap();
        assert_eq!(b3.client, "b");
        assert!(matches!(
            f.put_config("a", "x".repeat(MAX_CONFIG + 1), Some(&b3.revision))
                .await,
            Err(FleetError::TooLarge(_))
        ));
        let ra = f.put_runs("a", raw(r#"{"runs":[1]}"#)).await.unwrap();
        f.put_runs("b", raw(r#"{"runs":[2]}"#)).await.unwrap();

        let again = Fleet::open(dir.path().to_path_buf(), "st");
        let (meta, text) = again.config();
        assert_eq!(meta.unwrap().revision, b3.revision);
        assert_eq!(text.as_deref(), Some("two"));
        let (meta, body) = again.runs("a");
        assert_eq!(meta.unwrap().revision, ra.revision);
        assert_eq!(body.unwrap().get(), r#"{"runs":[1]}"#);
        assert_eq!(again.runs("b").1.unwrap().get(), r#"{"runs":[2]}"#);

        for i in 0..MAX_DEVICES {
            f.put_runs(&format!("d{i}"), raw("{}")).await.unwrap();
        }
        assert!(f.runs("a").0.is_none(), "the oldest upload made room");
        assert!(!dir.path().join(runs_file("a")).exists());

        // A content file that no longer matches its recorded revision is dropped.
        std::fs::write(dir.path().join("fleet-config.toml"), "tampered").unwrap();
        assert!(
            Fleet::open(dir.path().to_path_buf(), "st")
                .config()
                .0
                .is_none()
        );
    }
}
