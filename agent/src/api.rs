//! HTTP surface: the GitHub webhook endpoint and the bearer-token admin API the plugin uses.

use std::collections::{BTreeMap, VecDeque};
use std::sync::{Arc, Mutex, RwLock};
use std::time::Duration;

use axum::body::Bytes;
use axum::extract::{DefaultBodyLimit, Query, Request, State};
use axum::http::{HeaderMap, StatusCode};
use axum::middleware::{self, Next};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::value::RawValue;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use subtle::ConstantTimeEq;
use tokio::sync::watch;

use crate::config::{AgentConfig, Issue, RepoSub, Subscriptions};
use crate::event::EventInfo;
use crate::github::{self, SyncReport};
use crate::store::{EventStore, MAX_PAGE, StoredEvent};

const MAX_DELIVERIES: usize = 200;
const MAX_CLIENTS: usize = 32;
const MAX_WAIT: Duration = Duration::from_secs(30);
const ADMIN_BODY_LIMIT: usize = 1024 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Shutdown {
    Stop,
    Restart,
}

#[derive(Debug, Clone, Serialize)]
pub struct Delivery {
    pub delivery: String,
    pub at: DateTime<Utc>,
    pub event: String,
    pub action: Option<String>,
    pub repo: Option<String>,
    /// `relayed`, `ignored`, `duplicate`, `ping` or `rejected`.
    pub outcome: &'static str,
    pub reason: Option<String>,
    pub seq: Option<u64>,
}

#[derive(Debug, Clone, Serialize)]
pub struct ClientSeen {
    pub id: String,
    pub name: Option<String>,
    pub last_seen: DateTime<Utc>,
    pub cursor: u64,
}

pub struct AppState {
    pub cfg: Arc<AgentConfig>,
    pub subs: RwLock<Arc<Subscriptions>>,
    pub store: Arc<EventStore>,
    pub deliveries: Mutex<VecDeque<Delivery>>,
    pub delivery_total: Mutex<u64>,
    pub clients: Mutex<BTreeMap<String, ClientSeen>>,
    pub hooks: Mutex<Option<SyncReport>>,
    pub boot_id: String,
    pub started_at: DateTime<Utc>,
    pub shutdown: watch::Sender<Option<Shutdown>>,
    /// Serializes writers of `subscriptions.toml`.
    pub subs_write: tokio::sync::Mutex<()>,
    /// Serializes GitHub hook syncs.
    pub hook_lock: tokio::sync::Mutex<()>,
}

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|p| p.into_inner())
}

impl AppState {
    pub fn subs(&self) -> Arc<Subscriptions> {
        self.subs.read().unwrap_or_else(|p| p.into_inner()).clone()
    }

    fn set_subs(&self, s: Subscriptions) {
        *self.subs.write().unwrap_or_else(|p| p.into_inner()) = Arc::new(s);
    }

    fn record(&self, d: Delivery) {
        tracing::info!(delivery = %d.delivery, event = %d.event, outcome = d.outcome, reason = ?d.reason, "webhook");
        *lock(&self.delivery_total) += 1;
        let mut g = lock(&self.deliveries);
        if g.len() >= MAX_DELIVERIES {
            g.pop_front();
        }
        g.push_back(d);
    }

    /// Re-reads `subscriptions.toml` from disk.
    pub async fn reload(self: &Arc<Self>) -> Result<Arc<Subscriptions>, Vec<Issue>> {
        let _w = self.subs_write.lock().await;
        let path = self.cfg.subscriptions_path.clone();
        let subs = tokio::task::spawn_blocking(move || Subscriptions::load(&path))
            .await
            .map_err(|e| vec![Issue::new("reload", e.to_string())])??;
        self.set_subs(subs);
        let s = self.subs();
        self.spawn_hook_sync();
        Ok(s)
    }

    /// Runs hook sync in the background when `auto_sync_hooks` is on.
    fn spawn_hook_sync(self: &Arc<Self>) {
        if !self.cfg.auto_sync_hooks {
            return;
        }
        let me = self.clone();
        tokio::spawn(async move {
            me.sync_hooks_now(false).await;
        });
    }

