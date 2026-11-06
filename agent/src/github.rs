//! GitHub: webhook signatures and the GitHub App this agent runs as.
//!
//! The App is registered from a manifest, one click from the plugin: the agent hands out a page
//! that posts the manifest to GitHub; GitHub calls back with a code; the agent trades it for the
//! App's id, private key and webhook secret and keeps them in `github-app.json` (mode 0600, never
//! synced). Webhooks of every repository the App is installed on then arrive at `/hooks/github`,
//! signed with the App's webhook secret, with no per-repository hook to manage. The private key
//! signs short JWTs that buy installation tokens: the relay's own (editor suggestions, the
//! default-branch guard) and, per run, a token scoped to one repository that the plugin's runs
//! act on GitHub with. Before handing one out, the relay makes sure the repository's default
//! branch can't be force-pushed or deleted (a ruleset of its own when nothing else forbids it);
//! the Administration permission that takes stays with the relay.

use std::collections::HashMap;
use std::fmt::Write as _;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, RwLock};
use std::time::{Duration, Instant};

use aws_lc_rs::rand::{SecureRandom, SystemRandom};
use aws_lc_rs::signature::{RSA_PKCS1_SHA256, RsaKeyPair};
use base64::Engine;
use base64::engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD};
use hmac::{Hmac, Mac};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::Sha256;

use crate::config::{AgentConfig, valid_repo_name};

/// Largest GitHub API response read.
const MAX_API_RESPONSE: usize = 4 * 1024 * 1024;
/// Largest credentials file read.
const MAX_APP_FILE: u64 = 64 * 1024;
/// A manifest link must be used within GitHub's own one-hour window.
const PENDING_TTL: Duration = Duration::from_secs(3600);
const MAX_PENDING: usize = 16;
/// How long the repo → installation and installation list lookups are reused.
const INSTALL_TTL: Duration = Duration::from_secs(600);
const INSTALLATIONS_TTL: Duration = Duration::from_secs(60);
const MAX_INSTALLS: usize = 512;
/// Installation tokens live an hour; renew this long before they expire.
const TOKEN_MARGIN: Duration = Duration::from_secs(300);
/// Most names one list returns (repos, people, labels, …).
const MAX_ITEMS: usize = 1000;
const PER_PAGE: usize = 100;
/// Repository permissions the App asks for. `administration` stays with the relay: it adds the
/// default-branch guard and is never put in a token the relay hands out.
pub const APP_PERMISSIONS: &[(&str, &str)] = &[
    ("actions", "write"),
    ("administration", "write"),
    ("checks", "write"),
    ("contents", "write"),
    ("deployments", "write"),
    ("discussions", "write"),
    ("issues", "write"),
    ("metadata", "read"),
    ("pull_requests", "write"),
    ("statuses", "write"),
    ("workflows", "write"),
];
const RELAY_ONLY: &[&str] = &["administration"];
/// The ruleset the relay adds when a repository's default branch can still be force-pushed.
pub const GUARD_NAME: &str = "Roost: protect default branch";
/// How long a repository's checked protection is trusted before it is looked at again.
const GUARD_TTL: Duration = Duration::from_secs(600);

/// Events the App subscribes to: everything the plugin's trigger kinds listen for.
pub const APP_EVENTS: &[&str] = &[
    "check_suite",
    "issue_comment",
    "issues",
    "pull_request",
    "pull_request_review",
    "pull_request_review_comment",
    "pull_request_review_thread",
    "push",
    "release",
    "workflow_run",
];

/// `X-Hub-Signature-256: sha256=<hex>` over the raw body.
pub fn verify_signature(secret: &str, body: &[u8], header: Option<&str>) -> bool {
    let Some(hex_sig) = header.and_then(|h| h.trim().strip_prefix("sha256=")) else {
        return false;
    };
    let Ok(sig) = hex::decode(hex_sig) else {
        return false;
    };
    let Ok(mut mac) = Hmac::<Sha256>::new_from_slice(secret.as_bytes()) else {
        return false;
    };
    mac.update(body);
    // Constant-time comparison.
    mac.verify_slice(&sig).is_ok()
}

/// The App credentials as kept on disk (the manifest conversion's answer, trimmed).
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AppFile {
    pub id: u64,
    pub slug: String,
    pub name: String,
    pub owner: String,
    pub owner_type: String,
    pub html_url: String,
    pub webhook_secret: String,
    pub pem: String,
}

struct App {
    file: AppFile,
    key: RsaKeyPair,
}

/// What `/api/v1/status` shows about the App (no secrets).
#[derive(Debug, Clone, Serialize)]
pub struct AppInfo {
    pub id: u64,
    pub slug: String,
    pub name: String,
    pub owner: String,
    pub owner_type: String,
    pub html_url: String,
    pub install_url: String,
    /// The App's settings page on GitHub (logo, permissions).
    pub settings_url: String,
    /// The account the App acts as: `<slug>[bot]`.
    pub bot: String,
    pub installations: Option<usize>,
    /// Wanted permissions (`name:level`) some installation hasn't granted yet; None when unknown.
    pub missing: Option<Vec<String>>,
}

/// A token for one repository, as `/api/v1/github/token` hands it to the plugin. No `Debug`: it
/// holds a live credential.
#[derive(Serialize)]
pub struct AppToken {
    pub token: String,
    pub expires_at: String,
    /// Seconds until it expires.
    pub expires_in: u64,
    pub repository: String,
    pub permissions: Value,
    /// Git author/committer for commits made as the App.
    pub login: String,
    pub email: String,
    /// The default branch and how it is kept from force pushes: `existing`, `created` or `updated`.
    pub branch: String,
    pub protection: &'static str,
}

