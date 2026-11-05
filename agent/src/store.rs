//! Relayed events: a bounded, persisted, sequence-numbered log the plugin reads with a cursor.
//!
//! Each event is one file `<data>/events/<seq>.json`; `state.json` keeps the store id and the
//! next sequence number so cursors stay valid across restarts. Bounded by count, age and bytes.

use std::collections::VecDeque;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::value::RawValue;
use sha2::{Digest, Sha256};
use tokio::sync::watch;

use crate::event::EventInfo;

/// Upper bound on events returned per read.
pub const MAX_PAGE: usize = 200;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StoredEvent {
    pub seq: u64,
    /// The store this event belongs to; lets a lost `state.json` be rebuilt without a new id
    /// (which would make clients re-read every retained event as new).
    #[serde(default)]
    pub store_id: String,
    pub delivery: String,
    pub received_at: DateTime<Utc>,
    pub event: String,
    pub repo: Option<String>,
    pub info: EventInfo,
    /// The webhook body as received (verified JSON), absent when it was over the payload cap.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub payload: Option<Box<RawValue>>,
    #[serde(default)]
    pub payload_truncated: bool,
}

impl StoredEvent {
    fn weight(&self) -> usize {
        self.payload.as_ref().map(|p| p.get().len()).unwrap_or(0) + 1024
    }
}

#[derive(Debug, Serialize, Deserialize)]
struct StateFile {
    store_id: String,
    next_seq: u64,
}

struct Inner {
    events: VecDeque<Arc<StoredEvent>>,
    next_seq: u64,
    /// Highest sequence number visible to clients.
    committed: u64,
    bytes: usize,
}

pub struct Limits {
    pub keep: usize,
    pub max_age: Duration,
    pub max_total_bytes: usize,
    pub max_file_bytes: u64,
}

pub struct EventStore {
    dir: PathBuf,
    limits: Limits,
    store_id: String,
    inner: Mutex<Inner>,
    head: watch::Sender<u64>,
    /// Serializes pushes so event files and `state.json` are written in sequence order.
    writing: tokio::sync::Mutex<()>,
}

pub struct Page {
    pub events: Vec<Arc<StoredEvent>>,
    pub head: u64,
    pub oldest: u64,
    /// Events after the cursor were evicted before this read.
    pub gap: bool,
}

fn read_capped(path: &Path, cap: u64) -> Option<Vec<u8>> {
    let f = std::fs::File::open(path).ok()?;
    let mut buf = Vec::new();
    f.take(cap + 1).read_to_end(&mut buf).ok()?;
    (buf.len() as u64 <= cap).then_some(buf)
}

fn file_name(seq: u64) -> String {
    format!("{seq:016}.json")
}

impl EventStore {
    pub fn open(dir: PathBuf, limits: Limits) -> std::io::Result<EventStore> {
        let events_dir = dir.join("events");
        std::fs::create_dir_all(&events_dir)?;
        let state: Option<StateFile> = read_capped(&dir.join("state.json"), 64 * 1024)
            .and_then(|b| serde_json::from_slice(&b).ok());
        let mut names: Vec<(u64, PathBuf)> = Vec::new();
        for entry in std::fs::read_dir(&events_dir)? {
            let entry = entry?;
            let name = entry.file_name().to_string_lossy().to_string();
            if let Some(seq) = name
                .strip_suffix(".json")
                .and_then(|s| s.parse::<u64>().ok())
            {
                names.push((seq, entry.path()));
            }
        }
        names.sort_by_key(|(s, _)| *s);
        // Only the newest `keep` files are candidates; older ones are deleted unread.
        let skip = names.len().saturating_sub(limits.keep);
        let mut events = VecDeque::new();
        let mut bytes = 0;
        let mut max_seq = 0;
        for (i, (seq, path)) in names.iter().enumerate() {
            max_seq = max_seq.max(*seq);
            let loaded = if i < skip {
                None
            } else {
                read_capped(path, limits.max_file_bytes)
                    .and_then(|b| serde_json::from_slice::<StoredEvent>(&b).ok())
            };
            match loaded {
                Some(ev) if ev.seq == *seq => {
                    bytes += ev.weight();
                    events.push_back(Arc::new(ev));
                }
                _ => {
                    let _ = std::fs::remove_file(path);
                }
            }
        }
        let (store_id, next_seq) = match state {
            Some(s) => (s.store_id, s.next_seq.max(max_seq + 1)),
            None => {
                let kept = events
                    .back()
                    .map(|e| e.store_id.clone())
                    .filter(|s| !s.is_empty());
                let id = kept.unwrap_or_else(|| {
                    let seed = format!(
                        "{}:{}:{}",
                        Utc::now().timestamp_nanos_opt().unwrap_or(0),
                        std::process::id(),
                        dir.display()
                    );
                    hex::encode(Sha256::digest(seed.as_bytes()).get(..8).unwrap_or_default())
                });
                (id, max_seq + 1)
            }
        };
        let head = next_seq - 1;
        let store = EventStore {
            dir,
            limits,
            store_id,
            inner: Mutex::new(Inner {
                events,
                next_seq,
                committed: head,
                bytes,
            }),
            head: watch::channel(head).0,
            writing: tokio::sync::Mutex::new(()),
        };
        store.write_state_sync(next_seq)?;
        let evicted = store.evict(Utc::now());
        for seq in evicted {
            let _ = std::fs::remove_file(store.event_path(seq));
        }
        Ok(store)
    }