    /// One hook sync at a time, against the subscriptions current when it starts: two
    /// overlapping syncs would both miss the hook and create duplicates.
    pub async fn sync_hooks_now(&self, dry_run: bool) -> SyncReport {
        let _one = self.hook_lock.lock().await;
        let subs = self.subs();
        let report = github::sync_hooks(&self.cfg, &subs, dry_run).await;
        if !dry_run {
            *lock(&self.hooks) = Some(report.clone());
        }
        report
    }
}

fn err(status: StatusCode, msg: impl Into<String>) -> Response {
    (status, Json(json!({ "error": msg.into() }))).into_response()
}

fn issues(status: StatusCode, list: Vec<Issue>) -> Response {
    (status, Json(json!({ "error": "invalid", "issues": list }))).into_response()
}

pub fn router(state: Arc<AppState>) -> Router {
    let admin = Router::new()
        .route("/status", get(status))
        .route("/subscriptions", get(get_subs).put(put_subs))
        .route("/reload", post(reload))
        .route("/restart", post(restart))
        .route("/github/sync", post(hook_sync))
        .route("/events", get(events))
        .route("/events/test", post(test_event))
        .route("/deliveries", get(deliveries))
        .layer(DefaultBodyLimit::max(ADMIN_BODY_LIMIT))
        .layer(middleware::from_fn_with_state(state.clone(), auth));
    Router::new()
        .route(
            "/hooks/github",
            post(webhook).layer(DefaultBodyLimit::max(state.cfg.max_body_bytes)),
        )
        .route("/healthz", get(healthz))
        .nest("/api/v1", admin)
        .with_state(state)
}

async fn auth(State(st): State<Arc<AppState>>, req: Request, next: Next) -> Response {
    let given = req
        .headers()
        .get("authorization")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .unwrap_or_default();
    // Hash both sides so the comparison is constant-time regardless of length.
    let a = Sha256::digest(given.as_bytes());
    let b = Sha256::digest(st.cfg.admin_token.expose().as_bytes());
    if given.is_empty() || !bool::from(a.ct_eq(&b)) {
        return err(StatusCode::UNAUTHORIZED, "missing or wrong bearer token");
    }
    next.run(req).await
}

async fn healthz(State(st): State<Arc<AppState>>) -> Json<Value> {
    Json(json!({ "ok": true, "boot_id": st.boot_id }))
}

// ---------------------------------------------------------------------------------------------
// Webhook

fn header<'a>(h: &'a HeaderMap, name: &str) -> Option<&'a str> {
    h.get(name).and_then(|v| v.to_str().ok())
}