/// An installation: its id and the permissions it granted.
#[derive(Clone)]
struct Install {
    id: u64,
    permissions: Value,
}

struct Pending {
    org: Option<String>,
    name: String,
    at: Instant,
}

/// Why a GitHub App call failed, with the HTTP status the admin API should answer.
#[derive(Debug)]
pub struct Failure {
    pub status: u16,
    pub message: String,
}

impl Failure {
    fn new(status: u16, message: impl Into<String>) -> Failure {
        Failure {
            status,
            message: message.into(),
        }
    }
}

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|p| p.into_inner())
}

/// The last `/app/installations` answer, or the failure's status and message.
type InstallationsAnswer = Result<Vec<Install>, (u16, String)>;
/// A repository's default branch and how it was found protected (`existing`, `created`, `updated`).
type Guarded = (String, &'static str);

pub struct Github {
    api_url: String,
    web_url: String,
    public_url: Option<String>,
    path: PathBuf,
    client: reqwest::Client,
    rng: SystemRandom,
    app: RwLock<Option<Arc<App>>>,
    tokens: Mutex<HashMap<u64, (String, Instant)>>,
    installs: Mutex<HashMap<String, (Install, Instant)>>,
    installations: Mutex<Option<(InstallationsAnswer, Instant)>>,
    guards: Mutex<HashMap<String, (Guarded, Instant)>>,
    /// Repository → the lock its guard check runs under.
    guard_locks: Mutex<HashMap<String, Arc<tokio::sync::Mutex<()>>>>,
    /// (App id, the user id of its bot account).
    bot: Mutex<Option<(u64, u64)>>,
    pending: Mutex<HashMap<String, Pending>>,
}

fn rank(level: &str) -> u8 {
    match level {
        "read" => 1,
        "write" => 2,
        "admin" => 3,
        _ => 0,
    }
}

fn grants(perms: &Value, name: &str, level: &str) -> bool {
    rank(perms.get(name).and_then(Value::as_str).unwrap_or("")) >= rank(level)
}

fn has_rule(rules: &Value, kind: &str) -> bool {
    rules.as_array().is_some_and(|a| {
        a.iter()
            .any(|r| r.get("type").and_then(Value::as_str) == Some(kind))
    })
}

/// The default-branch guard: no force pushes, no deletion. Repository admins may still bypass it;
/// the App is not one of them.
fn guard_ruleset() -> Value {
    json!({
        "name": GUARD_NAME,
        "target": "branch",
        "enforcement": "active",
        "bypass_actors": [{ "actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "always" }],
        "conditions": { "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] } },
        "rules": [{ "type": "non_fast_forward" }, { "type": "deletion" }],
    })
}

/// A path segment (a branch name keeps its slashes).
fn path_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        if b.is_ascii_alphanumeric() || matches!(b, b'-' | b'.' | b'_' | b'~' | b'/') {
            out.push(char::from(b));
        } else {
            let _ = write!(out, "%{b:02X}");
        }
    }
    out
}

/// How long a token answer (`expires_at`) has left; an hour when GitHub didn't say.
fn time_left(v: &Value) -> Duration {
    str_of(v, "expires_at")
        .and_then(|s| chrono::DateTime::parse_from_rfc3339(&s).ok())
        .and_then(|t| {
            (t.with_timezone(&chrono::Utc) - chrono::Utc::now())
                .to_std()
                .ok()
        })
        .unwrap_or(Duration::from_secs(3600))
}

/// The DER bytes of a PEM private key: PKCS#1 (`RSA PRIVATE KEY`, what GitHub issues) or PKCS#8.
fn parse_key(pem: &str) -> Result<RsaKeyPair, String> {
    let pkcs1 = pem.contains("BEGIN RSA PRIVATE KEY");
    let body: String = pem
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty() && !l.starts_with("-----"))
        .collect();
    let der = STANDARD
        .decode(body.as_bytes())
        .map_err(|e| format!("private key is not base64 PEM: {e}"))?;
    let key = if pkcs1 {
        RsaKeyPair::from_der(&der)
    } else {
        RsaKeyPair::from_pkcs8(&der)
    };
    key.map_err(|e| format!("private key rejected: {e}"))
}

fn app_of(file: AppFile) -> Result<App, String> {
    let key = parse_key(&file.pem)?;
    Ok(App { file, key })
}

fn load_file(path: &Path) -> Result<Option<AppFile>, String> {
    use std::io::Read;
    let file = match std::fs::File::open(path) {
        Ok(f) => f,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(format!("cannot open {}: {e}", path.display())),
    };
    let mut text = String::new();
    file.take(MAX_APP_FILE + 1)
        .read_to_string(&mut text)
        .map_err(|e| format!("cannot read {}: {e}", path.display()))?;
    if text.len() as u64 > MAX_APP_FILE {
        return Err(format!("{} is too large", path.display()));
    }
    serde_json::from_str(&text)
        .map(Some)
        .map_err(|e| format!("{}: {e}", path.display()))
}

/// Writes the credentials owner-only, through a temp file renamed over `path`.
fn save_file(path: &Path, file: &AppFile) -> Result<(), String> {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    let bytes = serde_json::to_vec_pretty(file).map_err(|e| e.to_string())?;
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)
            .map_err(|e| format!("cannot create {}: {e}", dir.display()))?;
    }
    let mut tmp = path.as_os_str().to_owned();
    tmp.push(".tmp");
    let tmp = PathBuf::from(tmp);
    let mut f = std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(&tmp)
        .map_err(|e| format!("cannot write {}: {e}", tmp.display()))?;
    f.write_all(&bytes)
        .and_then(|()| f.sync_all())
        .map_err(|e| format!("cannot write {}: {e}", tmp.display()))?;
    std::fs::rename(&tmp, path).map_err(|e| format!("cannot write {}: {e}", path.display()))
}

