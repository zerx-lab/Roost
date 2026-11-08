//! HTTP surface: the GitHub webhook endpoint, the GitHub App registration pages, and the
//! bearer-token admin API the plugin uses.

use std::collections::{BTreeMap, VecDeque};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, RwLock};
use std::time::{Duration, Instant};

use axum::body::Bytes;
use axum::extract::{DefaultBodyLimit, Path, Query, Request, State};
use axum::http::{HeaderMap, StatusCode};
use axum::middleware::{self, Next};
use axum::response::{Html, IntoResponse, Redirect, Response};
use axum::routing::{delete, get, post, put};
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
use crate::fleet::{self, Fleet, FleetError};
use crate::github::{self, Failure, Github};
use crate::store::{EventStore, MAX_PAGE, StoredEvent};

const MAX_DELIVERIES: usize = 200;
/// Upper bound on distinct (outcome, event, repo) rows kept in the delivery summary.
const MAX_STAT_KEYS: usize = 256;
const MAX_CLIENTS: usize = 32;
const MAX_WAIT: Duration = Duration::from_secs(30);
const ADMIN_BODY_LIMIT: usize = 1024 * 1024;
/// The configuration upload: up to `fleet::MAX_CONFIG` of text, JSON-escaped.
const CONFIG_BODY_LIMIT: usize = 4 * fleet::MAX_CONFIG;
/// `POST /hooks/dispatch/<id>`: the body (`{ "inputs": {…} }`), runs a workflow may start per
/// minute, and the most inputs and their sizes.
const DISPATCH_BODY_LIMIT: usize = 64 * 1024;
const DISPATCH_PER_MINUTE: u32 = 30;
const MAX_DISPATCH_INPUTS: usize = 32;
const MAX_INPUT_VALUE: usize = 4096;

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

/// One row of the delivery summary: everything since `since` with the same outcome, event, repo.
#[derive(Debug, Clone, Serialize)]
pub struct StatRow {
    pub outcome: &'static str,
    pub event: String,
    pub repo: Option<String>,
    pub count: u64,
    pub first_at: DateTime<Utc>,
    pub last_at: DateTime<Utc>,
    /// Reason of the most recent delivery in this row.
    pub reason: Option<String>,
}

type StatKey = (&'static str, String, Option<String>);

/// Delivery counters since the process started or the last manual clear. `keys` holds at most
/// `MAX_STAT_KEYS` rows; `total` and `by_outcome` are never affected by eviction.
pub struct DeliveryStats {
    since: DateTime<Utc>,
    total: u64,
    by_outcome: BTreeMap<&'static str, u64>,
    keys: BTreeMap<StatKey, StatRow>,
}

impl DeliveryStats {
    pub fn new(since: DateTime<Utc>) -> Self {
        DeliveryStats {
            since,
            total: 0,
            by_outcome: BTreeMap::new(),
            keys: BTreeMap::new(),
        }
    }

    fn add(&mut self, d: &Delivery) {
        self.total += 1;
        *self.by_outcome.entry(d.outcome).or_insert(0) += 1;
        // A rejected delivery failed verification, so its event header is anyone's choice: they
        // share one row, and a flood of made-up names can't push real rows out of the table.
        let (event, repo) = if d.outcome == "rejected" {
            (String::new(), None)
        } else {
            (d.event.clone(), d.repo.clone())
        };
        let key: StatKey = (d.outcome, event.clone(), repo.clone());
        if let Some(row) = self.keys.get_mut(&key) {
            row.count += 1;
            row.last_at = d.at;
            row.reason = d.reason.clone();
            return;
        }
        if self.keys.len() >= MAX_STAT_KEYS {
            let oldest = self
                .keys
                .iter()
                .min_by_key(|(_, r)| r.last_at)
                .map(|(k, _)| k.clone());
            if let Some(k) = oldest {
                self.keys.remove(&k);
            }
        }
        self.keys.insert(
            key,
            StatRow {
                outcome: d.outcome,
                event,
                repo,
                count: 1,
                first_at: d.at,
                last_at: d.at,
                reason: d.reason.clone(),
            },
        );
    }

    fn reset(&mut self, since: DateTime<Utc>) {
        *self = DeliveryStats::new(since);
    }

    /// Rows by count descending, then most recently seen first.
    fn summary(&self) -> Vec<StatRow> {
        let mut rows: Vec<StatRow> = self.keys.values().cloned().collect();
        rows.sort_by(|a, b| {
            b.count
                .cmp(&a.count)
                .then_with(|| b.last_at.cmp(&a.last_at))
        });
        rows
    }
}

pub struct AppState {
    pub cfg: Arc<AgentConfig>,
    pub subs: RwLock<Arc<Subscriptions>>,
    pub store: Arc<EventStore>,
    pub gh: Arc<Github>,
    pub deliveries: Mutex<VecDeque<Delivery>>,
    /// Lock order: `delivery_stats` before `deliveries`.
    pub delivery_stats: Mutex<DeliveryStats>,
    pub clients: Mutex<BTreeMap<String, ClientSeen>>,
    /// Which device runs which workflow, the shared configuration and each device's runs.
    pub fleet: Arc<Fleet>,
    pub boot_id: String,
    pub started_at: DateTime<Utc>,
    pub shutdown: watch::Sender<Option<Shutdown>>,
    /// Serializes writers of `subscriptions.toml`.
    pub subs_write: tokio::sync::Mutex<()>,
    /// Starts per dispatchable workflow in the current minute (`POST /hooks/dispatch/<id>`);
    /// only ids in the subscriptions get an entry, so it stays as small as that list.
    pub dispatch_hits: Mutex<BTreeMap<String, (Instant, u32)>>,
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
        let mut stats = lock(&self.delivery_stats);
        stats.add(&d);
        let mut g = lock(&self.deliveries);
        if g.len() >= MAX_DELIVERIES {
            g.pop_front();
        }
        g.push_back(d);
    }

    /// Forgets the recent deliveries and all counters; counting restarts now.
    fn clear_deliveries(&self) {
        let mut stats = lock(&self.delivery_stats);
        stats.reset(Utc::now());
        lock(&self.deliveries).clear();
    }

    /// Re-reads `subscriptions.toml` from disk.
    pub async fn reload(self: &Arc<Self>) -> Result<Arc<Subscriptions>, Vec<Issue>> {
        let _w = self.subs_write.lock().await;
        let path = self.cfg.subscriptions_path.clone();
        let subs = tokio::task::spawn_blocking(move || Subscriptions::load(&path))
            .await
            .map_err(|e| vec![Issue::new("reload", e.to_string())])??;
        self.set_subs(subs);
        Ok(self.subs())
    }
}

fn err(status: StatusCode, msg: impl Into<String>) -> Response {
    (status, Json(json!({ "error": msg.into() }))).into_response()
}

fn issues(status: StatusCode, list: Vec<Issue>) -> Response {
    (status, Json(json!({ "error": "invalid", "issues": list }))).into_response()
}

fn failure(f: Failure) -> Response {
    let code = StatusCode::from_u16(f.status).unwrap_or(StatusCode::BAD_GATEWAY);
    err(code, f.message)
}