async fn webhook(State(st): State<Arc<AppState>>, headers: HeaderMap, body: Bytes) -> Response {
    let delivery = header(&headers, "x-github-delivery")
        .unwrap_or_default()
        .chars()
        .take(64)
        .collect::<String>();
    let event = header(&headers, "x-github-event")
        .unwrap_or_default()
        .chars()
        .take(64)
        .collect::<String>();
    let mut d = Delivery {
        delivery: delivery.clone(),
        at: Utc::now(),
        event: event.clone(),
        action: None,
        repo: None,
        outcome: "rejected",
        reason: None,
        seq: None,
    };
    let Some(secret) = &st.cfg.webhook_secret else {
        d.reason = Some("github.webhook_secret is not configured".into());
        st.record(d);
        return err(
            StatusCode::SERVICE_UNAVAILABLE,
            "webhook secret not configured on the agent",
        );
    };
    if !github::verify_signature(
        secret.expose(),
        &body,
        header(&headers, "x-hub-signature-256"),
    ) {
        d.reason = Some("bad or missing X-Hub-Signature-256".into());
        st.record(d);
        return err(StatusCode::UNAUTHORIZED, "bad signature");
    }
    if event.is_empty() || delivery.is_empty() {
        d.reason = Some("missing X-GitHub-Event or X-GitHub-Delivery".into());
        st.record(d);
        return err(StatusCode::BAD_REQUEST, "missing GitHub headers");
    }
    let payload: Value = match serde_json::from_slice(&body) {
        Ok(v) => v,
        Err(e) => {
            d.reason = Some(format!("body is not JSON: {e}"));
            st.record(d);
            return err(StatusCode::BAD_REQUEST, "body is not JSON");
        }
    };
    let info = EventInfo::from_github(&event, &payload);
    d.action = info.action.clone();
    d.repo = info.repo.clone();
    if event == "ping" {
        d.outcome = "ping";
        st.record(d);
        return Json(json!({ "ok": true, "pong": true })).into_response();
    }

    let subs = st.subs();
    let ignore = |d: &mut Delivery, why: String| {
        d.outcome = "ignored";
        d.reason = Some(why);
    };
    match info.repo.as_deref().and_then(|r| subs.repo(r)) {
        None => ignore(&mut d, "repo not subscribed".into()),
        Some((_, sub)) if !sub.events.contains(&event) && !sub.events.contains("*") => {
            ignore(
                &mut d,
                format!("event {event} not subscribed for this repo"),
            );
        }
        Some(_) if st.cfg.ignore_bots && info.sender_is_bot => {
            ignore(&mut d, "sender is a bot (github.ignore_bots)".into());
        }
        Some(_) if st.store.has_delivery(&delivery) => {
            d.outcome = "duplicate";
        }
        Some(_) => {
            let (raw, truncated) = if body.len() <= st.cfg.max_payload_bytes {
                match std::str::from_utf8(&body)
                    .ok()
                    .and_then(|s| RawValue::from_string(s.to_string()).ok())
                {
                    Some(r) => (Some(r), false),
                    None => (None, true),
                }
            } else {
                (None, true)
            };
            match st.store.push(delivery.clone(), info, raw, truncated).await {
                Ok(ev) => {
                    d.outcome = "relayed";
                    d.seq = Some(ev.seq);
                }
                Err(e) => {
                    d.reason = Some(format!("cannot store event: {e}"));
                    st.record(d);
                    // A 5xx makes GitHub show the failure; redeliver from its UI.
                    return err(StatusCode::INTERNAL_SERVER_ERROR, "cannot store event");
                }
            }
        }
    }
    let body = json!({ "outcome": d.outcome, "reason": d.reason, "seq": d.seq });
    let code = if d.outcome == "relayed" {
        StatusCode::ACCEPTED
    } else {
        StatusCode::OK
    };
    st.record(d);
    (code, Json(body)).into_response()
}

// ---------------------------------------------------------------------------------------------
// Admin

async fn status(State(st): State<Arc<AppState>>) -> Json<Value> {
    let subs = st.subs();
    let (head, oldest, count, bytes) = st.store.stats();
    let last = lock(&st.deliveries).back().cloned();
    let clients: Vec<ClientSeen> = lock(&st.clients).values().cloned().collect();
    let hooks = lock(&st.hooks).clone();
    Json(json!({
        "api": 1,
        "version": env!("CARGO_PKG_VERSION"),
        "boot_id": st.boot_id,
        "started_at": st.started_at,
        "now": Utc::now(),
        "config_path": st.cfg.path.display().to_string(),
        "public_url": st.cfg.public_url,
        "webhook_url": st.cfg.webhook_url(),
        "github": {
            "token": st.cfg.github_token.is_some(),
            "webhook_secret": st.cfg.webhook_secret.is_some(),
            "auto_sync_hooks": st.cfg.auto_sync_hooks,
            "ignore_bots": st.cfg.ignore_bots,
        },
        "subscriptions": {
            "revision": subs.revision,
            "repos": subs.repos.len(),
            "path": st.cfg.subscriptions_path.display().to_string(),
        },
        "store": {
            "store_id": st.store.store_id(),
            "head": head,
            "oldest": oldest,
            "count": count,
            "bytes": bytes,
        },
        "deliveries": { "total": *lock(&st.delivery_total), "last": last },
        "clients": clients,
        "hooks": hooks,
    }))
}