fn html_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for ch in s.chars() {
        match ch {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&#39;"),
            c => out.push(c),
        }
    }
    out
}

/// A small standalone HTML page (the manifest hand-off and the results GitHub redirects to).
pub fn page(title: &str, body_html: &str) -> String {
    format!(
        "<!doctype html><html lang=\"zh-CN\"><head><meta charset=\"utf-8\"><title>{t}</title>\
         <style>body{{font:15px/1.6 -apple-system,system-ui,sans-serif;max-width:560px;margin:15vh auto;padding:0 24px;color:#222}}\
         button{{font:inherit;padding:8px 16px;border-radius:8px;border:0;background:#222;color:#fff;cursor:pointer}}\
         code{{background:#eee;padding:1px 4px;border-radius:4px}}</style></head><body><h2>{t}</h2>{body_html}</body></html>",
        t = html_escape(title)
    )
}

fn valid_org(s: &str) -> bool {
    !s.is_empty() && s.len() <= 39 && s.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')
}

fn str_of(v: &Value, key: &str) -> Option<String> {
    v.get(key).and_then(Value::as_str).map(str::to_string)
}

impl Github {
    pub fn new(cfg: &AgentConfig) -> Result<Github, String> {
        let client = reqwest::Client::builder()
            .timeout(Duration::from_secs(20))
            .user_agent(concat!("roost-agent/", env!("CARGO_PKG_VERSION")))
            .build()
            .map_err(|e| format!("http client: {e}"))?;
        let app = match load_file(&cfg.app_path) {
            Ok(Some(f)) => match app_of(f) {
                Ok(a) => Some(Arc::new(a)),
                Err(e) => {
                    tracing::warn!(
                        "{}: {e}; GitHub App disabled until recreated",
                        cfg.app_path.display()
                    );
                    None
                }
            },
            Ok(None) => None,
            Err(e) => {
                tracing::warn!("{e}; GitHub App disabled until recreated");
                None
            }
        };
        Ok(Github {
            api_url: cfg.api_url.clone(),
            web_url: cfg.web_url.clone(),
            public_url: cfg.public_url.clone(),
            path: cfg.app_path.clone(),
            client,
            rng: SystemRandom::new(),
            app: RwLock::new(app),
            tokens: Mutex::new(HashMap::new()),
            installs: Mutex::new(HashMap::new()),
            installations: Mutex::new(None),
            guards: Mutex::new(HashMap::new()),
            guard_locks: Mutex::new(HashMap::new()),
            bot: Mutex::new(None),
            pending: Mutex::new(HashMap::new()),
        })
    }

    fn app(&self) -> Option<Arc<App>> {
        self.app.read().unwrap_or_else(|p| p.into_inner()).clone()
    }

    fn set_app(&self, app: Option<App>) {
        *self.app.write().unwrap_or_else(|p| p.into_inner()) = app.map(Arc::new);
        self.forget_installs();
        lock(&self.tokens).clear();
        lock(&self.guards).clear();
        *lock(&self.bot) = None;
    }

    /// Drops cached installation lookups and the tokens and guard checks made under them
    /// (installations or their granted permissions changed on GitHub).
    pub fn forget_installs(&self) {
        lock(&self.installs).clear();
        *lock(&self.installations) = None;
        lock(&self.tokens).clear();
        lock(&self.guards).clear();
    }

    pub fn webhook_secret(&self) -> Option<String> {
        self.app().map(|a| a.file.webhook_secret.clone())
    }

    pub fn configured(&self) -> bool {
        self.app().is_some()
    }

