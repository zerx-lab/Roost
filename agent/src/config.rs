//! Configuration files.
//!
//! * `agent.toml`: server binding (listen address, admin token, GitHub API base, storage
//!   limits). Never synced: secrets stay on the server; changes take a restart. The GitHub App's
//!   credentials live next to the data in `github-app.json`, written by the registration flow.
//! * `subscriptions.toml`: which repos the relay accepts and which events each needs. Pushed by
//!   the plugin (computed from its local workflows) and hot-reloaded; editable by hand on the
//!   server when the push can't reach it, then applied with a remote reload. `"*"` is any repo.

use std::collections::{BTreeMap, BTreeSet};
use std::io::Read;
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::time::Duration;

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::secret::Secret;

/// Upper bound for either config file.
pub const MAX_CONFIG_BYTES: u64 = 1024 * 1024;
/// Upper bound for subscribed repos (one webhook each).
pub const MAX_REPOS: usize = 500;

/// One problem found in a config file. `line`/`col` are 1-based when known.
#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
pub struct Issue {
    pub path: String,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub line: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub col: Option<usize>,
}

impl Issue {
    pub fn new(path: impl Into<String>, message: impl Into<String>) -> Issue {
        Issue {
            path: path.into(),
            message: message.into(),
            line: None,
            col: None,
        }
    }
}

impl std::fmt::Display for Issue {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match (self.line, self.col) {
            (Some(l), Some(c)) => write!(f, "{}:{}: {}: {}", l, c, self.path, self.message),
            _ => write!(f, "{}: {}", self.path, self.message),
        }
    }
}

/// 1-based line and column of byte `offset` in `text`.
pub fn line_col(text: &str, offset: usize) -> (usize, usize) {
    let mut line = 1;
    let mut col = 1;
    for (i, ch) in text.char_indices() {
        if i >= offset {
            break;
        }
        if ch == '\n' {
            line += 1;
            col = 1;
        } else {
            col += 1;
        }
    }
    (line, col)
}

pub fn read_bounded(path: &Path) -> Result<String, String> {
    let file =
        std::fs::File::open(path).map_err(|e| format!("cannot open {}: {e}", path.display()))?;
    let mut text = String::new();
    file.take(MAX_CONFIG_BYTES + 1)
        .read_to_string(&mut text)
        .map_err(|e| format!("cannot read {}: {e}", path.display()))?;
    if text.len() as u64 > MAX_CONFIG_BYTES {
        return Err(format!(
            "{} is larger than {MAX_CONFIG_BYTES} bytes",
            path.display()
        ));
    }
    Ok(text)
}

fn toml_issue(text: &str, file: &str, e: &toml::de::Error) -> Issue {
    let mut issue = Issue::new(file, e.message());
    if let Some(r) = e.span() {
        let (l, c) = line_col(text, r.start);
        issue.line = Some(l);
        issue.col = Some(c);
    }
    issue
}

/// Parses `90`, `90s`, `30m`, `2h`, `1h30m`, `7d`.
pub fn parse_duration(s: &str) -> Result<Duration, String> {
    let s = s.trim();
    if s.is_empty() {
        return Err("empty duration".into());
    }
    if let Ok(n) = s.parse::<u64>() {
        return Ok(Duration::from_secs(n));
    }
    let mut total: u64 = 0;
    let mut num = String::new();
    for ch in s.chars() {
        if ch.is_ascii_digit() {
            num.push(ch);
            continue;
        }
        let mult = match ch {
            's' => 1,
            'm' => 60,
            'h' => 3600,
            'd' => 86400,
            _ => {
                return Err(format!(
                    "bad duration {s:?}: unknown unit {ch:?} (s, m, h, d)"
                ));
            }
        };
        let n: u64 = num
            .parse()
            .map_err(|_| format!("bad duration {s:?}: a number must precede {ch:?}"))?;
        total = n
            .checked_mul(mult)
            .and_then(|v| total.checked_add(v))
            .ok_or_else(|| format!("duration {s:?} is too large"))?;
        num.clear();
    }
    if !num.is_empty() {
        return Err(format!("bad duration {s:?}: trailing number without unit"));
    }
    Ok(Duration::from_secs(total))
}