async fn get_subs(State(st): State<Arc<AppState>>) -> Json<Value> {
    let s = st.subs();
    Json(json!({ "revision": s.revision, "text": s.text, "repos": s.repos }))
}

#[derive(Deserialize)]
struct PutSubs {
    base_revision: Option<String>,
    repos: BTreeMap<String, RepoSub>,
}

async fn put_subs(State(st): State<Arc<AppState>>, Json(body): Json<PutSubs>) -> Response {
    let _w = st.subs_write.lock().await;
    let cur = st.subs();
    // A hand edit on the server that hasn't been reloaded yet still counts as a server change.
    let path = st.cfg.subscriptions_path.clone();
    let disk = tokio::task::spawn_blocking(move || Subscriptions::load(&path)).await;
    let disk_changed = match &disk {
        Ok(Ok(d)) => d.revision != cur.revision,
        Ok(Err(_)) => true,
        Err(_) => false,
    };
    let stale_base = body
        .base_revision
        .as_ref()
        .is_some_and(|base| base != &cur.revision);
    if body.base_revision.is_some() && (stale_base || disk_changed) {
        let (revision, text) = match &disk {
            Ok(Ok(d)) if disk_changed => (d.revision.clone(), d.text.clone()),
            _ => (cur.revision.clone(), cur.text.clone()),
        };
        return (
            StatusCode::CONFLICT,
            Json(json!({
                "error": if disk_changed {
                    "conflict: subscriptions.toml was edited on the server (not reloaded yet)"
                } else {
                    "conflict: the subscriptions changed on the server since your last push"
                },
                "revision": revision,
                "text": text,
                "unreloaded": disk_changed,
            })),
        )
            .into_response();
    }
    let next = match Subscriptions::from_repos(body.repos) {
        Ok(s) => s,
        Err(list) => return issues(StatusCode::UNPROCESSABLE_ENTITY, list),
    };
    if next.repos == cur.repos {
        return Json(json!({ "revision": cur.revision, "changed": false })).into_response();
    }
    let path = &st.cfg.subscriptions_path;
    if path.exists() {
        let mut bak = path.as_os_str().to_owned();
        bak.push(".bak");
        if let Err(e) = tokio::fs::copy(path, std::path::PathBuf::from(bak)).await {
            tracing::warn!("cannot back up subscriptions: {e}");
        }
    }
    if let Err(e) = crate::util::write_atomic(path, next.text.as_bytes()).await {
        return err(
            StatusCode::INTERNAL_SERVER_ERROR,
            format!("cannot write {}: {e}", path.display()),
        );
    }
    let revision = next.revision.clone();
    st.set_subs(next);
    drop(_w);
    st.spawn_hook_sync();
    Json(json!({
        "revision": revision,
        "changed": true,
        "hook_sync": if st.cfg.auto_sync_hooks { "started" } else { "off" },
    }))
    .into_response()
}

async fn reload(State(st): State<Arc<AppState>>) -> Response {
    match st.reload().await {
        Ok(s) => Json(json!({ "revision": s.revision, "repos": s.repos })).into_response(),
        Err(list) => issues(StatusCode::UNPROCESSABLE_ENTITY, list),
    }
}

#[derive(Deserialize, Default)]
struct RestartBody {
    #[serde(default)]
    stop: bool,
}

async fn restart(State(st): State<Arc<AppState>>, body: Option<Json<RestartBody>>) -> Response {
    let stop = body.map(|b| b.0.stop).unwrap_or(false);
    let kind = if stop {
        Shutdown::Stop
    } else {
        Shutdown::Restart
    };
    tracing::warn!(?kind, "shutdown requested over the admin API");
    // Answer first; the server drains in-flight requests before exiting.
    let tx = st.shutdown.clone();
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_millis(200)).await;
        tx.send_replace(Some(kind));
    });
    (
        StatusCode::ACCEPTED,
        Json(json!({ "ok": true, "boot_id": st.boot_id, "restart": !stop })),
    )
        .into_response()
}