    /// A JWT the App signs for itself: valid from a minute ago for nine minutes.
    fn jwt(&self, app: &App) -> Result<String, Failure> {
        let now = chrono::Utc::now().timestamp();
        let header = URL_SAFE_NO_PAD.encode(br#"{"alg":"RS256","typ":"JWT"}"#);
        let claims = json!({ "iat": now - 60, "exp": now + 540, "iss": app.file.id.to_string() });
        let msg = format!("{header}.{}", URL_SAFE_NO_PAD.encode(claims.to_string()));
        let mut sig = vec![0u8; app.key.public_modulus_len()];
        app.key
            .sign(&RSA_PKCS1_SHA256, &self.rng, msg.as_bytes(), &mut sig)
            .map_err(|_| Failure::new(500, "cannot sign the GitHub App JWT"))?;
        Ok(format!("{msg}.{}", URL_SAFE_NO_PAD.encode(sig)))
    }

    /// One GitHub API call; `bearer` is a JWT or an installation token (none for manifests).
    async fn call(
        &self,
        method: reqwest::Method,
        path: &str,
        bearer: Option<&str>,
        body: Option<&Value>,
    ) -> Result<Value, Failure> {
        let mut req = self
            .client
            .request(method.clone(), format!("{}{}", self.api_url, path))
            .header("Accept", "application/vnd.github+json")
            .header("X-GitHub-Api-Version", "2022-11-28");
        if let Some(b) = bearer {
            req = req.bearer_auth(b);
        }
        if let Some(b) = body {
            req = req.json(b);
        }
        let mut resp = req
            .send()
            .await
            .map_err(|e| Failure::new(502, format!("{method} {path}: {e}")))?;
        let status = resp.status();
        let mut bytes = Vec::new();
        while let Some(chunk) = resp
            .chunk()
            .await
            .map_err(|e| Failure::new(502, format!("{method} {path}: {e}")))?
        {
            if bytes.len() + chunk.len() > MAX_API_RESPONSE {
                return Err(Failure::new(
                    502,
                    format!("{method} {path}: response too large"),
                ));
            }
            bytes.extend_from_slice(&chunk);
        }
        if !status.is_success() {
            let msg = serde_json::from_slice::<Value>(&bytes)
                .ok()
                .and_then(|v| str_of(&v, "message"))
                .unwrap_or_default();
            let code = if status.as_u16() == 404 { 404 } else { 502 };
            return Err(Failure::new(
                code,
                format!("GitHub {} on {method} {path}: {msg}", status.as_u16()),
            ));
        }
        if bytes.is_empty() {
            return Ok(Value::Null);
        }
        serde_json::from_slice(&bytes)
            .map_err(|e| Failure::new(502, format!("{method} {path}: bad JSON: {e}")))
    }

    fn need_app(&self) -> Result<Arc<App>, Failure> {
        self.app()
            .ok_or_else(|| Failure::new(409, "GitHub App 未创建:在 Roost「中继」页创建"))
    }

    /// The App's installations (accounts it is installed on). Answers, failures included, are
    /// reused for a minute, so a slow or failing GitHub can't stall every status poll.
    async fn installations(&self) -> Result<Vec<Install>, Failure> {
        if let Some((answer, at)) = lock(&self.installations).as_ref()
            && at.elapsed() < INSTALLATIONS_TTL
        {
            return answer
                .clone()
                .map_err(|(status, message)| Failure { status, message });
        }
        let app = self.need_app()?;
        let jwt = self.jwt(&app)?;
        let answer = self
            .call(
                reqwest::Method::GET,
                "/app/installations?per_page=100",
                Some(&jwt),
                None,
            )
            .await
            .map(|v| {
                v.as_array()
                    .map(|a| {
                        a.iter()
                            .filter_map(|i| {
                                Some(Install {
                                    id: i.get("id").and_then(Value::as_u64)?,
                                    permissions: i.get("permissions").cloned().unwrap_or_default(),
                                })
                            })
                            .collect::<Vec<Install>>()
                    })
                    .unwrap_or_default()
            })
            .map_err(|f| (f.status, f.message));
        *lock(&self.installations) = Some((answer.clone(), Instant::now()));
        answer.map_err(|(status, message)| Failure { status, message })
    }

    /// The relay's own token for installation `id`, reused until shortly before it expires.
    async fn token(&self, id: u64) -> Result<String, Failure> {
        if let Some((t, until)) = lock(&self.tokens).get(&id)
            && Instant::now() < *until
        {
            return Ok(t.clone());
        }
        let app = self.need_app()?;
        let jwt = self.jwt(&app)?;
        let v = self
            .call(
                reqwest::Method::POST,
                &format!("/app/installations/{id}/access_tokens"),
                Some(&jwt),
                None,
            )
            .await?;
        let token = str_of(&v, "token").ok_or_else(|| Failure::new(502, "GitHub gave no token"))?;
        let left = time_left(&v);
        let until = Instant::now() + left.saturating_sub(TOKEN_MARGIN);
        let mut g = lock(&self.tokens);
        if g.len() >= MAX_INSTALLS {
            g.clear();
        }
        g.insert(id, (token.clone(), until));
        Ok(token)
    }

    /// The installation that covers `repo` (the App must be installed on it).
    async fn installation(&self, repo: &str) -> Result<Install, Failure> {
        let key = repo.to_ascii_lowercase();
        let cached = lock(&self.installs)
            .get(&key)
            .filter(|(_, at)| at.elapsed() < INSTALL_TTL)
            .map(|(i, _)| i.clone());
        if let Some(i) = cached {
            return Ok(i);
        }
        let app = self.need_app()?;
        let jwt = self.jwt(&app)?;
        let v = self
            .call(
                reqwest::Method::GET,
                &format!("/repos/{repo}/installation"),
                Some(&jwt),
                None,
            )
            .await
            .map_err(|f| {
                if f.status == 404 {
                    Failure::new(404, format!("GitHub App 没有安装到 {repo}"))
                } else {
                    f
                }
            })?;
        let install = Install {
            id: v
                .get("id")
                .and_then(Value::as_u64)
                .ok_or_else(|| Failure::new(502, "GitHub gave no installation id"))?,
            permissions: v.get("permissions").cloned().unwrap_or_default(),
        };
        let mut g = lock(&self.installs);
        if g.len() >= MAX_INSTALLS {
            g.clear();
        }
        g.insert(key, (install.clone(), Instant::now()));
        Ok(install)
    }

    /// The relay's installation token for `repo`.
    async fn repo_token(&self, repo: &str) -> Result<String, Failure> {
        let install = self.installation(repo).await?;
        self.token(install.id).await
    }

    /// The guard check for `key` while it is still trusted.
    fn cached_guard(&self, key: &str) -> Option<Guarded> {
        lock(&self.guards)
            .get(key)
            .filter(|(_, at)| at.elapsed() < GUARD_TTL)
            .map(|(g, _)| g.clone())
    }

    /// `repo`'s default branch, after making sure it can't be force-pushed or deleted: by rules
    /// already in place, else by the relay's own ruleset. Fails when neither can be had.
    async fn guard(&self, repo: &str, token: &str) -> Result<Guarded, Failure> {
        let key = repo.to_ascii_lowercase();
        if let Some(g) = self.cached_guard(&key) {
            return Ok(g);
        }
        // One check per repository at a time: two runs starting together would otherwise both
        // create the ruleset, and GitHub refuses the second (names are unique).
        let gate = {
            let mut m = lock(&self.guard_locks);
            if m.len() >= MAX_INSTALLS {
                m.retain(|_, l| Arc::strong_count(l) > 1);
            }
            m.entry(key.clone()).or_default().clone()
        };
        let _held = gate.lock().await;
        if let Some(g) = self.cached_guard(&key) {
            return Ok(g);
        }
        let info = self
            .call(
                reqwest::Method::GET,
                &format!("/repos/{repo}"),
                Some(token),
                None,
            )
            .await?;
        let branch = str_of(&info, "default_branch")
            .filter(|b| !b.is_empty())
            .ok_or_else(|| Failure::new(502, format!("GitHub 没有给出 {repo} 的默认分支")))?;
        let rules = self
            .call(
                reqwest::Method::GET,
                &format!(
                    "/repos/{repo}/rules/branches/{}?per_page=100",
                    path_escape(&branch)
                ),
                Some(token),
                None,
            )
            .await?;
        let source = if has_rule(&rules, "non_fast_forward") && has_rule(&rules, "deletion") {
            "existing"
        } else {
            self.add_guard(repo, &branch, token).await?
        };
        let g = (branch, source);
        let mut m = lock(&self.guards);
        if m.len() >= MAX_INSTALLS {
            m.clear();
        }
        m.insert(key, (g.clone(), Instant::now()));
        Ok(g)
    }

    /// Puts the relay's ruleset on `repo` (or turns its earlier one back on).
    async fn add_guard(
        &self,
        repo: &str,
        branch: &str,
        token: &str,
    ) -> Result<&'static str, Failure> {
        let refuse = |f: Failure| {
            Failure::new(
                409,
                format!(
                    "{repo} 的默认分支 {branch} 仍可被强推或删除,Roost 也无法加上保护规则集({}),因此不签发 App 令牌。\
                     常见原因:安装还没接受 App 新增的 Administration 权限,或私有仓库所在账号的套餐不支持规则集。\
                     也可以在 GitHub 上为默认分支手动添加禁止强推与删除的规则",
                    f.message
                ),
            )
        };
        let list = self
            .call(
                reqwest::Method::GET,
                &format!("/repos/{repo}/rulesets?includes_parents=false&per_page=100"),
                Some(token),
                None,
            )
            .await
            .map_err(refuse)?;
        let ours = list
            .as_array()
            .and_then(|a| {
                a.iter()
                    .find(|r| r.get("name").and_then(Value::as_str) == Some(GUARD_NAME))
            })
            .and_then(|r| r.get("id"))
            .and_then(Value::as_u64);
        let body = guard_ruleset();
        let (method, path, source) = match ours {
            Some(id) => (
                reqwest::Method::PUT,
                format!("/repos/{repo}/rulesets/{id}"),
                "updated",
            ),
            None => (
                reqwest::Method::POST,
                format!("/repos/{repo}/rulesets"),
                "created",
            ),
        };
        self.call(method, &path, Some(token), Some(&body))
            .await
            .map_err(refuse)?;
        tracing::info!(%repo, %branch, source, "default branch guard in place");
        Ok(source)
    }