    pub fn store_id(&self) -> &str {
        &self.store_id
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(|p| p.into_inner())
    }

    fn event_path(&self, seq: u64) -> PathBuf {
        self.dir.join("events").join(file_name(seq))
    }

    fn write_state_sync(&self, next_seq: u64) -> std::io::Result<()> {
        let bytes = serde_json::to_vec(&StateFile {
            store_id: self.store_id.clone(),
            next_seq,
        })
        .map_err(std::io::Error::other)?;
        let path = self.dir.join("state.json");
        let tmp = self.dir.join("state.json.tmp");
        std::fs::write(&tmp, bytes)?;
        std::fs::rename(tmp, path)
    }

    /// Drops events past the count, age and byte limits; returns their sequence numbers.
    fn evict(&self, now: DateTime<Utc>) -> Vec<u64> {
        let mut g = self.lock();
        let cutoff = chrono::Duration::from_std(self.limits.max_age)
            .ok()
            .map(|d| now - d);
        let mut out = Vec::new();
        while let Some(front) = g.events.front() {
            let old = cutoff.is_some_and(|c| front.received_at < c);
            if g.events.len() > self.limits.keep || g.bytes > self.limits.max_total_bytes || old {
                let w = front.weight();
                out.push(front.seq);
                g.bytes = g.bytes.saturating_sub(w);
                g.events.pop_front();
            } else {
                break;
            }
        }
        out
    }

    pub fn has_delivery(&self, delivery: &str) -> bool {
        self.lock().events.iter().any(|e| e.delivery == delivery)
    }

    /// Persists an event, then makes it visible and wakes long-polls. An event whose files can't
    /// be written is never shown to clients (its sequence number is skipped, not reused).
    pub async fn push(
        &self,
        delivery: String,
        info: EventInfo,
        payload: Option<Box<RawValue>>,
        payload_truncated: bool,
    ) -> std::io::Result<Arc<StoredEvent>> {
        let _writing = self.writing.lock().await;
        let seq = {
            let mut g = self.lock();
            let seq = g.next_seq;
            g.next_seq += 1;
            seq
        };
        let ev = Arc::new(StoredEvent {
            seq,
            store_id: self.store_id.clone(),
            delivery,
            received_at: Utc::now(),
            event: info.event.clone(),
            repo: info.repo.clone(),
            info,
            payload,
            payload_truncated,
        });
        let state = serde_json::to_vec(&StateFile {
            store_id: self.store_id.clone(),
            next_seq: seq + 1,
        })
        .map_err(std::io::Error::other)?;
        crate::util::write_atomic(&self.dir.join("state.json"), &state).await?;
        let bytes = serde_json::to_vec(&*ev).map_err(std::io::Error::other)?;
        crate::util::write_atomic(&self.event_path(seq), &bytes).await?;
        {
            let mut g = self.lock();
            g.bytes += ev.weight();
            g.events.push_back(ev.clone());
            g.committed = seq;
        }
        self.head.send_replace(seq);
        for seq in self.evict(Utc::now()) {
            if let Err(e) = tokio::fs::remove_file(self.event_path(seq)).await
                && e.kind() != std::io::ErrorKind::NotFound
            {
                tracing::warn!(seq, "cannot remove evicted event: {e}");
            }
        }
        Ok(ev)
    }