#[derive(Deserialize, Default)]
struct SyncBody {
    #[serde(default)]
    dry_run: bool,
}

async fn hook_sync(State(st): State<Arc<AppState>>, body: Option<Json<SyncBody>>) -> Json<Value> {
    let dry = body.map(|b| b.0.dry_run).unwrap_or(false);
    Json(json!(st.sync_hooks_now(dry).await))
}

#[derive(Deserialize)]
struct EventsQuery {
    after: Option<u64>,
    limit: Option<usize>,
    wait: Option<u64>,
    payload: Option<bool>,
}

#[derive(Serialize)]
struct EventOut<'a> {
    seq: u64,
    delivery: &'a str,
    received_at: DateTime<Utc>,
    event: &'a str,
    repo: Option<&'a str>,
    info: &'a EventInfo,
    #[serde(skip_serializing_if = "Option::is_none")]
    payload: Option<&'a RawValue>,
    payload_truncated: bool,
}

fn event_out(e: &StoredEvent, with_payload: bool) -> EventOut<'_> {
    EventOut {
        seq: e.seq,
        delivery: &e.delivery,
        received_at: e.received_at,
        event: &e.event,
        repo: e.repo.as_deref(),
        info: &e.info,
        payload: if with_payload {
            e.payload.as_deref()
        } else {
            None
        },
        payload_truncated: e.payload_truncated || (!with_payload && e.payload.is_some()),
    }
}

fn client_id(h: &HeaderMap) -> Option<(String, Option<String>)> {
    let id = header(h, "x-roost-client")?;
    let ok = !id.is_empty()
        && id.len() <= 64
        && id
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_' || c == '.');
    if !ok {
        return None;
    }
    let name = header(h, "x-roost-client-name").map(|n| n.chars().take(64).collect());
    Some((id.to_string(), name))
}

async fn events(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Query(q): Query<EventsQuery>,
) -> Response {
    let with_payload = q.payload.unwrap_or(true);
    let limit = q.limit.unwrap_or(50).clamp(1, MAX_PAGE);
    let (head, ..) = st.store.stats();
    // No cursor: start at the head, so a new client doesn't replay history.
    let after = q.after.unwrap_or(head);
    // A cursor past the head belongs to a wiped store: answer at once so the client resets.
    let wait_ok = after <= head;
    if let Some((id, name)) = client_id(&headers) {
        let mut g = lock(&st.clients);
        if !g.contains_key(&id)
            && g.len() >= MAX_CLIENTS
            && let Some(oldest) = g.values().min_by_key(|c| c.last_seen).map(|c| c.id.clone())
        {
            g.remove(&oldest);
        }
        g.insert(
            id.clone(),
            ClientSeen {
                id,
                name,
                last_seen: Utc::now(),
                cursor: after,
            },
        );
    }
    let wait = Duration::from_secs(q.wait.unwrap_or(0)).min(MAX_WAIT);
    if wait_ok && wait > Duration::ZERO && st.store.page(after, 1).events.is_empty() {
        let mut head_rx = st.store.subscribe();
        let mut stop_rx = st.shutdown.subscribe();
        let deadline = tokio::time::Instant::now() + wait;
        loop {
            if *head_rx.borrow_and_update() > after || stop_rx.borrow().is_some() {
                break;
            }
            tokio::select! {
                r = head_rx.changed() => if r.is_err() { break },
                r = stop_rx.changed() => if r.is_err() { break },
                _ = tokio::time::sleep_until(deadline) => break,
            }
        }
    }
    let page = st.store.page(after, limit);
    let list: Vec<EventOut<'_>> = page
        .events
        .iter()
        .map(|e| event_out(e, with_payload))
        .collect();
    Json(json!({
        "store_id": st.store.store_id(),
        "boot_id": st.boot_id,
        "head": page.head,
        "oldest": page.oldest,
        "gap": page.gap,
        "events": list,
    }))
    .into_response()
}

#[derive(Deserialize, Default)]
struct TestBody {
    repo: Option<String>,
}