    /// The user id of the App's bot account (for commit e-mail addresses GitHub attributes).
    async fn bot_id(&self, app: &App, token: &str) -> Result<u64, Failure> {
        if let Some((aid, uid)) = *lock(&self.bot)
            && aid == app.file.id
        {
            return Ok(uid);
        }
        let v = self
            .call(
                reqwest::Method::GET,
                &format!("/users/{}%5Bbot%5D", path_escape(&app.file.slug)),
                Some(token),
                None,
            )
            .await?;
        let uid = v
            .get("id")
            .and_then(Value::as_u64)
            .ok_or_else(|| Failure::new(502, "GitHub gave no id for the App's bot account"))?;
        *lock(&self.bot) = Some((app.file.id, uid));
        Ok(uid)
    }

    /// A token for one run on `repo`: only that repository, every permission its installation
    /// granted except the relay's own, and only once its default branch is guarded.
    pub async fn app_token(&self, repo: &str) -> Result<AppToken, Failure> {
        if !valid_repo_name(repo) {
            return Err(Failure::new(400, "repo=owner/name is required"));
        }
        let app = self.need_app()?;
        let install = self.installation(repo).await?;
        let own = self.token(install.id).await?;
        let guarded = self.guard(repo, &own).await;
        let (branch, protection) = match guarded {
            Ok(g) => g,
            Err(f) => {
                // The relay's token may predate a permission just granted: mint a fresh one next time.
                lock(&self.tokens).remove(&install.id);
                return Err(f);
            }
        };
        let uid = self.bot_id(&app, &own).await?;
        let mut perms = serde_json::Map::new();
        for (name, _) in APP_PERMISSIONS {
            if RELAY_ONLY.contains(name) {
                continue;
            }
            if let Some(level) = install.permissions.get(*name) {
                perms.insert((*name).to_string(), level.clone());
            }
        }
        let short = repo.split_once('/').map_or(repo, |(_, n)| n);
        let jwt = self.jwt(&app)?;
        let v = self
            .call(
                reqwest::Method::POST,
                &format!("/app/installations/{}/access_tokens", install.id),
                Some(&jwt),
                Some(&json!({ "repositories": [short], "permissions": perms })),
            )
            .await?;
        let token = str_of(&v, "token").ok_or_else(|| Failure::new(502, "GitHub gave no token"))?;
        let login = format!("{}[bot]", app.file.slug);
        Ok(AppToken {
            token,
            expires_at: str_of(&v, "expires_at").unwrap_or_default(),
            expires_in: time_left(&v).as_secs(),
            repository: repo.to_string(),
            permissions: v
                .get("permissions")
                .cloned()
                .unwrap_or(Value::Object(perms)),
            email: format!("{uid}+{login}@users.noreply.github.com"),
            login,
            branch,
            protection,
        })
    }