// ---------------------------------------------------------------------------------------------
// agent.toml

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct AgentFile {
    #[serde(default)]
    server: ServerRaw,
    #[serde(default)]
    auth: AuthRaw,
    #[serde(default)]
    github: GithubRaw,
    #[serde(default)]
    store: StoreRaw,
    #[serde(default)]
    paths: PathsRaw,
}

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct ServerRaw {
    listen: Option<String>,
    public_url: Option<String>,
    max_body_bytes: Option<u64>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct AuthRaw {
    token: Option<String>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct GithubRaw {
    api_url: Option<String>,
    web_url: Option<String>,
    /// Where the GitHub App credentials are kept (default `<data>/github-app.json`).
    app: Option<String>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct StoreRaw {
    keep_events: Option<usize>,
    max_age: Option<String>,
    max_payload_bytes: Option<u64>,
    max_total_bytes: Option<u64>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct PathsRaw {
    data: Option<String>,
    subscriptions: Option<String>,
}

/// Resolved `agent.toml`.
#[derive(Debug, Clone)]
pub struct AgentConfig {
    pub path: PathBuf,
    pub listen: SocketAddr,
    pub public_url: Option<String>,
    pub max_body_bytes: usize,
    pub admin_token: Secret,
    pub api_url: String,
    pub web_url: String,
    pub app_path: PathBuf,
    pub keep_events: usize,
    pub max_age: Duration,
    pub max_payload_bytes: usize,
    pub max_total_bytes: usize,
    pub data_dir: PathBuf,
    pub subscriptions_path: PathBuf,
}

fn bounded(
    issues: &mut Vec<Issue>,
    key: &str,
    v: Option<u64>,
    default: u64,
    range: std::ops::RangeInclusive<u64>,
) -> u64 {
    let v = v.unwrap_or(default);
    if !range.contains(&v) {
        issues.push(Issue::new(
            key,
            format!("must be {}..={}", range.start(), range.end()),
        ));
        return default;
    }
    v
}

fn as_usize(v: u64) -> usize {
    usize::try_from(v).unwrap_or(usize::MAX)
}

impl AgentConfig {
    pub fn webhook_url(&self) -> Option<String> {
        self.public_url
            .as_ref()
            .map(|u| format!("{u}/hooks/github"))
    }

    pub fn load(path: &Path) -> Result<AgentConfig, Vec<Issue>> {
        let text =
            read_bounded(path).map_err(|m| vec![Issue::new(path.display().to_string(), m)])?;
        let base = path
            .parent()
            .map(Path::to_path_buf)
            .unwrap_or_else(|| PathBuf::from("."));
        Self::parse(&text, path, &base)
    }

    pub fn parse(text: &str, path: &Path, base: &Path) -> Result<AgentConfig, Vec<Issue>> {
        let label = path.display().to_string();
        let raw: AgentFile =
            toml::from_str(text).map_err(|e| vec![toml_issue(text, &label, &e)])?;
        let mut issues = Vec::new();

        let listen_s = raw
            .server
            .listen
            .clone()
            .unwrap_or_else(|| "127.0.0.1:8787".into());
        let listen: SocketAddr = listen_s.parse().unwrap_or_else(|e| {
            issues.push(Issue::new("server.listen", format!("{listen_s:?}: {e}")));
            SocketAddr::from(([127, 0, 0, 1], 8787))
        });
        let public_url = raw
            .server
            .public_url
            .clone()
            .map(|u| u.trim().trim_end_matches('/').to_string())
            .filter(|s| !s.is_empty());
        if let Some(u) = &public_url
            && !(u.starts_with("https://") || u.starts_with("http://"))
        {
            issues.push(Issue::new(
                "server.public_url",
                "must start with https:// or http://",
            ));
        }

        let mut secret = |key: &str, spec: &Option<String>| -> Option<Secret> {
            match Secret::resolve(spec.as_deref()?, base) {
                Ok(s) => s,
                Err(e) => {
                    issues.push(Issue::new(key, e));
                    None
                }
            }
        };
        let admin_token = secret("auth.token", &raw.auth.token);
        let admin_token = match admin_token {
            Some(t) if t.expose().len() >= 16 => t,
            Some(_) => {
                issues.push(Issue::new("auth.token", "must be at least 16 characters"));
                Secret::default()
            }
            None => {
                issues.push(Issue::new(
                    "auth.token",
                    "required: the plugin authenticates with it (literal, env:NAME or file:PATH)",
                ));
                Secret::default()
            }
        };

        let max_body_bytes = bounded(
            &mut issues,
            "server.max_body_bytes",
            raw.server.max_body_bytes,
            25 * 1024 * 1024,
            1024..=100 * 1024 * 1024,
        );
        let keep_events = bounded(
            &mut issues,
            "store.keep_events",
            raw.store.keep_events.map(|v| v as u64),
            2000,
            10..=100_000,
        );
        let max_payload_bytes = bounded(
            &mut issues,
            "store.max_payload_bytes",
            raw.store.max_payload_bytes,
            2 * 1024 * 1024,
            0..=32 * 1024 * 1024,
        );
        let max_total_bytes = bounded(
            &mut issues,
            "store.max_total_bytes",
            raw.store.max_total_bytes,
            256 * 1024 * 1024,
            1024 * 1024..=8 * 1024 * 1024 * 1024,
        );
        let max_age = match parse_duration(raw.store.max_age.as_deref().unwrap_or("7d")) {
            Ok(d) if d >= Duration::from_secs(60) => d,
            Ok(_) => {
                issues.push(Issue::new("store.max_age", "must be at least 1m"));
                Duration::from_secs(7 * 86400)
            }
            Err(e) => {
                issues.push(Issue::new("store.max_age", e));
                Duration::from_secs(7 * 86400)
            }
        };

        if !issues.is_empty() {
            return Err(issues);
        }
        let data_dir = base.join(raw.paths.data.as_deref().unwrap_or("data"));
        Ok(AgentConfig {
            path: path.to_path_buf(),
            listen,
            public_url,
            max_body_bytes: as_usize(max_body_bytes),
            admin_token,
            api_url: raw
                .github
                .api_url
                .unwrap_or_else(|| "https://api.github.com".into())
                .trim_end_matches('/')
                .to_string(),
            web_url: raw
                .github
                .web_url
                .unwrap_or_else(|| "https://github.com".into())
                .trim_end_matches('/')
                .to_string(),
            app_path: match raw.github.app.as_deref() {
                Some(p) => base.join(p),
                None => data_dir.join("github-app.json"),
            },
            keep_events: as_usize(keep_events),
            max_age,
            max_payload_bytes: as_usize(max_payload_bytes),
            max_total_bytes: as_usize(max_total_bytes),
            data_dir,
            subscriptions_path: base.join(
                raw.paths
                    .subscriptions
                    .as_deref()
                    .unwrap_or("subscriptions.toml"),
            ),
        })
    }
}

// ---------------------------------------------------------------------------------------------
// subscriptions.toml

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct RepoSub {
    /// GitHub event names the relay keeps for this repo (`"*"`: every event).
    #[serde(default)]
    pub events: BTreeSet<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
struct SubsFile {
    #[serde(default)]
    repos: BTreeMap<String, RepoSub>,
    /// Workflows outside callers may start (`POST /hooks/dispatch/<id>`): id → SHA-256 (hex) of
    /// the bearer token that may start it. The token itself never reaches the relay.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    dispatch: BTreeMap<String, String>,
}

/// A validated `subscriptions.toml`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Subscriptions {
    pub revision: String,
    pub text: String,
    pub repos: BTreeMap<String, RepoSub>,
    pub dispatch: BTreeMap<String, String>,
}

const SUBS_HEADER: &str = "# Roost relay subscriptions: repos this agent accepts webhooks for, and the\n\
# events each needs. Written by the Roost plugin (PUT /api/v1/subscriptions).\n\
# Edited by hand? Apply it with the plugin's Reload button or POST /api/v1/reload.\n\n";

impl Subscriptions {
    pub fn empty() -> Subscriptions {
        Subscriptions {
            revision: revision_of(""),
            text: String::new(),
            repos: BTreeMap::new(),
            dispatch: BTreeMap::new(),
        }
    }

    /// Whether `event` of `repo` is subscribed: by the repo's own entry (case-insensitive, as
    /// GitHub names are) or by the `"*"` entry for any repo.
    pub fn wants(&self, repo: &str, event: &str) -> bool {
        self.repos.iter().any(|(k, s)| {
            (k == ANY_REPO || k.eq_ignore_ascii_case(repo))
                && (s.events.contains(event) || s.events.contains("*"))
        })
    }

    /// A named repo to point a test event at (not the `"*"` entry).
    pub fn first_repo(&self) -> Option<String> {
        self.repos.keys().find(|k| k.as_str() != ANY_REPO).cloned()
    }

    pub fn load(path: &Path) -> Result<Subscriptions, Vec<Issue>> {
        if !path.exists() {
            return Ok(Subscriptions::empty());
        }
        let text =
            read_bounded(path).map_err(|m| vec![Issue::new(path.display().to_string(), m)])?;
        Self::parse(&text)
    }

    pub fn parse(text: &str) -> Result<Subscriptions, Vec<Issue>> {
        if text.len() as u64 > MAX_CONFIG_BYTES {
            return Err(vec![Issue::new("subscriptions.toml", "file too large")]);
        }
        let raw: SubsFile =
            toml::from_str(text).map_err(|e| vec![toml_issue(text, "subscriptions.toml", &e)])?;
        let repos = validate_repos(raw.repos)?;
        let dispatch = validate_dispatch(raw.dispatch)?;
        Ok(Subscriptions {
            revision: revision_of(text),
            text: text.to_string(),
            repos,
            dispatch,
        })
    }

    /// Canonical file text for `repos` and `dispatch` (what a push writes).
    pub fn from_parts(
        repos: BTreeMap<String, RepoSub>,
        dispatch: BTreeMap<String, String>,
    ) -> Result<Subscriptions, Vec<Issue>> {
        let repos = validate_repos(repos)?;
        let dispatch = validate_dispatch(dispatch)?;
        let body = toml::to_string(&SubsFile {
            repos: repos.clone(),
            dispatch: dispatch.clone(),
        })
        .map_err(|e| vec![Issue::new("subscriptions", e.to_string())])?;
        let text = format!("{SUBS_HEADER}{body}");
        Ok(Subscriptions {
            revision: revision_of(&text),
            text,
            repos,
            dispatch,
        })
    }
}

/// At most this many workflows may be started from outside.
pub const MAX_DISPATCH: usize = 100;

/// A workflow id as Roost writes them (lowercase letters, digits, `-`, `_`).
pub fn valid_workflow_id(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 64
        && s.chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-' || c == '_')
}

fn validate_dispatch(
    dispatch: BTreeMap<String, String>,
) -> Result<BTreeMap<String, String>, Vec<Issue>> {
    let mut issues = Vec::new();
    if dispatch.len() > MAX_DISPATCH {
        issues.push(Issue::new(
            "dispatch",
            format!("at most {MAX_DISPATCH} workflows"),
        ));
    }
    for (id, hash) in &dispatch {
        if !valid_workflow_id(id) {
            issues.push(Issue::new(format!("dispatch.{id:?}"), "not a workflow id"));
        }
        if hash.len() != 64
            || !hash
                .chars()
                .all(|c| c.is_ascii_digit() || ('a'..='f').contains(&c))
        {
            issues.push(Issue::new(
                format!("dispatch.{id:?}"),
                "must be the token's SHA-256 as 64 lowercase hex digits",
            ));
        }
    }
    if issues.is_empty() {
        Ok(dispatch)
    } else {
        Err(issues)
    }
}

fn validate_repos(
    repos: BTreeMap<String, RepoSub>,
) -> Result<BTreeMap<String, RepoSub>, Vec<Issue>> {
    let mut issues = Vec::new();
    if repos.len() > MAX_REPOS {
        issues.push(Issue::new("repos", format!("at most {MAX_REPOS} repos")));
    }
    let mut seen = BTreeSet::new();
    for (name, sub) in &repos {
        let path = format!("repos.{name:?}");
        if name != ANY_REPO && !valid_repo_name(name) {
            issues.push(Issue::new(
                &path,
                "repo keys must be \"owner/name\" or \"*\"",
            ));
        }
        if !seen.insert(name.to_ascii_lowercase()) {
            issues.push(Issue::new(
                &path,
                "duplicate repo (names are case-insensitive)",
            ));
        }
        for e in &sub.events {
            if !valid_event(e) {
                issues.push(Issue::new(
                    format!("{path}.events"),
                    format!("{e:?} is not a GitHub event name (issues, pull_request, push, …)"),
                ));
            }
        }
    }
    if issues.is_empty() {
        Ok(repos)
    } else {
        Err(issues)
    }
}

/// The subscriptions key that matches every repository.
pub const ANY_REPO: &str = "*";

pub fn valid_event(e: &str) -> bool {
    !e.is_empty() && e.len() <= 64 && e.chars().all(|c| c.is_ascii_lowercase() || c == '_')
}

pub fn valid_repo_name(s: &str) -> bool {
    let ok = |p: &str| {
        !p.is_empty()
            && p.len() <= 100
            && p != "."
            && p != ".."
            && p.chars()
                .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_' || c == '.')
    };
    match s.split_once('/') {
        Some((owner, name)) => ok(owner) && ok(name),
        None => false,
    }
}

pub fn revision_of(text: &str) -> String {
    let digest = Sha256::digest(text.as_bytes());
    hex::encode(digest.get(..8).unwrap_or_default())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn subscriptions_roundtrip_wildcard_and_validation() {
        let mut repos = BTreeMap::new();
        repos.insert(
            "acme/web".to_string(),
            RepoSub {
                events: ["issues".to_string(), "push".to_string()].into(),
            },
        );
        repos.insert(
            "*".to_string(),
            RepoSub {
                events: ["release".to_string()].into(),
            },
        );
        let s = Subscriptions::from_parts(repos.clone(), BTreeMap::new()).unwrap();
        let back = Subscriptions::parse(&s.text).unwrap();
        assert_eq!(back.repos, repos);
        assert_eq!(back.revision, s.revision);
        assert!(s.wants("ACME/Web", "push"), "names are case-insensitive");
        assert!(!s.wants("acme/other", "push"), "push only for acme/web");
        assert!(s.wants("acme/other", "release"), "\"*\" covers any repo");
        assert_eq!(s.first_repo().as_deref(), Some("acme/web"));

        let e = Subscriptions::parse("[repos.\"bad\"]\nevents = [\"Issues\"]\n").unwrap_err();
        assert_eq!(e.len(), 2, "{e:?}");
        let e = Subscriptions::parse("[repos.\"a/b\"]\nhook = true\n").unwrap_err();
        assert_eq!(e[0].line, Some(2), "{e:?}");
    }

    #[test]
    fn durations() {
        assert_eq!(parse_duration("90").unwrap(), Duration::from_secs(90));
        assert_eq!(parse_duration("1h30m").unwrap(), Duration::from_secs(5400));
        assert!(parse_duration("5x").is_err());
        assert!(parse_duration("m").is_err());
        assert!(parse_duration("3m5").is_err());
    }

    #[test]
    fn agent_config_requires_token_and_resolves_paths() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("agent.toml");
        let err = AgentConfig::parse("", &p, dir.path()).unwrap_err();
        assert!(err.iter().any(|e| e.path == "auth.token"));
        let ok = AgentConfig::parse(
            "[auth]\ntoken = \"0123456789abcdef\"\n[server]\npublic_url = \"https://x.dev/\"\n",
            &p,
            dir.path(),
        )
        .unwrap();
        assert_eq!(
            ok.webhook_url().as_deref(),
            Some("https://x.dev/hooks/github")
        );
        assert_eq!(ok.subscriptions_path, dir.path().join("subscriptions.toml"));
        let bad = AgentConfig::parse(
            "[auth]\ntoken = \"0123456789abcdef\"\n[store]\nkeep_events = 1\n",
            &p,
            dir.path(),
        )
        .unwrap_err();
        assert_eq!(bad[0].path, "store.keep_events");
    }

    #[test]
    fn names() {
        assert!(valid_repo_name("a-b/c.d_e"));
        assert!(!valid_repo_name("a/b/c"));
        assert!(!valid_repo_name("../x"));
        assert!(valid_event("pull_request_review"));
        assert!(!valid_event("push!"));
    }
}