/// Puts a synthetic `roost_test` event in the store so a client can check the whole relay path.
async fn test_event(State(st): State<Arc<AppState>>, body: Option<Json<TestBody>>) -> Response {
    let subs = st.subs();
    let repo = body
        .and_then(|b| b.0.repo)
        .or_else(|| subs.repos.keys().next().cloned());
    let info = EventInfo {
        event: "roost_test".into(),
        action: Some("ping".into()),
        repo: repo.clone(),
        title: Some("Roost relay test".into()),
        sender: Some("roost-agent".into()),
        ..Default::default()
    };
    let delivery = format!("test-{}", Utc::now().timestamp_millis());
    match st.store.push(delivery.clone(), info, None, false).await {
        Ok(ev) => {
            st.record(Delivery {
                delivery,
                at: Utc::now(),
                event: "roost_test".into(),
                action: Some("ping".into()),
                repo,
                outcome: "relayed",
                reason: Some("synthetic test event".into()),
                seq: Some(ev.seq),
            });
            (StatusCode::ACCEPTED, Json(json!({ "seq": ev.seq }))).into_response()
        }
        Err(e) => err(
            StatusCode::INTERNAL_SERVER_ERROR,
            format!("cannot store: {e}"),
        ),
    }
}

#[derive(Deserialize)]
struct DeliveriesQuery {
    limit: Option<usize>,
}