    /// Names from a paginated list: `array` is the key holding the list (None: the body is it).
    async fn collect(
        &self,
        token: &str,
        path: &str,
        array: Option<&str>,
        field: &str,
        out: &mut Vec<String>,
    ) -> Result<(), Failure> {
        let sep = if path.contains('?') { '&' } else { '?' };
        for page in 1..=MAX_ITEMS / PER_PAGE {
            let v = self
                .call(
                    reqwest::Method::GET,
                    &format!("{path}{sep}per_page={PER_PAGE}&page={page}"),
                    Some(token),
                    None,
                )
                .await?;
            let list = match array {
                Some(k) => v.get(k).and_then(Value::as_array),
                None => v.as_array(),
            };
            let Some(list) = list else {
                break;
            };
            for item in list {
                if out.len() >= MAX_ITEMS {
                    return Ok(());
                }
                if let Some(s) = item.get(field).and_then(Value::as_str) {
                    out.push(s.to_string());
                }
            }
            if list.len() < PER_PAGE {
                break;
            }
        }
        Ok(())
    }

    /// Suggestions for the editor: `repos` (all installed), or per `repo`: `people`, `labels`,
    /// `branches`, `workflows`.
    pub async fn list(&self, what: &str, repo: Option<&str>) -> Result<Vec<String>, Failure> {
        let mut out = Vec::new();
        if what == "repos" {
            for install in self.installations().await? {
                if out.len() >= MAX_ITEMS {
                    break;
                }
                let token = self.token(install.id).await?;
                self.collect(
                    &token,
                    "/installation/repositories",
                    Some("repositories"),
                    "full_name",
                    &mut out,
                )
                .await?;
            }
        } else {
            let repo = repo
                .filter(|r| valid_repo_name(r))
                .ok_or_else(|| Failure::new(400, "repo=owner/name is required"))?;
            let (path, array, field) = match what {
                "people" => (format!("/repos/{repo}/assignees"), None, "login"),
                "labels" => (format!("/repos/{repo}/labels"), None, "name"),
                "branches" => (format!("/repos/{repo}/branches"), None, "name"),
                "workflows" => (
                    format!("/repos/{repo}/actions/workflows"),
                    Some("workflows"),
                    "name",
                ),
                _ => return Err(Failure::new(404, format!("unknown list {what:?}"))),
            };
            let token = self.repo_token(repo).await?;
            self.collect(&token, &path, array, field, &mut out).await?;
        }
        out.sort_by_key(|s| s.to_ascii_lowercase());
        out.dedup();
        Ok(out)
    }

    /// The App as `/api/v1/status` reports it, or None before one is created.
    pub async fn info(&self) -> Option<AppInfo> {
        let app = self.app()?;
        let installs = self.installations().await.ok();
        let missing = installs.as_ref().map(|list| {
            APP_PERMISSIONS
                .iter()
                .filter(|(name, level)| list.iter().any(|i| !grants(&i.permissions, name, level)))
                .map(|(name, level)| format!("{name}:{level}"))
                .collect::<Vec<String>>()
        });
        let f = &app.file;
        let settings_url = if f.owner_type == "Organization" {
            format!(
                "{}/organizations/{}/settings/apps/{}",
                self.web_url, f.owner, f.slug
            )
        } else {
            format!("{}/settings/apps/{}", self.web_url, f.slug)
        };
        Some(AppInfo {
            id: f.id,
            slug: f.slug.clone(),
            name: f.name.clone(),
            owner: f.owner.clone(),
            owner_type: f.owner_type.clone(),
            html_url: f.html_url.clone(),
            install_url: format!("{}/installations/new", f.html_url),
            settings_url,
            bot: format!("{}[bot]", f.slug),
            installations: installs.map(|v| v.len()),
            missing,
        })
    }

    // -----------------------------------------------------------------------------------------
    // Registration from a manifest