    pub fn page(&self, after: u64, limit: usize) -> Page {
        let g = self.lock();
        let head = g.committed;
        let oldest = g.events.front().map(|e| e.seq).unwrap_or(head + 1);
        let events: Vec<_> = g
            .events
            .iter()
            .filter(|e| e.seq > after)
            .take(limit.clamp(1, MAX_PAGE))
            .cloned()
            .collect();
        Page {
            gap: after + 1 < oldest && after < head,
            events,
            head,
            oldest,
        }
    }

    pub fn stats(&self) -> (u64, u64, usize, usize) {
        let g = self.lock();
        let oldest = g.events.front().map(|e| e.seq).unwrap_or(g.committed + 1);
        (g.committed, oldest, g.events.len(), g.bytes)
    }

    pub fn subscribe(&self) -> watch::Receiver<u64> {
        self.head.subscribe()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn limits(keep: usize) -> Limits {
        Limits {
            keep,
            max_age: Duration::from_secs(3600),
            max_total_bytes: 1 << 30,
            max_file_bytes: 1 << 20,
        }
    }

    fn info(event: &str) -> EventInfo {
        EventInfo {
            event: event.into(),
            repo: Some("a/b".into()),
            ..Default::default()
        }
    }

    #[tokio::test]
    async fn cursor_paging_eviction_gap_and_reopen() {
        let dir = tempfile::tempdir().unwrap();
        let store = EventStore::open(dir.path().to_path_buf(), limits(3)).unwrap();
        let id = store.store_id().to_string();
        for i in 0..5 {
            let p = RawValue::from_string(format!("{{\"n\":{i}}}")).unwrap();
            store
                .push(format!("d{i}"), info("push"), Some(p), false)
                .await
                .unwrap();
        }
        let page = store.page(0, 10);
        assert_eq!(page.head, 5);
        assert_eq!(page.oldest, 3);
        assert!(page.gap, "seq 1-2 evicted");
        assert_eq!(
            page.events.iter().map(|e| e.seq).collect::<Vec<_>>(),
            vec![3, 4, 5]
        );
        let page = store.page(4, 10);
        assert!(!page.gap);
        assert_eq!(page.events.len(), 1);
        assert!(store.has_delivery("d4"));
        assert!(!store.has_delivery("d0"));
        assert!(!dir.path().join("events").join(file_name(1)).exists());
        drop(store);

        let store = EventStore::open(dir.path().to_path_buf(), limits(3)).unwrap();
        assert_eq!(store.store_id(), id, "store id survives restarts");
        let page = store.page(4, 10);
        assert_eq!(page.events[0].payload.as_ref().unwrap().get(), "{\"n\":4}");
        let ev = store
            .push("d5".into(), info("issues"), None, true)
            .await
            .unwrap();
        assert_eq!(ev.seq, 6, "sequence continues after reopen");
        assert!(!store.page(5, 10).gap);
        drop(store);

        // state.json lost: the id comes back from the events, so clients don't replay them.
        std::fs::remove_file(dir.path().join("state.json")).unwrap();
        let store = EventStore::open(dir.path().to_path_buf(), limits(3)).unwrap();
        assert_eq!(store.store_id(), id);
        assert_eq!(store.page(0, 10).head, 6);
    }

    #[tokio::test]
    async fn empty_store_keeps_sequence_from_state() {
        let dir = tempfile::tempdir().unwrap();
        let mut l = limits(10);
        l.max_age = Duration::from_secs(60);
        let store = EventStore::open(dir.path().to_path_buf(), l).unwrap();
        store
            .push("x".into(), info("push"), None, false)
            .await
            .unwrap();
        std::fs::remove_file(dir.path().join("events").join(file_name(1))).unwrap();
        drop(store);
        let store = EventStore::open(dir.path().to_path_buf(), limits(10)).unwrap();
        let page = store.page(1, 10);
        assert_eq!(page.head, 1);
        assert!(page.events.is_empty());
        assert!(!page.gap);
    }
}