async fn deliveries(
    State(st): State<Arc<AppState>>,
    Query(q): Query<DeliveriesQuery>,
) -> Json<Value> {
    let limit = q.limit.unwrap_or(50).clamp(1, MAX_DELIVERIES);
    let list: Vec<Delivery> = lock(&st.deliveries)
        .iter()
        .rev()
        .take(limit)
        .cloned()
        .collect();
    Json(json!({ "deliveries": list, "total": *lock(&st.delivery_total) }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::Body;
    use hmac::{Hmac, Mac};
    use http_body_util::BodyExt;
    use tower::ServiceExt;

    const TOKEN: &str = "0123456789abcdef-token";

    fn state(dir: &std::path::Path) -> Arc<AppState> {
        let cfg = AgentConfig::parse(
            &format!(
                "[auth]\ntoken=\"{TOKEN}\"\n[github]\nwebhook_secret=\"hush\"\nauto_sync_hooks=false\n"
            ),
            &dir.join("agent.toml"),
            dir,
        )
        .unwrap();
        let store = EventStore::open(
            cfg.data_dir.clone(),
            crate::store::Limits {
                keep: 100,
                max_age: Duration::from_secs(3600),
                max_total_bytes: 1 << 30,
                max_file_bytes: 1 << 20,
            },
        )
        .unwrap();
        let subs_text = "[repos.\"acme/web\"]\nevents=[\"issues\"]\n";
        std::fs::write(&cfg.subscriptions_path, subs_text).unwrap();
        Arc::new(AppState {
            cfg: Arc::new(cfg),
            subs: RwLock::new(Arc::new(Subscriptions::parse(subs_text).unwrap())),
            store: Arc::new(store),
            deliveries: Mutex::new(VecDeque::new()),
            delivery_total: Mutex::new(0),
            clients: Mutex::new(BTreeMap::new()),
            hooks: Mutex::new(None),
            boot_id: "boot".into(),
            started_at: Utc::now(),
            shutdown: watch::channel(None).0,
            subs_write: tokio::sync::Mutex::new(()),
            hook_lock: tokio::sync::Mutex::new(()),
        })
    }

    fn signed(event: &str, delivery: &str, body: &str, secret: &str) -> Request<Body> {
        let mut mac = Hmac::<Sha256>::new_from_slice(secret.as_bytes()).unwrap();
        mac.update(body.as_bytes());
        let sig = format!("sha256={}", hex::encode(mac.finalize().into_bytes()));
        Request::post("/hooks/github")
            .header("x-github-event", event)
            .header("x-github-delivery", delivery)
            .header("x-hub-signature-256", sig)
            .header("content-type", "application/json")
            .body(Body::from(body.to_string()))
            .unwrap()
    }

    async fn call(app: &Router, req: Request<Body>) -> (StatusCode, Value) {
        let resp = app.clone().oneshot(req).await.unwrap();
        let code = resp.status();
        let bytes = resp.into_body().collect().await.unwrap().to_bytes();
        (code, serde_json::from_slice(&bytes).unwrap_or(Value::Null))
    }

    fn admin(method: &str, uri: &str, body: Option<Value>) -> Request<Body> {
        let b = Request::builder()
            .method(method)
            .uri(uri)
            .header("authorization", format!("Bearer {TOKEN}"))
            .header("x-roost-client", "mac-1");
        match body {
            Some(v) => b
                .header("content-type", "application/json")
                .body(Body::from(v.to_string()))
                .unwrap(),
            None => b.body(Body::empty()).unwrap(),
        }
    }

    const ISSUE: &str = r#"{"action":"opened","repository":{"full_name":"acme/web"},"sender":{"login":"u","type":"User"},"issue":{"number":1,"title":"x","author_association":"OWNER"}}"#;

    #[tokio::test]
    async fn webhook_verifies_filters_dedupes_and_relays() {
        let dir = tempfile::tempdir().unwrap();
        let st = state(dir.path());
        let app = router(st.clone());

        let (c, _) = call(&app, signed("issues", "d1", ISSUE, "wrong")).await;
        assert_eq!(c, StatusCode::UNAUTHORIZED);
        let (c, v) = call(&app, signed("issues", "d1", ISSUE, "hush")).await;
        assert_eq!(c, StatusCode::ACCEPTED, "{v}");
        assert_eq!(v["seq"], 1);
        let (_, v) = call(&app, signed("issues", "d1", ISSUE, "hush")).await;
        assert_eq!(v["outcome"], "duplicate");
        let (_, v) = call(&app, signed("push", "d2", ISSUE, "hush")).await;
        assert_eq!(v["outcome"], "ignored");
        let other = ISSUE.replace("acme/web", "acme/other");
        let (_, v) = call(&app, signed("issues", "d3", &other, "hush")).await;
        assert_eq!(v["reason"], "repo not subscribed");
        let bot = ISSUE.replace("\"User\"", "\"Bot\"");
        let (_, v) = call(&app, signed("issues", "d4", &bot, "hush")).await;
        assert_eq!(v["outcome"], "ignored");
        let (_, v) = call(&app, signed("ping", "d5", "{}", "hush")).await;
        assert_eq!(v["pong"], true);

        let (c, _) = call(
            &app,
            Request::get("/api/v1/events").body(Body::empty()).unwrap(),
        )
        .await;
        assert_eq!(c, StatusCode::UNAUTHORIZED, "admin API needs the token");
        let (c, v) = call(&app, admin("GET", "/api/v1/events?after=0", None)).await;
        assert_eq!(c, StatusCode::OK);
        assert_eq!(v["events"][0]["info"]["number"], 1);
        assert_eq!(v["events"][0]["payload"]["issue"]["title"], "x");
        assert_eq!(v["head"], 1);
        let (_, v) = call(&app, admin("GET", "/api/v1/deliveries", None)).await;
        assert_eq!(v["total"], 7);
        let (_, v) = call(&app, admin("GET", "/api/v1/status", None)).await;
        assert_eq!(v["clients"][0]["id"], "mac-1");
        assert_eq!(v["store"]["head"], 1);
    }

    #[tokio::test]
    async fn long_poll_wakes_on_new_event() {
        let dir = tempfile::tempdir().unwrap();
        let st = state(dir.path());
        let app = router(st.clone());
        let poll = tokio::spawn({
            let app = app.clone();
            async move { call(&app, admin("GET", "/api/v1/events?after=0&wait=10", None)).await }
        });
        tokio::time::sleep(Duration::from_millis(100)).await;
        let t0 = std::time::Instant::now();
        let (c, _) = call(&app, admin("POST", "/api/v1/events/test", Some(json!({})))).await;
        assert_eq!(c, StatusCode::ACCEPTED);
        let (_, v) = poll.await.unwrap();
        assert!(t0.elapsed() < Duration::from_secs(3));
        assert_eq!(v["events"][0]["event"], "roost_test");
        assert_eq!(v["events"][0]["repo"], "acme/web");
        // A cursor from a wiped store (past the head) gets an immediate answer, not a 10 s wait.
        let t0 = std::time::Instant::now();
        let (_, v) = call(&app, admin("GET", "/api/v1/events?after=999&wait=10", None)).await;
        assert!(t0.elapsed() < Duration::from_secs(2));
        assert_eq!(v["head"], 1);
    }

    #[tokio::test]
    async fn subscriptions_push_conflict_validation_and_reload() {
        let dir = tempfile::tempdir().unwrap();
        let st = state(dir.path());
        let app = router(st.clone());
        let (_, cur) = call(&app, admin("GET", "/api/v1/subscriptions", None)).await;
        let rev = cur["revision"].as_str().unwrap().to_string();

        let body = json!({"base_revision": "stale", "repos": {}});
        let (c, _) = call(&app, admin("PUT", "/api/v1/subscriptions", Some(body))).await;
        assert_eq!(c, StatusCode::CONFLICT);

        let body = json!({"base_revision": rev, "repos": {"bad": {"events": ["issues"]}}});
        let (c, v) = call(&app, admin("PUT", "/api/v1/subscriptions", Some(body))).await;
        assert_eq!(c, StatusCode::UNPROCESSABLE_ENTITY);
        assert_eq!(v["issues"][0]["path"], "repos.\"bad\"");

        let body =
            json!({"base_revision": rev, "repos": {"acme/web": {"events": ["issues", "push"]}}});
        let (c, v) = call(&app, admin("PUT", "/api/v1/subscriptions", Some(body))).await;
        assert_eq!(c, StatusCode::OK, "{v}");
        assert_eq!(v["changed"], true);
        let on_disk = std::fs::read_to_string(&st.cfg.subscriptions_path).unwrap();
        assert!(on_disk.contains("push"));

        // A hand edit on the server not reloaded yet: a push based on the old revision conflicts.
        let hand = "[repos.\"acme/api\"]\nevents=[\"release\"]\n";
        std::fs::write(&st.cfg.subscriptions_path, hand).unwrap();
        let (_, cur) = call(&app, admin("GET", "/api/v1/subscriptions", None)).await;
        let body =
            json!({"base_revision": cur["revision"], "repos": {"acme/web": {"events": ["push"]}}});
        let (c, v) = call(&app, admin("PUT", "/api/v1/subscriptions", Some(body))).await;
        assert_eq!(c, StatusCode::CONFLICT, "{v}");
        assert_eq!(v["text"], hand, "conflict carries the server's file");
        // Applied with reload.
        let (c, v) = call(&app, admin("POST", "/api/v1/reload", None)).await;
        assert_eq!(c, StatusCode::OK);
        assert!(v["repos"]["acme/api"].is_object());
        std::fs::write(&st.cfg.subscriptions_path, "[repos.\"x\"]\n").unwrap();
        let (c, _) = call(&app, admin("POST", "/api/v1/reload", None)).await;
        assert_eq!(
            c,
            StatusCode::UNPROCESSABLE_ENTITY,
            "bad file keeps the old subscriptions"
        );
        assert!(st.subs().repos.contains_key("acme/api"));
    }

    #[tokio::test]
    async fn restart_signals_shutdown() {
        let dir = tempfile::tempdir().unwrap();
        let st = state(dir.path());
        let app = router(st.clone());
        let mut rx = st.shutdown.subscribe();
        let (c, v) = call(&app, admin("POST", "/api/v1/restart", None)).await;
        assert_eq!(c, StatusCode::ACCEPTED);
        assert_eq!(v["restart"], true);
        tokio::time::timeout(Duration::from_secs(2), rx.changed())
            .await
            .unwrap()
            .unwrap();
        assert_eq!(*rx.borrow(), Some(Shutdown::Restart));
    }
}