    /// Starts a registration: the URL of this agent's page that posts the manifest to GitHub.
    pub fn begin(&self, org: Option<String>, name: Option<String>) -> Result<String, Failure> {
        let Some(public) = &self.public_url else {
            return Err(Failure::new(
                409,
                "agent.toml 没有设置 server.public_url:GitHub 需要用它回调与投递 webhook",
            ));
        };
        if self.configured() {
            return Err(Failure::new(
                409,
                "已经有 GitHub App;先删除本地凭据再重新创建",
            ));
        }
        let org = org.map(|o| o.trim().to_string()).filter(|o| !o.is_empty());
        if let Some(o) = &org
            && !valid_org(o)
        {
            return Err(Failure::new(400, format!("{o:?} 不是有效的组织名")));
        }
        let mut raw = [0u8; 16];
        self.rng
            .fill(&mut raw)
            .map_err(|_| Failure::new(500, "no randomness"))?;
        let state = hex::encode(raw);
        let name = name
            .map(|n| n.trim().chars().take(34).collect::<String>())
            .filter(|n| !n.is_empty())
            .unwrap_or_else(|| format!("Roost {}", state.chars().take(6).collect::<String>()));
        let mut g = lock(&self.pending);
        g.retain(|_, p| p.at.elapsed() < PENDING_TTL);
        if g.len() >= MAX_PENDING {
            return Err(Failure::new(
                429,
                "too many registrations in progress; try again later",
            ));
        }
        g.insert(
            state.clone(),
            Pending {
                org,
                name,
                at: Instant::now(),
            },
        );
        Ok(format!("{public}/github/app/new?state={state}"))
    }

    /// The manifest this agent registers.
    fn manifest(&self, name: &str) -> Value {
        let public = self.public_url.clone().unwrap_or_default();
        json!({
            "name": name,
            "url": public,
            "description": "Roost relay: hands GitHub events to the Roost Tern plugin.",
            "hook_attributes": { "url": format!("{public}/hooks/github"), "active": true },
            "redirect_url": format!("{public}/github/app/callback"),
            "setup_url": format!("{public}/github/app/installed"),
            "public": false,
            "default_permissions": APP_PERMISSIONS
                .iter()
                .map(|(name, level)| ((*name).to_string(), Value::from(*level)))
                .collect::<serde_json::Map<String, Value>>(),
            "default_events": APP_EVENTS,
        })
    }

    /// The page that posts the manifest of registration `state` to GitHub, or None when unknown.
    pub fn manifest_page(&self, state: &str) -> Option<String> {
        let g = lock(&self.pending);
        let p = g.get(state).filter(|p| p.at.elapsed() < PENDING_TTL)?;
        let target = match &p.org {
            Some(o) => format!("{}/organizations/{o}/settings/apps/new", self.web_url),
            None => format!("{}/settings/apps/new", self.web_url),
        };
        let manifest = self.manifest(&p.name).to_string();
        Some(page(
            "创建 Roost GitHub App",
            &format!(
                "<p>即将在 GitHub {who}下创建 GitHub App「{name}」:它把仓库事件转给 Roost,并让 Roost 的运行以 App 身份评论、审查与推送\
                 (默认分支会加上禁止强推与删除的规则)。GitHub 会让你确认名称,创建后再选择要安装的仓库。</p>\
                 <form id=\"f\" method=\"post\" action=\"{action}?state={state}\">\
                 <input type=\"hidden\" name=\"manifest\" value=\"{manifest}\">\
                 <button type=\"submit\">前往 GitHub 创建</button></form>\
                 <script>document.getElementById('f').submit()</script>",
                who = p
                    .org
                    .as_deref()
                    .map(|o| format!("组织 <code>{}</code> ", html_escape(o)))
                    .unwrap_or_else(|| "你的账号".into()),
                name = html_escape(&p.name),
                action = html_escape(&target),
                state = html_escape(state),
                manifest = html_escape(&manifest),
            ),
        ))
    }

    /// Completes registration `state` with GitHub's `code`: stores the credentials and returns
    /// the App's installation page.
    pub async fn finish(&self, code: &str, state: &str) -> Result<String, Failure> {
        let pending = lock(&self.pending).remove(state);
        match pending {
            Some(p) if p.at.elapsed() < PENDING_TTL => {}
            _ => {
                return Err(Failure::new(
                    400,
                    "这个创建链接已失效,请回到 Roost 重新创建",
                ));
            }
        }
        if code.is_empty() || code.len() > 100 || !code.chars().all(|c| c.is_ascii_alphanumeric()) {
            return Err(Failure::new(400, "GitHub 回调缺少有效的 code"));
        }
        if self.configured() {
            return Err(Failure::new(409, "已经有 GitHub App"));
        }
        let v = self
            .call(
                reqwest::Method::POST,
                &format!("/app-manifests/{code}/conversions"),
                None,
                None,
            )
            .await?;
        let owner = v.get("owner").cloned().unwrap_or(Value::Null);
        let file = AppFile {
            id: v
                .get("id")
                .and_then(Value::as_u64)
                .ok_or_else(|| Failure::new(502, "GitHub gave no App id"))?,
            slug: str_of(&v, "slug").unwrap_or_default(),
            name: str_of(&v, "name").unwrap_or_default(),
            owner: str_of(&owner, "login").unwrap_or_default(),
            owner_type: str_of(&owner, "type").unwrap_or_default(),
            html_url: str_of(&v, "html_url").unwrap_or_default(),
            webhook_secret: str_of(&v, "webhook_secret")
                .filter(|s| !s.is_empty())
                .ok_or_else(|| Failure::new(502, "GitHub gave no webhook secret"))?,
            pem: str_of(&v, "pem")
                .ok_or_else(|| Failure::new(502, "GitHub gave no private key"))?,
        };
        let app = app_of(file.clone()).map_err(|e| Failure::new(502, e))?;
        let path = self.path.clone();
        let saved = tokio::task::spawn_blocking(move || save_file(&path, &file))
            .await
            .map_err(|e| Failure::new(500, e.to_string()))?;
        saved.map_err(|e| Failure::new(500, e))?;
        let install = format!("{}/installations/new", app.file.html_url);
        tracing::info!(slug = %app.file.slug, owner = %app.file.owner, "GitHub App created");
        self.set_app(Some(app));
        Ok(install)
    }