pub fn router(state: Arc<AppState>) -> Router {
    let admin = Router::new()
        .route("/status", get(status))
        .route("/subscriptions", get(get_subs).put(put_subs))
        .route("/reload", post(reload))
        .route("/restart", post(restart))
        .route("/github/app", delete(app_forget))
        .route("/github/app/manifest", post(app_manifest))
        .route("/github/token", post(gh_token))
        .route("/github/{what}", get(gh_list))
        .route("/events", get(events).delete(clear_events))
        .route("/events/test", post(test_event))
        .route("/deliveries", get(deliveries).delete(clear_deliveries))
        .route("/fleet/executor", put(put_executor))
        .route("/fleet/assign", put(put_assign))
        .route(
            "/fleet/config",
            get(get_config)
                .put(put_config)
                .layer(DefaultBodyLimit::max(CONFIG_BODY_LIMIT)),
        )
        .route("/fleet/runs", put(put_runs))
        .route("/fleet/runs/{client}", get(get_runs))
        .route("/fleet/run", post(post_run))
        .layer(DefaultBodyLimit::max(ADMIN_BODY_LIMIT))
        .layer(middleware::from_fn_with_state(state.clone(), auth));
    Router::new()
        .route(
            "/hooks/github",
            post(webhook).layer(DefaultBodyLimit::max(state.cfg.max_body_bytes)),
        )
        .route("/github/app/new", get(app_page))
        .route("/github/app/callback", get(app_callback))
        .route("/github/app/installed", get(app_installed))
        .route("/healthz", get(healthz))
        .route(
            "/hooks/dispatch/{id}",
            post(dispatch).layer(DefaultBodyLimit::max(DISPATCH_BODY_LIMIT)),
        )
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

#[derive(Deserialize, Default)]
#[serde(deny_unknown_fields)]
struct DispatchBody {
    #[serde(default)]
    inputs: BTreeMap<String, String>,
}

fn valid_input_name(k: &str) -> bool {
    !k.is_empty()
        && k.len() <= 64
        && k.chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
}

/// Starts workflow `id` from outside: the bearer token's SHA-256 must be the one the plugin pushed
/// for it (subscriptions `dispatch`). Unknown ids and wrong tokens get the same answer. The run
/// reaches the devices as a `roost_dispatch` event; the plugin checks the inputs again.
async fn dispatch(
    State(st): State<Arc<AppState>>,
    Path(id): Path<String>,
    headers: HeaderMap,
    body: Option<Json<DispatchBody>>,
) -> Response {
    let subs = st.subs();
    let given = headers
        .get("authorization")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .unwrap_or_default();
    let got = hex::encode(Sha256::digest(given.as_bytes()));
    let ok = match subs.dispatch.get(&id) {
        Some(want) => !given.is_empty() && bool::from(got.as_bytes().ct_eq(want.as_bytes())),
        None => false,
    };
    if !ok {
        return err(StatusCode::UNAUTHORIZED, "unknown workflow or wrong token");
    }
    let inputs = body.map(|b| b.0.inputs).unwrap_or_default();
    if inputs.len() > MAX_DISPATCH_INPUTS
        || inputs
            .iter()
            .any(|(k, v)| !valid_input_name(k) || v.len() > MAX_INPUT_VALUE)
    {
        return err(
            StatusCode::UNPROCESSABLE_ENTITY,
            format!(
                "at most {MAX_DISPATCH_INPUTS} inputs, names [A-Za-z0-9_-]{{1,64}}, values up to {MAX_INPUT_VALUE} bytes"
            ),
        );
    }
    {
        let mut hits = lock(&st.dispatch_hits);
        hits.retain(|k, _| subs.dispatch.contains_key(k));
        let now = Instant::now();
        let slot = hits.entry(id.clone()).or_insert((now, 0));
        if now.duration_since(slot.0) >= Duration::from_secs(60) {
            *slot = (now, 0);
        }
        if slot.1 >= DISPATCH_PER_MINUTE {
            return err(
                StatusCode::TOO_MANY_REQUESTS,
                format!("at most {DISPATCH_PER_MINUTE} starts a minute"),
            );
        }
        slot.1 += 1;
    }
    let payload = match serde_json::to_string(&json!({ "workflow": id, "inputs": inputs }))
        .ok()
        .and_then(|s| RawValue::from_string(s).ok())
    {
        Some(p) => p,
        None => {
            return err(
                StatusCode::INTERNAL_SERVER_ERROR,
                "cannot encode the request",
            );
        }
    };
    let info = EventInfo {
        event: "roost_dispatch".into(),
        action: Some("dispatch".into()),
        title: Some(id.clone()),
        sender: Some("api".into()),
        ..Default::default()
    };
    // Unique even for calls in the same millisecond: clients skip a delivery id they have seen.
    static DISPATCH_SEQ: AtomicU64 = AtomicU64::new(0);
    let delivery = format!(
        "dispatch-{}-{}-{}",
        id,
        Utc::now().timestamp_millis(),
        DISPATCH_SEQ.fetch_add(1, Ordering::Relaxed)
    );
    match st
        .store
        .push(delivery.clone(), info, Some(payload), false)
        .await
    {
        Ok(ev) => {
            st.record(Delivery {
                delivery,
                at: Utc::now(),
                event: "roost_dispatch".into(),
                action: Some("dispatch".into()),
                repo: None,
                outcome: "relayed",
                reason: Some(format!("workflow {id}")),
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
    let Some(secret) = st.gh.webhook_secret() else {
        d.reason = Some("no GitHub App yet".into());
        st.record(d);
        return err(
            StatusCode::SERVICE_UNAVAILABLE,
            "GitHub App not created on this agent yet",
        );
    };
    if !github::verify_signature(&secret, &body, header(&headers, "x-hub-signature-256")) {
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
    if event == "installation" || event == "installation_repositories" {
        // Repos were added to or removed from the App: look installations up again.
        st.gh.forget_installs();
    }

    let subs = st.subs();
    let ignore = |d: &mut Delivery, why: String| {
        d.outcome = "ignored";
        d.reason = Some(why);
    };
    match info.repo.as_deref() {
        None => ignore(&mut d, "not about a repository".into()),
        Some(r) if !subs.wants(r, &event) => {
            ignore(&mut d, format!("{event} not subscribed for {r}"));
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
    let app = st.gh.info().await;
    let (total, since) = {
        let s = lock(&st.delivery_stats);
        (s.total, s.since)
    };
    Json(json!({
        "api": 3,
        "version": env!("CARGO_PKG_VERSION"),
        "boot_id": st.boot_id,
        "started_at": st.started_at,
        "now": Utc::now(),
        "config_path": st.cfg.path.display().to_string(),
        "public_url": st.cfg.public_url,
        "webhook_url": st.cfg.webhook_url(),
        "github": {
            "app": app,
            "events": github::APP_EVENTS,
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
        "deliveries": { "total": total, "since": since, "last": last },
        "clients": clients,
        "fleet": st.fleet.state(),
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
    #[serde(default)]
    dispatch: BTreeMap<String, String>,
}

async fn put_subs(State(st): State<Arc<AppState>>, Json(body): Json<PutSubs>) -> Response {
    if let Some(denied) = fleet_usable(&st) {
        return denied;
    }
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
    let next = match Subscriptions::from_parts(body.repos, body.dispatch) {
        Ok(s) => s,
        Err(list) => return issues(StatusCode::UNPROCESSABLE_ENTITY, list),
    };
    // What the relay already runs is accepted whatever base it comes with: devices on the same
    // configuration push the same subscriptions.
    if !disk_changed && next.repos == cur.repos && next.dispatch == cur.dispatch {
        return Json(json!({ "revision": cur.revision, "changed": false })).into_response();
    }
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
    Json(json!({ "revision": revision, "changed": true })).into_response()
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

// ---------------------------------------------------------------------------------------------
// GitHub App

#[derive(Deserialize, Default)]
struct ManifestBody {
    org: Option<String>,
    name: Option<String>,
}

/// Starts registering the App: the page the user opens to post the manifest to GitHub.
async fn app_manifest(
    State(st): State<Arc<AppState>>,
    body: Option<Json<ManifestBody>>,
) -> Response {
    let b = body.map(|b| b.0).unwrap_or_default();
    match st.gh.begin(b.org, b.name) {
        Ok(url) => Json(json!({ "url": url })).into_response(),
        Err(f) => failure(f),
    }
}

#[derive(Deserialize)]
struct StateQuery {
    state: Option<String>,
    code: Option<String>,
}

fn html(status: StatusCode, title: &str, body: &str) -> Response {
    (status, Html(github::page(title, body))).into_response()
}

async fn app_page(State(st): State<Arc<AppState>>, Query(q): Query<StateQuery>) -> Response {
    match q.state.as_deref().and_then(|s| st.gh.manifest_page(s)) {
        Some(page) => (StatusCode::OK, Html(page)).into_response(),
        None => html(
            StatusCode::NOT_FOUND,
            "链接已失效",
            "<p>这个创建链接不存在或已过期,请回到 Roost 的「中继」页重新创建 GitHub App。</p>",
        ),
    }
}

/// GitHub's redirect after the App was created: keep its credentials, then go install it.
async fn app_callback(State(st): State<Arc<AppState>>, Query(q): Query<StateQuery>) -> Response {
    let (Some(code), Some(state)) = (q.code, q.state) else {
        return html(
            StatusCode::BAD_REQUEST,
            "创建失败",
            "<p>GitHub 回调缺少 code 或 state。</p>",
        );
    };
    match st.gh.finish(&code, &state).await {
        Ok(install) => Redirect::to(&install).into_response(),
        Err(f) => {
            tracing::warn!("GitHub App registration failed: {}", f.message);
            html(
                StatusCode::from_u16(f.status).unwrap_or(StatusCode::BAD_GATEWAY),
                "创建失败",
                "<p>没能完成 GitHub App 的创建,详情见 roost-agent 日志。回到 Roost 重新创建即可。</p>",
            )
        }
    }
}

async fn app_installed() -> Response {
    html(
        StatusCode::OK,
        "GitHub App 已安装",
        "<p>安装完成。回到 Roost 即可在工作流的仓库筛选中选到这些仓库;以后要增减仓库,在 GitHub 的 App 安装设置里修改。</p>",
    )
}

async fn app_forget(State(st): State<Arc<AppState>>) -> Response {
    match st.gh.forget().await {
        Ok(had) => Json(json!({ "ok": true, "deleted": had })).into_response(),
        Err(f) => failure(f),
    }
}

#[derive(Deserialize)]
struct ListQuery {
    repo: Option<String>,
}

/// Editor suggestions: `repos`, or per repo `people` / `labels` / `branches` / `workflows`.
async fn gh_list(
    State(st): State<Arc<AppState>>,
    Path(what): Path<String>,
    Query(q): Query<ListQuery>,
) -> Response {
    match st.gh.list(&what, q.repo.as_deref()).await {
        Ok(items) => Json(json!({ "items": items })).into_response(),
        Err(f) => failure(f),
    }
}

#[derive(Deserialize)]
struct TokenBody {
    repo: String,
}

/// A token for one run on `repo`, acting as the App (see `Github::app_token`).
async fn gh_token(State(st): State<Arc<AppState>>, Json(b): Json<TokenBody>) -> Response {
    if let Some(denied) = fleet_usable(&st) {
        return denied;
    }
    match st.gh.app_token(&b.repo).await {
        Ok(t) => {
            tracing::info!(repo = %t.repository, protection = t.protection, "issued an App token");
            Json(t).into_response()
        }
        Err(f) => failure(f),
    }
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

fn valid_client(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 64
        && id
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_' || c == '.')
}

fn client_id(h: &HeaderMap) -> Option<(String, Option<String>)> {
    let id = header(h, "x-roost-client")?;
    if !valid_client(id) {
        return None;
    }
    let name = header(h, "x-roost-client-name").map(|n| n.chars().take(64).collect());
    Some((id.to_string(), name))
}

/// Refuses what a device does on its own behalf while the device record is unreadable (nobody
/// knows what is whose then).
fn fleet_usable(st: &AppState) -> Option<Response> {
    if st.fleet.usable() {
        None
    } else {
        Some(fleet_failure(FleetError::Broken, st))
    }
}

fn fleet_failure(e: FleetError, st: &AppState) -> Response {
    match e {
        FleetError::Broken => (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(json!({
                "error": "the relay cannot read its device record: assign the default device again",
                "code": "fleet_broken",
                "fleet": st.fleet.state(),
            })),
        )
            .into_response(),
        FleetError::Conflict(s) => (
            StatusCode::CONFLICT,
            Json(json!({
                "error": "the device assignments changed since you looked",
                "code": "fleet_conflict",
                "fleet": s,
            })),
        )
            .into_response(),
        FleetError::ConfigConflict(cur) => (
            StatusCode::CONFLICT,
            Json(json!({
                "error": "the configuration changed since you last had it",
                "code": "config_conflict",
                "config": cur,
            })),
        )
            .into_response(),
        FleetError::TooLarge(n) => err(
            StatusCode::PAYLOAD_TOO_LARGE,
            format!("larger than {n} bytes"),
        ),
        FleetError::TooMany(n) => err(
            StatusCode::PAYLOAD_TOO_LARGE,
            format!("at most {n} workflows can have a device of their own"),
        ),
        FleetError::Io(m) => err(StatusCode::INTERNAL_SERVER_ERROR, m),
    }
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
    let client = client_id(&headers);
    if let Some((id, name)) = client.clone() {
        let mut g = lock(&st.clients);
        if !g.contains_key(&id)
            && g.len() >= MAX_CLIENTS
            && let Some(oldest) = g.values().min_by_key(|c| c.last_seen).map(|c| c.id.clone())
        {
            g.remove(&oldest);
        }
        // History reads (`payload=false`) start before the client's cursor: keep its poll's.
        let cursor = match (q.payload, g.get(&id)) {
            (Some(false), Some(prev)) => prev.cursor,
            _ => after,
        };
        g.insert(
            id.clone(),
            ClientSeen {
                id,
                name,
                last_seen: Utc::now(),
                cursor,
            },
        );
    }
    let wait = Duration::from_secs(q.wait.unwrap_or(0)).min(MAX_WAIT);
    // Subscribed before looking, so a change in between still ends the wait.
    let mut fleet_rx = st.fleet.subscribe();
    fleet_rx.borrow_and_update();
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
                _ = fleet_rx.changed() => break,
                _ = tokio::time::sleep_until(deadline) => break,
            }
        }
    }
    let page = st.store.page(after, limit);
    let fleet = st.fleet.state();
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
        "fleet": fleet,
    }))
    .into_response()
}

// ---------------------------------------------------------------------------------------------
// Devices: who runs what, the shared configuration, each device's runs

#[derive(Deserialize)]
struct ExecutorBody {
    client: Option<String>,
    base_revision: u64,
}

#[derive(Deserialize)]
struct AssignBody {
    workflow: String,
    client: Option<String>,
    base_revision: u64,
}

fn valid_workflow(id: &str) -> bool {
    id != fleet::DEFAULT && valid_client(id)
}

/// A device's name, when the relay has heard from it since it started or has it on record.
/// `Err`: neither (or not a client id), with the answer to give.
fn device_name(st: &AppState, client: &str) -> Result<Option<String>, (StatusCode, &'static str)> {
    if !valid_client(client) {
        return Err((StatusCode::BAD_REQUEST, "invalid client id"));
    }
    if let Some(seen) = lock(&st.clients).get(client) {
        return Ok(seen.name.clone());
    }
    st.fleet.known(client).ok_or((
        StatusCode::NOT_FOUND,
        "the relay hasn't heard from that client since it started",
    ))
}

/// Assigns `key` from the events after the current head on (compare-and-set on the revision).
async fn assign(st: &AppState, key: &str, client: Option<String>, base: u64) -> Response {
    let name = match client.as_deref().map(|c| device_name(st, c)) {
        Some(Err((code, msg))) => return err(code, msg),
        Some(Ok(n)) => n,
        None => None,
    };
    match st
        .fleet
        .assign(key, client.as_deref(), name, base, || {
            let (head, oldest, ..) = st.store.stats();
            (head, oldest)
        })
        .await
    {
        Ok(s) => Json(json!({ "fleet": s })).into_response(),
        Err(e) => fleet_failure(e, st),
    }
}

/// Makes a device the default one (none: every device runs every workflow not assigned elsewhere).
async fn put_executor(State(st): State<Arc<AppState>>, Json(b): Json<ExecutorBody>) -> Response {
    assign(&st, fleet::DEFAULT, b.client, b.base_revision).await
}

/// Gives one workflow to a device (none: it follows the default device again).
async fn put_assign(State(st): State<Arc<AppState>>, Json(b): Json<AssignBody>) -> Response {
    if !valid_workflow(&b.workflow) {
        return err(StatusCode::BAD_REQUEST, "invalid workflow id");
    }
    assign(&st, &b.workflow, b.client, b.base_revision).await
}

#[derive(Deserialize)]
struct HaveQuery {
    have: Option<String>,
}

async fn get_config(State(st): State<Arc<AppState>>, Query(q): Query<HaveQuery>) -> Response {
    let (meta, text) = st.fleet.config();
    match (meta, text) {
        (Some(m), Some(t)) if q.have.as_deref() != Some(m.revision.as_str()) => {
            Json(json!({ "config": m, "text": &*t })).into_response()
        }
        (m, _) => Json(json!({ "config": m, "unchanged": true })).into_response(),
    }
}

#[derive(Deserialize)]
struct ConfigBody {
    text: String,
    /// The revision the uploader last had (none: it never had one).
    #[serde(default)]
    base: Option<String>,
}

async fn put_config(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(b): Json<ConfigBody>,
) -> Response {
    let Some((id, _)) = client_id(&headers) else {
        return err(StatusCode::BAD_REQUEST, "X-Roost-Client is required");
    };
    match st.fleet.put_config(&id, b.text, b.base.as_deref()).await {
        Ok(m) => Json(json!({ "config": m })).into_response(),
        Err(e) => fleet_failure(e, &st),
    }
}

async fn get_runs(
    State(st): State<Arc<AppState>>,
    Path(client): Path<String>,
    Query(q): Query<HaveQuery>,
) -> Response {
    let (meta, body) = st.fleet.runs(&client);
    match (meta, body) {
        (Some(m), Some(b)) if q.have.as_deref() != Some(m.revision.as_str()) => {
            Json(json!({ "runs": m, "body": &*b })).into_response()
        }
        (m, _) => Json(json!({ "runs": m, "unchanged": true })).into_response(),
    }
}

async fn put_runs(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(b): Json<Box<RawValue>>,
) -> Response {
    let Some((id, _)) = client_id(&headers) else {
        return err(StatusCode::BAD_REQUEST, "X-Roost-Client is required");
    };
    match st.fleet.put_runs(&id, b).await {
        Ok(m) => Json(json!({ "runs": m })).into_response(),
        Err(e) => fleet_failure(e, &st),
    }
}

#[derive(Deserialize)]
struct RunBody {
    workflow: String,
    /// The device that is to run it.
    target: String,
    #[serde(default)]
    inputs: BTreeMap<String, String>,
    /// The pull request to run on, as typed (`owner/name#12`, a link or a number).
    #[serde(default)]
    pr: Option<String>,
}

/// A manual run asked for on one device for another: stored as a `roost_run` event naming its
/// target, which runs it when it reads the event (later, if it is offline now).
async fn post_run(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(b): Json<RunBody>,
) -> Response {
    if let Some(denied) = fleet_usable(&st) {
        return denied;
    }
    let Some((from, from_name)) = client_id(&headers) else {
        return err(StatusCode::BAD_REQUEST, "X-Roost-Client is required");
    };
    if !valid_workflow(&b.workflow) || !valid_client(&b.target) {
        return err(StatusCode::BAD_REQUEST, "invalid workflow or device id");
    }
    if b.pr.as_ref().is_some_and(|p| p.len() > 300)
        || b.inputs.len() > MAX_DISPATCH_INPUTS
        || b.inputs
            .iter()
            .any(|(k, v)| !valid_input_name(k) || v.len() > MAX_INPUT_VALUE)
    {
        return err(
            StatusCode::UNPROCESSABLE_ENTITY,
            format!(
                "at most {MAX_DISPATCH_INPUTS} inputs, names [A-Za-z0-9_-]{{1,64}}, values up to {MAX_INPUT_VALUE} bytes"
            ),
        );
    }
    let payload = match serde_json::to_string(&json!({
        "workflow": b.workflow,
        "target": b.target,
        "inputs": b.inputs,
        "pr": b.pr,
        "from": from,
        "from_name": from_name,
    }))
    .ok()
    .and_then(|s| RawValue::from_string(s).ok())
    {
        Some(p) => p,
        None => {
            return err(
                StatusCode::INTERNAL_SERVER_ERROR,
                "cannot encode the request",
            );
        }
    };
    let info = EventInfo {
        event: "roost_run".into(),
        action: Some("run".into()),
        title: Some(b.workflow.clone()),
        sender: Some("device".into()),
        ..Default::default()
    };
    static RUN_SEQ: AtomicU64 = AtomicU64::new(0);
    let delivery = format!(
        "run-{}-{}-{}",
        b.workflow,
        Utc::now().timestamp_millis(),
        RUN_SEQ.fetch_add(1, Ordering::Relaxed)
    );
    match st.store.push(delivery, info, Some(payload), false).await {
        Ok(ev) => (StatusCode::ACCEPTED, Json(json!({ "seq": ev.seq }))).into_response(),
        Err(e) => err(
            StatusCode::INTERNAL_SERVER_ERROR,
            format!("cannot store: {e}"),
        ),
    }
}

#[derive(Deserialize, Default)]
struct TestBody {
    repo: Option<String>,
}

/// Puts a synthetic `roost_test` event in the store so a client can check the whole relay path.
async fn test_event(State(st): State<Arc<AppState>>, body: Option<Json<TestBody>>) -> Response {
    let subs = st.subs();
    let repo = body.and_then(|b| b.0.repo).or_else(|| subs.first_repo());
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
    // Same lock order as `record`, so the list and the counters describe one moment.
    let stats = lock(&st.delivery_stats);
    let list: Vec<Delivery> = lock(&st.deliveries)
        .iter()
        .rev()
        .take(limit)
        .cloned()
        .collect();
    Json(json!({
        "deliveries": list,
        "total": stats.total,
        "since": stats.since,
        "by_outcome": stats.by_outcome,
        "summary": stats.summary(),
    }))
}

/// Forgets the recent deliveries and every counter; `since` becomes now.
async fn clear_deliveries(State(st): State<Arc<AppState>>) -> Json<Value> {
    st.clear_deliveries();
    Json(json!({ "ok": true }))
}

/// Deletes every retained event. Sequence numbers and the store id are kept, so client cursors
/// stay valid and a client behind the head sees a gap.
async fn clear_events(State(st): State<Arc<AppState>>) -> Response {
    match st.store.clear().await {
        Ok((removed, head)) => {
            Json(json!({ "ok": true, "removed": removed, "head": head })).into_response()
        }
        Err(e) => err(
            StatusCode::INTERNAL_SERVER_ERROR,
            format!("cannot clear events: {e}"),
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::Body;
    use hmac::{Hmac, Mac};
    use http_body_util::BodyExt;
    use tower::ServiceExt;

    const TOKEN: &str = "0123456789abcdef-token";

    /// An agent with a GitHub App whose webhook secret is "hush"; `api` points the App's GitHub
    /// calls at a fake server.
    fn state(dir: &std::path::Path) -> Arc<AppState> {
        // Nothing listens on port 9: App calls fail at once instead of reaching GitHub.
        state_with(dir, Some("http://127.0.0.1:9"), true)
    }

    fn state_with(dir: &std::path::Path, api: Option<&str>, with_app: bool) -> Arc<AppState> {
        let api_line = api
            .map(|a| format!("api_url=\"{a}\"\n"))
            .unwrap_or_default();
        let cfg = AgentConfig::parse(
            &format!(
                "[auth]\ntoken=\"{TOKEN}\"\n[server]\npublic_url=\"https://r.dev\"\n[github]\n{api_line}"
            ),
            &dir.join("agent.toml"),
            dir,
        )
        .unwrap();
        if with_app {
            let (pem, _) = github::tests::test_key();
            let file = github::tests::test_file(&pem, "hush");
            std::fs::create_dir_all(cfg.app_path.parent().unwrap()).unwrap();
            std::fs::write(&cfg.app_path, serde_json::to_vec(&file).unwrap()).unwrap();
        }
        let gh = Arc::new(Github::new(&cfg).unwrap());
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
        let fleet = Fleet::open(dir.to_path_buf(), store.store_id());
        let subs_text = "[repos.\"acme/web\"]\nevents=[\"issues\"]\n";
        std::fs::write(&cfg.subscriptions_path, subs_text).unwrap();
        Arc::new(AppState {
            cfg: Arc::new(cfg),
            subs: RwLock::new(Arc::new(Subscriptions::parse(subs_text).unwrap())),
            store: Arc::new(store),
            gh,
            deliveries: Mutex::new(VecDeque::new()),
            delivery_stats: Mutex::new(DeliveryStats::new(Utc::now())),
            clients: Mutex::new(BTreeMap::new()),
            fleet: Arc::new(fleet),
            boot_id: "boot".into(),
            started_at: Utc::now(),
            shutdown: watch::channel(None).0,
            subs_write: tokio::sync::Mutex::new(()),
            dispatch_hits: Mutex::new(BTreeMap::new()),
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
        assert_eq!(v["reason"], "issues not subscribed for acme/other");
        // Bots are relayed: whether they fire is each trigger's choice (ignore_bots).
        let bot = ISSUE.replace("\"User\"", "\"Bot\"");
        let (_, v) = call(&app, signed("issues", "d4", &bot, "hush")).await;
        assert_eq!(v["outcome"], "relayed");
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
        assert_eq!(v["head"], 2, "the issue and the bot's");
        let (_, v) = call(&app, admin("GET", "/api/v1/deliveries", None)).await;
        assert_eq!(v["total"], 7);
        let (_, v) = call(&app, admin("GET", "/api/v1/status", None)).await;
        assert_eq!(v["clients"][0]["id"], "mac-1");
        assert_eq!(v["store"]["head"], 2);
        assert_eq!(v["github"]["app"]["slug"], "roost-test");
        assert_eq!(
            v["github"]["app"]["installations"],
            Value::Null,
            "GitHub unreachable"
        );
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
    async fn dispatch_needs_the_workflows_token_is_rate_limited_and_relays() {
        let dir = tempfile::tempdir().unwrap();
        let st = state(dir.path());
        let app = router(st.clone());
        let token = "t0ken-for-nightly";
        let hash = hex::encode(Sha256::digest(token.as_bytes()));
        let (_, cur) = call(&app, admin("GET", "/api/v1/subscriptions", None)).await;
        let bad = json!({"base_revision": cur["revision"], "repos": {}, "dispatch": {"nightly": "nothex"}});
        let (c, _) = call(&app, admin("PUT", "/api/v1/subscriptions", Some(bad))).await;
        assert_eq!(
            c,
            StatusCode::UNPROCESSABLE_ENTITY,
            "a hash must be a SHA-256"
        );
        let body =
            json!({"base_revision": cur["revision"], "repos": {}, "dispatch": {"nightly": hash}});
        let (c, v) = call(&app, admin("PUT", "/api/v1/subscriptions", Some(body))).await;
        assert_eq!(c, StatusCode::OK, "{v}");
        let on_disk = std::fs::read_to_string(&st.cfg.subscriptions_path).unwrap();
        assert!(
            on_disk.contains(&hash) && !on_disk.contains(token),
            "only the hash is kept"
        );

        let post = |id: &str, tok: Option<&str>, body: &str| {
            let mut b = Request::post(format!("/hooks/dispatch/{id}"))
                .header("content-type", "application/json");
            if let Some(t) = tok {
                b = b.header("authorization", format!("Bearer {t}"));
            }
            b.body(Body::from(body.to_string())).unwrap()
        };
        let (c, _) = call(&app, post("nightly", Some("wrong"), "{}")).await;
        assert_eq!(c, StatusCode::UNAUTHORIZED);
        let (c, _) = call(&app, post("nightly", None, "{}")).await;
        assert_eq!(c, StatusCode::UNAUTHORIZED);
        let (c, _) = call(&app, post("other", Some(token), "{}")).await;
        assert_eq!(
            c,
            StatusCode::UNAUTHORIZED,
            "unknown ids answer like wrong tokens"
        );
        let (c, _) = call(
            &app,
            post("nightly", Some(token), r#"{"inputs":{"bad name":"x"}}"#),
        )
        .await;
        assert_eq!(c, StatusCode::UNPROCESSABLE_ENTITY);
        let (c, v) = call(
            &app,
            post("nightly", Some(token), r#"{"inputs":{"focus":"docs"}}"#),
        )
        .await;
        assert_eq!(c, StatusCode::ACCEPTED, "{v}");
        let (_, v) = call(&app, admin("GET", "/api/v1/events?after=0", None)).await;
        assert_eq!(v["events"][0]["event"], "roost_dispatch");
        assert_eq!(v["events"][0]["payload"]["workflow"], "nightly");
        assert_eq!(v["events"][0]["payload"]["inputs"]["focus"], "docs");
        for _ in 1..DISPATCH_PER_MINUTE {
            let (c, _) = call(&app, post("nightly", Some(token), "{}")).await;
            assert_eq!(c, StatusCode::ACCEPTED);
        }
        let (c, _) = call(&app, post("nightly", Some(token), "{}")).await;
        assert_eq!(c, StatusCode::TOO_MANY_REQUESTS);
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

    /// A fake GitHub API: the manifest conversion and what the editor lists use.
    async fn fake_github(pem: String) -> String {
        use axum::extract::Path as P;
        let pem = Arc::new(pem);
        let gh = Router::new()
            .route(
                "/app-manifests/{code}/conversions",
                post(move |P(code): P<String>| {
                    let pem = pem.clone();
                    async move {
                        assert_eq!(code, "abc123");
                        Json(json!({
                            "id": 9, "slug": "roost-x", "name": "Roost x",
                            "owner": { "login": "zero", "type": "User" },
                            "html_url": "https://github.com/apps/roost-x",
                            "webhook_secret": "fresh", "pem": *pem,
                            "client_secret": "never-kept",
                        }))
                    }
                }),
            )
            .route("/app/installations", get(|| async { Json(json!([{ "id": 7 }])) }))
            .route(
                "/app/installations/{id}/access_tokens",
                post(|| async {
                    Json(json!({ "token": "inst-tok", "expires_at": (Utc::now() + chrono::Duration::hours(1)).to_rfc3339() }))
                }),
            )
            .route(
                "/installation/repositories",
                get(|h: HeaderMap| async move {
                    assert_eq!(header(&h, "authorization"), Some("Bearer inst-tok"));
                    Json(json!({ "repositories": [{ "full_name": "acme/web" }, { "full_name": "acme/api" }] }))
                }),
            )
            .route("/repos/{o}/{r}/installation", get(|| async { Json(json!({ "id": 7 })) }))
            .route(
                "/repos/{o}/{r}/assignees",
                get(|| async { Json(json!([{ "login": "alice" }, { "login": "Bob" }])) }),
            );
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move { axum::serve(listener, gh).await.unwrap() });
        format!("http://{addr}")
    }

    #[tokio::test]
    async fn app_registration_lists_and_forget() {
        let dir = tempfile::tempdir().unwrap();
        let (pem, _) = github::tests::test_key();
        let api = fake_github(pem).await;
        let st = state_with(dir.path(), Some(&api), false);
        let app = router(st.clone());

        let (c, _) = call(&app, signed("issues", "d1", ISSUE, "hush")).await;
        assert_eq!(
            c,
            StatusCode::SERVICE_UNAVAILABLE,
            "no App: no webhook secret"
        );
        let (c, v) = call(&app, admin("GET", "/api/v1/github/repos", None)).await;
        assert_eq!(c, StatusCode::CONFLICT, "{v}");

        let (c, v) = call(
            &app,
            admin("POST", "/api/v1/github/app/manifest", Some(json!({}))),
        )
        .await;
        assert_eq!(c, StatusCode::OK, "{v}");
        let url = v["url"].as_str().unwrap();
        let state = url.split("state=").nth(1).unwrap().to_string();
        assert!(url.starts_with("https://r.dev/github/app/new?state="));
        let page = app
            .clone()
            .oneshot(
                Request::get(format!("/github/app/new?state={state}"))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(page.status(), StatusCode::OK);

        let (c, _) = call(
            &app,
            Request::get("/github/app/callback?code=abc123&state=forged")
                .body(Body::empty())
                .unwrap(),
        )
        .await;
        assert_eq!(c, StatusCode::BAD_REQUEST, "unknown state refused");
        let done = app
            .clone()
            .oneshot(
                Request::get(format!("/github/app/callback?code=abc123&state={state}"))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(done.status(), StatusCode::SEE_OTHER);
        assert_eq!(
            done.headers()["location"],
            "https://github.com/apps/roost-x/installations/new"
        );
        let kept = std::fs::read_to_string(&st.cfg.app_path).unwrap();
        assert!(!kept.contains("never-kept"), "client secret not stored");

        let (c, _) = call(&app, signed("issues", "d2", ISSUE, "fresh")).await;
        assert_eq!(
            c,
            StatusCode::ACCEPTED,
            "webhooks verify with the App's secret"
        );
        let (_, v) = call(&app, admin("GET", "/api/v1/github/repos", None)).await;
        assert_eq!(v["items"], json!(["acme/api", "acme/web"]));
        let (_, v) = call(
            &app,
            admin("GET", "/api/v1/github/people?repo=acme/web", None),
        )
        .await;
        assert_eq!(v["items"], json!(["alice", "Bob"]));
        let (c, _) = call(&app, admin("GET", "/api/v1/github/people?repo=../x", None)).await;
        assert_eq!(c, StatusCode::BAD_REQUEST);
        let (_, v) = call(&app, admin("GET", "/api/v1/status", None)).await;
        assert_eq!(v["github"]["app"]["owner"], "zero");
        assert_eq!(v["github"]["app"]["installations"], 1);
        let (c, _) = call(
            &app,
            admin("POST", "/api/v1/github/app/manifest", Some(json!({}))),
        )
        .await;
        assert_eq!(c, StatusCode::CONFLICT, "one App at a time");

        let (c, _) = call(&app, admin("DELETE", "/api/v1/github/app", None)).await;
        assert_eq!(c, StatusCode::OK);
        assert!(!st.cfg.app_path.exists());
        let (c, _) = call(&app, signed("issues", "d3", ISSUE, "fresh")).await;
        assert_eq!(c, StatusCode::SERVICE_UNAVAILABLE);
    }

    /// What the guard fake saw: rulesets created, scoped token requests (their bodies).
    #[derive(Default)]
    struct Seen {
        rulesets: Vec<Value>,
        scoped: Vec<Value>,
    }

    /// A fake GitHub for run tokens: no rules on any default branch; creating a ruleset fails on
    /// `acme/private` (as on a plan without rulesets).
    async fn fake_github_guard(seen: Arc<Mutex<Seen>>) -> String {
        use axum::extract::Path as P;
        let perms = json!({ "administration": "write", "contents": "write", "issues": "write", "metadata": "read" });
        let (p1, p2) = (perms.clone(), perms);
        let (s1, s2) = (seen.clone(), seen);
        let gh = Router::new()
            .route(
                "/app/installations",
                get(move || {
                    let p = p1.clone();
                    async move { Json(json!([{ "id": 7, "permissions": p }])) }
                }),
            )
            .route(
                "/repos/{o}/{r}/installation",
                get(move || {
                    let p = p2.clone();
                    async move { Json(json!({ "id": 7, "permissions": p })) }
                }),
            )
            .route(
                "/app/installations/{id}/access_tokens",
                post(move |body: Option<Json<Value>>| {
                    let s = s1.clone();
                    async move {
                        let token = match body {
                            Some(Json(b)) => {
                                s.lock().unwrap().scoped.push(b);
                                "run-tok"
                            }
                            None => "inst-tok",
                        };
                        Json(json!({
                            "token": token,
                            "expires_at": (Utc::now() + chrono::Duration::hours(1)).to_rfc3339(),
                            "permissions": { "contents": "write", "issues": "write", "metadata": "read" },
                        }))
                    }
                }),
            )
            .route(
                "/repos/{o}/{r}",
                get(|| async { Json(json!({ "default_branch": "main" })) }),
            )
            .route(
                "/repos/{o}/{r}/rules/branches/{b}",
                get(|P((_, _, b)): P<(String, String, String)>| async move {
                    assert_eq!(b, "main");
                    Json(json!([{ "type": "required_signatures" }]))
                }),
            )
            .route(
                "/repos/{o}/{r}/rulesets",
                get(|| async { Json(json!([])) }).post(
                    move |P((_, r)): P<(String, String)>, h: HeaderMap, Json(b): Json<Value>| {
                        let s = s2.clone();
                        async move {
                            assert_eq!(header(&h, "authorization"), Some("Bearer inst-tok"));
                            if r == "private" {
                                return (
                                    StatusCode::FORBIDDEN,
                                    Json(json!({ "message": "Upgrade to GitHub Pro" })),
                                )
                                    .into_response();
                            }
                            s.lock().unwrap().rulesets.push(b);
                            (StatusCode::CREATED, Json(json!({ "id": 1 }))).into_response()
                        }
                    },
                ),
            )
            .route(
                "/users/{login}",
                get(|P(l): P<String>| async move {
                    assert_eq!(l, "roost-test[bot]");
                    Json(json!({ "id": 77 }))
                }),
            );
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move { axum::serve(listener, gh).await.unwrap() });
        format!("http://{addr}")
    }

    #[tokio::test]
    async fn run_tokens_need_a_guarded_default_branch_and_stay_scoped() {
        let dir = tempfile::tempdir().unwrap();
        let seen = Arc::new(Mutex::new(Seen::default()));
        let api = fake_github_guard(seen.clone()).await;
        let st = state_with(dir.path(), Some(&api), true);
        let app = router(st.clone());

        let (c, v) = call(
            &app,
            admin(
                "POST",
                "/api/v1/github/token",
                Some(json!({ "repo": "acme/web" })),
            ),
        )
        .await;
        assert_eq!(c, StatusCode::OK, "{v}");
        assert_eq!(v["token"], "run-tok");
        assert_eq!(v["login"], "roost-test[bot]");
        assert_eq!(v["email"], "77+roost-test[bot]@users.noreply.github.com");
        assert_eq!(v["branch"], "main");
        assert_eq!(v["protection"], "created");
        assert!(v["expires_in"].as_u64().unwrap() > 3000);
        {
            let s = seen.lock().unwrap();
            assert_eq!(s.rulesets.len(), 1, "the missing guard was added");
            let rs = &s.rulesets[0];
            assert_eq!(rs["name"], github::GUARD_NAME);
            assert_eq!(rs["enforcement"], "active");
            assert_eq!(
                rs["conditions"]["ref_name"]["include"],
                json!(["~DEFAULT_BRANCH"])
            );
            assert_eq!(
                rs["rules"],
                json!([{ "type": "non_fast_forward" }, { "type": "deletion" }])
            );
            assert_eq!(
                s.scoped,
                vec![json!({
                    "repositories": ["web"],
                    "permissions": { "contents": "write", "issues": "write", "metadata": "read" },
                })],
                "one repository, without the relay's administration permission"
            );
        }

        // The check is reused; after it lapses, two runs starting together still add one ruleset.
        let req = || {
            admin(
                "POST",
                "/api/v1/github/token",
                Some(json!({ "repo": "acme/web" })),
            )
        };
        let (c, _) = call(&app, req()).await;
        assert_eq!(c, StatusCode::OK);
        assert_eq!(
            seen.lock().unwrap().rulesets.len(),
            1,
            "the guard check is reused"
        );
        st.gh.forget_installs();
        let ((c1, _), (c2, _)) = tokio::join!(call(&app, req()), call(&app, req()));
        assert_eq!((c1, c2), (StatusCode::OK, StatusCode::OK));
        assert_eq!(
            seen.lock().unwrap().rulesets.len(),
            2,
            "one check per repository at a time"
        );

        let (c, v) = call(
            &app,
            admin(
                "POST",
                "/api/v1/github/token",
                Some(json!({ "repo": "acme/private" })),
            ),
        )
        .await;
        assert_eq!(c, StatusCode::CONFLICT, "{v}");
        assert!(
            v["error"]
                .as_str()
                .unwrap()
                .contains("Upgrade to GitHub Pro")
        );
        assert_eq!(
            seen.lock().unwrap().scoped.len(),
            4,
            "no token without a guard"
        );

        let (c, _) = call(
            &app,
            admin(
                "POST",
                "/api/v1/github/token",
                Some(json!({ "repo": "../x" })),
            ),
        )
        .await;
        assert_eq!(c, StatusCode::BAD_REQUEST);

        let (_, v) = call(&app, admin("GET", "/api/v1/status", None)).await;
        let a = &v["github"]["app"];
        assert_eq!(a["bot"], "roost-test[bot]");
        assert_eq!(
            a["settings_url"],
            "https://github.com/settings/apps/roost-test"
        );
        assert_eq!(
            a["missing"],
            json!([
                "actions:write",
                "checks:write",
                "deployments:write",
                "discussions:write",
                "pull_requests:write",
                "statuses:write",
                "workflows:write"
            ])
        );
    }

    fn delivery(
        outcome: &'static str,
        event: &str,
        repo: Option<&str>,
        reason: Option<&str>,
        at: DateTime<Utc>,
    ) -> Delivery {
        Delivery {
            delivery: format!("{event}-{}", at.timestamp_millis()),
            at,
            event: event.into(),
            action: None,
            repo: repo.map(Into::into),
            outcome,
            reason: reason.map(Into::into),
            seq: None,
        }
    }

    #[tokio::test]
    async fn delivery_summary_counts_by_outcome_event_and_repo() {
        let dir = tempfile::tempdir().unwrap();
        let st = state(dir.path());
        let app = router(st.clone());
        let t0 = Utc::now();
        let at = |s: i64| t0 + chrono::Duration::seconds(s);
        let fd = Some("zerx-lab/FluxDown");
        st.record(delivery("ignored", "workflow_run", fd, Some("old"), at(0)));
        st.record(delivery(
            "ignored",
            "workflow_run",
            fd,
            Some("older"),
            at(1),
        ));
        st.record(delivery(
            "ignored",
            "workflow_run",
            fd,
            Some("newest"),
            at(2),
        ));
        // Same event and repo but another outcome, another event, another repo: separate rows.
        st.record(delivery("relayed", "workflow_run", fd, None, at(3)));
        st.record(delivery("ignored", "push", fd, Some("p"), at(4)));
        st.record(delivery("ignored", "workflow_run", None, Some("n"), at(5)));
        st.record(delivery(
            "relayed",
            "roost_test",
            Some("acme/web"),
            None,
            at(6),
        ));
        st.record(delivery("rejected", "", None, Some("bad signature"), at(7)));
        st.record(delivery("ignored", "push", fd, None, at(8)));

        let (c, v) = call(&app, admin("GET", "/api/v1/deliveries?limit=2", None)).await;
        assert_eq!(c, StatusCode::OK);
        assert_eq!(v["total"], 9);
        assert_eq!(
            v["by_outcome"],
            json!({ "ignored": 6, "relayed": 2, "rejected": 1 })
        );
        assert_eq!(v["since"], json!(lock(&st.delivery_stats).since));
        assert_eq!(
            v["deliveries"].as_array().unwrap().len(),
            2,
            "limit applies to the list only"
        );
        assert_eq!(v["deliveries"][0]["event"], "push", "newest first");

        let rows: Vec<(String, String, Value, u64)> = v["summary"]
            .as_array()
            .unwrap()
            .iter()
            .map(|r| {
                (
                    r["outcome"].as_str().unwrap().to_string(),
                    r["event"].as_str().unwrap().to_string(),
                    r["repo"].clone(),
                    r["count"].as_u64().unwrap(),
                )
            })
            .collect();
        let fd_v = json!("zerx-lab/FluxDown");
        let row = |o: &str, e: &str, repo: Value, n: u64| (o.to_string(), e.to_string(), repo, n);
        assert_eq!(
            rows,
            vec![
                row("ignored", "workflow_run", fd_v.clone(), 3),
                row("ignored", "push", fd_v.clone(), 2),
                // count 1 each: most recently seen first
                row("rejected", "", Value::Null, 1),
                row("relayed", "roost_test", json!("acme/web"), 1),
                row("ignored", "workflow_run", Value::Null, 1),
                row("relayed", "workflow_run", fd_v, 1),
            ]
        );
        let top = &v["summary"][0];
        assert_eq!(top["reason"], "newest", "reason of the latest delivery");
        assert_eq!(top["first_at"], json!(at(0)));
        assert_eq!(top["last_at"], json!(at(2)));
        assert_eq!(
            v["summary"][1]["reason"],
            Value::Null,
            "latest push had no reason"
        );
    }

    #[tokio::test]
    async fn delivery_summary_is_bounded_and_totals_survive_eviction() {
        let dir = tempfile::tempdir().unwrap();
        let st = state(dir.path());
        let t0 = Utc::now();
        let at = |s: i64| t0 + chrono::Duration::seconds(s);
        let ev = |i: usize| format!("e{i}");
        for i in 0..MAX_STAT_KEYS {
            st.record(delivery("ignored", &ev(i), None, None, at(i as i64)));
        }
        // Seen again: e0 is no longer the stalest, e1 is.
        st.record(delivery("ignored", &ev(0), None, None, at(1000)));
        st.record(delivery("relayed", "fresh", None, None, at(1001)));

        let g = lock(&st.delivery_stats);
        assert_eq!(g.keys.len(), MAX_STAT_KEYS);
        assert!(
            !g.keys.contains_key(&("ignored", ev(1), None)),
            "stalest key evicted"
        );
        assert!(g.keys.contains_key(&("ignored", ev(0), None)));
        assert!(g.keys.contains_key(&("ignored", ev(2), None)));
        assert!(g.keys.contains_key(&("relayed", "fresh".to_string(), None)));
        assert_eq!(g.total, MAX_STAT_KEYS as u64 + 2);
        assert_eq!(
            g.by_outcome.get("ignored"),
            Some(&(MAX_STAT_KEYS as u64 + 1))
        );
        assert_eq!(g.by_outcome.get("relayed"), Some(&1));
        assert_eq!(g.summary().len(), MAX_STAT_KEYS);
        assert_eq!(g.summary()[0].event, "e0", "count 2 sorts first");
    }

    #[tokio::test]
    async fn delete_deliveries_resets_counters_and_since() {
        let dir = tempfile::tempdir().unwrap();
        let st = state(dir.path());
        let app = router(st.clone());
        st.record(delivery("ignored", "push", Some("a/b"), None, Utc::now()));
        let (_, before) = call(&app, admin("GET", "/api/v1/deliveries", None)).await;
        assert_eq!(before["total"], 1);
        let (_, s) = call(&app, admin("GET", "/api/v1/status", None)).await;
        assert_eq!(s["api"], 3);
        assert_eq!(s["deliveries"]["since"], before["since"]);

        tokio::time::sleep(Duration::from_millis(5)).await;
        let (c, v) = call(&app, admin("DELETE", "/api/v1/deliveries", None)).await;
        assert_eq!((c, v), (StatusCode::OK, json!({ "ok": true })));
        let (_, after) = call(&app, admin("GET", "/api/v1/deliveries", None)).await;
        assert_eq!(after["total"], 0);
        assert_eq!(after["deliveries"], json!([]));
        assert_eq!(after["by_outcome"], json!({}));
        assert_eq!(after["summary"], json!([]));
        let parse = |v: &Value| v.as_str().unwrap().parse::<DateTime<Utc>>().unwrap();
        assert!(parse(&after["since"]) > parse(&before["since"]));
        let (_, s) = call(&app, admin("GET", "/api/v1/status", None)).await;
        assert_eq!(s["deliveries"]["since"], after["since"]);
        assert_eq!(s["deliveries"]["total"], 0);
        assert_eq!(s["deliveries"]["last"], Value::Null);
    }

    #[tokio::test]
    async fn delete_events_keeps_cursors_and_both_deletes_need_the_token() {
        let dir = tempfile::tempdir().unwrap();
        let st = state(dir.path());
        let app = router(st.clone());
        for uri in ["/api/v1/events", "/api/v1/deliveries"] {
            let anon = Request::delete(uri).body(Body::empty()).unwrap();
            let (c, _) = call(&app, anon).await;
            assert_eq!(c, StatusCode::UNAUTHORIZED, "{uri}");
            let wrong = Request::delete(uri)
                .header("authorization", "Bearer nope")
                .body(Body::empty())
                .unwrap();
            let (c, _) = call(&app, wrong).await;
            assert_eq!(c, StatusCode::UNAUTHORIZED, "{uri}");
        }
        for i in 0..2 {
            let (c, _) = call(&app, signed("issues", &format!("d{i}"), ISSUE, "hush")).await;
            assert_eq!(c, StatusCode::ACCEPTED);
        }
        let (_, before) = call(&app, admin("GET", "/api/v1/status", None)).await;
        assert_eq!(before["store"]["count"], 2);
        assert_eq!(
            st.delivery_stats.lock().unwrap().total,
            2,
            "401s were not recorded"
        );

        let (c, v) = call(&app, admin("DELETE", "/api/v1/events", None)).await;
        assert_eq!(c, StatusCode::OK);
        assert_eq!(v, json!({ "ok": true, "removed": 2, "head": 2 }));
        let (_, after) = call(&app, admin("GET", "/api/v1/status", None)).await;
        assert_eq!(after["store"]["count"], 0);
        assert_eq!(after["store"]["bytes"], 0);
        assert_eq!(after["store"]["head"], 2);
        assert_eq!(after["store"]["store_id"], before["store"]["store_id"]);
        assert_eq!(
            after["deliveries"]["total"], 2,
            "deliveries are cleared separately"
        );

        let (_, v) = call(&app, admin("GET", "/api/v1/events?after=0", None)).await;
        assert_eq!(v["gap"], true, "a client behind the head sees the gap");
        assert_eq!(v["events"], json!([]));
        let (_, v) = call(&app, admin("GET", "/api/v1/events?after=2", None)).await;
        assert_eq!(v["gap"], false);
        let (_, v) = call(&app, signed("issues", "d9", ISSUE, "hush")).await;
        assert_eq!(v["seq"], 3, "sequence numbers are not reused");
    }

    fn from(client: &str, method: &str, uri: &str, body: Option<Value>) -> Request<Body> {
        let mut r = admin(method, uri, body);
        r.headers_mut()
            .insert("x-roost-client", client.parse().unwrap());
        r
    }

    #[tokio::test]
    async fn devices_get_workflows_from_the_head_on_and_share_the_configuration() {
        let dir = tempfile::tempdir().unwrap();
        let st = state(dir.path());
        let app = router(st.clone());
        let subs = || Some(json!({"repos": {"acme/web": {"events": ["issues"]}}}));

        let (_, v) = call(&app, from("mac-1", "GET", "/api/v1/events", None)).await;
        assert_eq!(v["fleet"]["executor"], Value::Null);
        call(&app, from("mac-2", "GET", "/api/v1/events", None)).await;
        call(&app, signed("issues", "d1", ISSUE, "hush")).await;

        let default = |client: Value, base: u64| {
            from(
                "mac-2",
                "PUT",
                "/api/v1/fleet/executor",
                Some(json!({"client": client, "base_revision": base})),
            )
        };
        let assign = |wf: &str, client: Value, base: u64| {
            from(
                "mac-2",
                "PUT",
                "/api/v1/fleet/assign",
                Some(json!({"workflow": wf, "client": client, "base_revision": base})),
            )
        };
        let (c, _) = call(&app, default(json!("ghost"), 0)).await;
        assert_eq!(c, StatusCode::NOT_FOUND, "only clients the relay knows");
        let (c, v) = call(&app, default(json!("mac-1"), 0)).await;
        assert_eq!(c, StatusCode::OK, "{v}");
        assert_eq!(v["fleet"]["executor"]["id"], "mac-1");
        assert_eq!(v["fleet"]["owners"]["*"][0]["seq"], 1, "from the head on");
        let (c, v) = call(&app, assign("triage", json!("mac-2"), 0)).await;
        assert_eq!(
            (c, v["code"].clone()),
            (StatusCode::CONFLICT, json!("fleet_conflict"))
        );
        let (c, _) = call(&app, assign("*", json!("mac-2"), 1)).await;
        assert_eq!(c, StatusCode::BAD_REQUEST);
        call(&app, signed("issues", "d2", ISSUE, "hush")).await;
        let (c, v) = call(&app, assign("triage", json!("mac-2"), 1)).await;
        assert_eq!(c, StatusCode::OK, "{v}");
        assert_eq!(v["fleet"]["owners"]["triage"][0]["client"], "mac-2");
        assert_eq!(v["fleet"]["owners"]["triage"][0]["seq"], 2);

        // Any device pushes subscriptions; the same ones again are fine on a stale base (devices on
        // the same configuration push the same), different ones are a conflict.
        let (c, v) = call(&app, from("mac-2", "PUT", "/api/v1/subscriptions", subs())).await;
        assert_eq!(c, StatusCode::OK);
        let old = json!("0000");
        let with_base = |repos: Value| Some(json!({"repos": repos, "base_revision": old}));
        let (c, w) = call(
            &app,
            from(
                "mac-1",
                "PUT",
                "/api/v1/subscriptions",
                with_base(json!({"acme/web": {"events": ["issues"]}})),
            ),
        )
        .await;
        assert_eq!(
            (c, w["revision"].clone()),
            (StatusCode::OK, v["revision"].clone())
        );
        let (c, _) = call(
            &app,
            from(
                "mac-1",
                "PUT",
                "/api/v1/subscriptions",
                with_base(json!({"acme/api": {"events": ["issues"]}})),
            ),
        )
        .await;
        assert_eq!(c, StatusCode::CONFLICT);

        // The configuration: compare-and-set on the revision the uploader had.
        let cfg = |text: &str, base: Value| Some(json!({"text": text, "base": base}));
        let (c, v) = call(
            &app,
            from(
                "mac-1",
                "PUT",
                "/api/v1/fleet/config",
                cfg("one", Value::Null),
            ),
        )
        .await;
        assert_eq!(c, StatusCode::OK, "{v}");
        let rev = v["config"]["revision"].as_str().unwrap().to_string();
        let (c, v) = call(
            &app,
            from(
                "mac-2",
                "PUT",
                "/api/v1/fleet/config",
                cfg("two", Value::Null),
            ),
        )
        .await;
        assert_eq!(
            (c, v["code"].clone()),
            (StatusCode::CONFLICT, json!("config_conflict"))
        );
        assert_eq!(v["config"]["revision"], rev.as_str());
        let (c, _) = call(
            &app,
            from(
                "mac-2",
                "PUT",
                "/api/v1/fleet/config",
                cfg("two", json!(rev)),
            ),
        )
        .await;
        assert_eq!(c, StatusCode::OK);
        let (_, v) = call(&app, from("mac-1", "GET", "/api/v1/fleet/config", None)).await;
        assert_eq!(
            (v["text"].clone(), v["config"]["client"].clone()),
            (json!("two"), json!("mac-2"))
        );

        // Runs: each device its own.
        let runs = |id: &str| Some(json!({"runs": [{"id": id}]}));
        call(&app, from("mac-1", "PUT", "/api/v1/fleet/runs", runs("r1"))).await;
        call(&app, from("mac-2", "PUT", "/api/v1/fleet/runs", runs("r2"))).await;
        let (_, v) = call(&app, from("mac-2", "GET", "/api/v1/fleet/runs/mac-1", None)).await;
        assert_eq!(v["body"]["runs"][0]["id"], "r1");
        let have = v["runs"]["revision"].as_str().unwrap().to_string();
        let (_, v) = call(
            &app,
            from(
                "mac-2",
                "GET",
                &format!("/api/v1/fleet/runs/mac-1?have={have}"),
                None,
            ),
        )
        .await;
        assert_eq!(v["unchanged"], true);
        let (_, v) = call(&app, from("mac-2", "GET", "/api/v1/status", None)).await;
        assert!(v["fleet"]["uploads"]["mac-2"]["revision"].is_string());

        // A manual run for another device reaches it as an event naming it.
        let (c, v) = call(
            &app,
            from(
                "mac-1",
                "POST",
                "/api/v1/fleet/run",
                Some(
                    json!({"workflow": "triage", "target": "mac-2", "inputs": {"n": "1"}, "pr": "acme/web#7"}),
                ),
            ),
        )
        .await;
        assert_eq!(c, StatusCode::ACCEPTED, "{v}");
        let seq = v["seq"].as_u64().unwrap();
        let (_, v) = call(
            &app,
            from(
                "mac-2",
                "GET",
                &format!("/api/v1/events?after={}", seq - 1),
                None,
            ),
        )
        .await;
        let e = &v["events"][0];
        assert_eq!(
            (e["event"].clone(), e["payload"]["target"].clone()),
            (json!("roost_run"), json!("mac-2"))
        );
        assert_eq!(
            (e["payload"]["from"].clone(), e["payload"]["pr"].clone()),
            (json!("mac-1"), json!("acme/web#7"))
        );

        // A long-poll answers as soon as an assignment changes.
        let after = v["head"].as_u64().unwrap();
        let waiting = tokio::spawn({
            let app = app.clone();
            async move {
                call(
                    &app,
                    from(
                        "mac-1",
                        "GET",
                        &format!("/api/v1/events?after={after}&wait=20"),
                        None,
                    ),
                )
                .await
            }
        });
        tokio::time::sleep(Duration::from_millis(100)).await;
        call(&app, assign("triage", Value::Null, 2)).await;
        let (_, v) = tokio::time::timeout(Duration::from_secs(5), waiting)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(v["fleet"]["revision"], 3);
        assert_eq!(v["fleet"]["owners"]["triage"][1]["client"], Value::Null);
    }
}