    /// Deletes the local credentials (the App itself stays on GitHub). Whether there were any.
    pub async fn forget(&self) -> Result<bool, Failure> {
        let had = self.configured();
        match tokio::fs::remove_file(&self.path).await {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => {
                return Err(Failure::new(
                    500,
                    format!("cannot delete {}: {e}", self.path.display()),
                ));
            }
        }
        self.set_app(None);
        Ok(had)
    }
}

#[cfg(test)]
pub mod tests {
    use super::*;
    use aws_lc_rs::encoding::AsDer;
    use aws_lc_rs::rsa::KeySize;
    use aws_lc_rs::signature::{KeyPair, RSA_PKCS1_2048_8192_SHA256, UnparsedPublicKey};

    /// A fresh PKCS#8 PEM key and its public key bytes.
    pub fn test_key() -> (String, Vec<u8>) {
        let k = RsaKeyPair::generate(KeySize::Rsa2048).unwrap();
        let der = AsDer::<aws_lc_rs::encoding::Pkcs8V1Der>::as_der(&k).unwrap();
        let b64 = STANDARD.encode(der.as_ref());
        let pem = format!("-----BEGIN PRIVATE KEY-----\n{b64}\n-----END PRIVATE KEY-----\n");
        (pem, k.public_key().as_ref().to_vec())
    }

    pub fn test_file(pem: &str, secret: &str) -> AppFile {
        AppFile {
            id: 42,
            slug: "roost-test".into(),
            name: "Roost test".into(),
            owner: "zero".into(),
            owner_type: "User".into(),
            html_url: "https://github.com/apps/roost-test".into(),
            webhook_secret: secret.into(),
            pem: pem.into(),
        }
    }

    #[test]
    fn signature_roundtrip_and_rejections() {
        let mut mac = Hmac::<Sha256>::new_from_slice(b"s3cret").unwrap();
        mac.update(b"{}");
        let sig = format!("sha256={}", hex::encode(mac.finalize().into_bytes()));
        assert!(verify_signature("s3cret", b"{}", Some(&sig)));
        assert!(!verify_signature("other", b"{}", Some(&sig)));
        assert!(!verify_signature("s3cret", b"{ }", Some(&sig)));
        assert!(!verify_signature("s3cret", b"{}", None));
        assert!(!verify_signature("s3cret", b"{}", Some("sha1=abc")));
        assert!(!verify_signature("s3cret", b"{}", Some("sha256=zz")));
    }

    #[test]
    fn jwt_is_rs256_signed_by_the_app_key() {
        let dir = tempfile::tempdir().unwrap();
        let cfg = AgentConfig::parse(
            "[auth]\ntoken=\"0123456789abcdef\"\n",
            &dir.path().join("agent.toml"),
            dir.path(),
        )
        .unwrap();
        let (pem, public) = test_key();
        save_file(&cfg.app_path, &test_file(&pem, "hush")).unwrap();
        let gh = Github::new(&cfg).unwrap();
        let app = gh.app().unwrap();
        let jwt = gh.jwt(&app).unwrap();
        let parts: Vec<&str> = jwt.split('.').collect();
        assert_eq!(parts.len(), 3);
        let claims: Value =
            serde_json::from_slice(&URL_SAFE_NO_PAD.decode(parts[1]).unwrap()).unwrap();
        assert_eq!(claims["iss"], "42");
        assert!(claims["exp"].as_i64().unwrap() - claims["iat"].as_i64().unwrap() <= 600);
        let msg = format!("{}.{}", parts[0], parts[1]);
        let sig = URL_SAFE_NO_PAD.decode(parts[2]).unwrap();
        UnparsedPublicKey::new(&RSA_PKCS1_2048_8192_SHA256, public)
            .verify(msg.as_bytes(), &sig)
            .unwrap();
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(&cfg.app_path)
            .unwrap()
            .permissions()
            .mode();
        assert_eq!(mode & 0o777, 0o600, "credentials are owner-only");
    }

    #[test]
    fn manifest_flow_guards() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("agent.toml");
        let no_url =
            AgentConfig::parse("[auth]\ntoken=\"0123456789abcdef\"\n", &p, dir.path()).unwrap();
        assert_eq!(
            Github::new(&no_url)
                .unwrap()
                .begin(None, None)
                .unwrap_err()
                .status,
            409
        );
        let cfg = AgentConfig::parse(
            "[auth]\ntoken=\"0123456789abcdef\"\n[server]\npublic_url=\"https://r.dev\"\n",
            &p,
            dir.path(),
        )
        .unwrap();
        let gh = Github::new(&cfg).unwrap();
        assert_eq!(
            gh.begin(Some("bad org!".into()), None).unwrap_err().status,
            400
        );
        let url = gh
            .begin(Some("acme".into()), Some("My <Roost>".into()))
            .unwrap();
        let state = url.split("state=").nth(1).unwrap();
        let html = gh.manifest_page(state).unwrap();
        assert!(html.contains("https://github.com/organizations/acme/settings/apps/new?state="));
        assert!(html.contains("My &lt;Roost&gt;"), "names are escaped");
        assert!(html.contains("https://r.dev/hooks/github"));
        assert!(gh.manifest_page("nope").is_none());
    }
}
