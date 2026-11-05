//! GitHub: webhook signatures and repository webhook registration.
//!
//! Hook sync is the "set it from the plugin" path: for every `[repos]` entry with `hook = true` it
//! creates or updates one webhook pointing at this agent, subscribed to the events the workflows
//! use. When that can't work (no token, no public URL, missing permission), each repo's result
//! carries the exact values to enter by hand in the repository's Settings › Webhooks.

use std::collections::BTreeSet;
use std::time::Duration;

use hmac::{Hmac, Mac};
use serde::Serialize;
use serde_json::{Value, json};
use sha2::Sha256;

use crate::config::{AgentConfig, Subscriptions};

/// Largest GitHub API response read.
const MAX_API_RESPONSE: usize = 4 * 1024 * 1024;

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

#[derive(Debug, Clone, Serialize)]
pub struct ManualHook {
    pub settings_url: String,
    pub payload_url: Option<String>,
    pub content_type: &'static str,
    pub secret: &'static str,
    pub events: Vec<String>,
    pub ssl_verification: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct HookResult {
    pub repo: String,
    /// `created`, `updated`, `unchanged`, `unused`, `disabled`, `manual` or `error`.
    pub status: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub hook_id: Option<u64>,
    pub events: Vec<String>,
    /// Present whenever the hook has to be set up by hand.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub manual: Option<ManualHook>,
}

#[derive(Debug, Clone, Serialize)]
pub struct SyncReport {
    pub at: chrono::DateTime<chrono::Utc>,
    pub dry_run: bool,
    /// Why the agent can't sync by itself, when it can't.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub blocked: Option<String>,
    pub repos: Vec<HookResult>,
}

fn manual_for(cfg: &AgentConfig, repo: &str, events: &[String]) -> ManualHook {
    ManualHook {
        settings_url: format!("{}/{}/settings/hooks/new", cfg.web_url, repo),
        payload_url: cfg.webhook_url(),
        content_type: "application/json",
        secret: "the value of [github].webhook_secret in agent.toml",
        events: events.to_vec(),
        ssl_verification: true,
    }
}

pub async fn sync_hooks(cfg: &AgentConfig, subs: &Subscriptions, dry_run: bool) -> SyncReport {
    let blocked = match (&cfg.github_token, cfg.webhook_url(), &cfg.webhook_secret) {
        (_, None, _) => Some("server.public_url is not set in agent.toml".to_string()),
        (_, _, None) => Some("github.webhook_secret is not set in agent.toml".to_string()),
        (None, _, _) => Some("github.token is not set in agent.toml".to_string()),
        _ => None,
    };
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(20))
        .user_agent(concat!("roost-agent/", env!("CARGO_PKG_VERSION")))
        .build();
    let mut repos = Vec::new();
    for (name, sub) in &subs.repos {
        let events: Vec<String> = sub.events.iter().cloned().collect();
        let mut res = HookResult {
            repo: name.clone(),
            status: String::new(),
            message: None,
            hook_id: None,
            events: events.clone(),
            manual: None,
        };
        if !sub.hook {
            res.status = "disabled".into();
            res.message = Some("hook = false: managed by hand".into());
            repos.push(res);
            continue;
        }
        if events.is_empty() {
            res.status = "unused".into();
            res.message = Some("no events subscribed for this repo".into());
            repos.push(res);
            continue;
        }
        if let Some(b) = &blocked {
            res.status = "manual".into();
            res.message = Some(b.clone());
            res.manual = Some(manual_for(cfg, name, &events));
            repos.push(res);
            continue;
        }
        let client = match &client {
            Ok(c) => c,
            Err(e) => {
                res.status = "error".into();
                res.message = Some(format!("http client: {e}"));
                res.manual = Some(manual_for(cfg, name, &events));
                repos.push(res);
                continue;
            }
        };
        match sync_one(cfg, client, name, &events, dry_run).await {
            Ok((status, id)) => {
                res.status = status;
                res.hook_id = id;
            }
            Err(msg) => {
                res.status = "manual".into();
                res.message = Some(msg);
                res.manual = Some(manual_for(cfg, name, &events));
            }
        }
        repos.push(res);
    }
    SyncReport {
        at: chrono::Utc::now(),
        dry_run,
        blocked,
        repos,
    }
}

async fn api(
    cfg: &AgentConfig,
    client: &reqwest::Client,
    method: reqwest::Method,
    path: &str,
    body: Option<Value>,
) -> Result<Value, String> {
    let token = cfg
        .github_token
        .as_ref()
        .map(|t| t.expose().to_string())
        .unwrap_or_default();
    let mut req = client
        .request(method.clone(), format!("{}{}", cfg.api_url, path))
        .bearer_auth(token)
        .header("Accept", "application/vnd.github+json")
        .header("X-GitHub-Api-Version", "2022-11-28");
    if let Some(b) = body {
        req = req.json(&b);
    }
    let mut resp = req
        .send()
        .await
        .map_err(|e| format!("{method} {path}: {e}"))?;
    let status = resp.status();
    // Hook lists are small; stop reading past the cap instead of buffering whatever arrives.
    let mut bytes = Vec::new();
    while let Some(chunk) = resp
        .chunk()
        .await
        .map_err(|e| format!("{method} {path}: {e}"))?
    {
        if bytes.len() + chunk.len() > MAX_API_RESPONSE {
            return Err(format!("{method} {path}: response too large"));
        }
        bytes.extend_from_slice(&chunk);
    }
    if !status.is_success() {
        let msg = serde_json::from_slice::<Value>(&bytes)
            .ok()
            .and_then(|v| v.get("message").and_then(Value::as_str).map(str::to_string))
            .unwrap_or_default();
        let hint = match status.as_u16() {
            401 => " (token invalid or expired)",
            403 | 404 => {
                " (the token needs admin rights on the repo: classic scope admin:repo_hook, or fine-grained Webhooks: read and write)"
            }
            _ => "",
        };
        return Err(format!(
            "GitHub {} on {method} {path}: {msg}{hint}",
            status.as_u16()
        ));
    }
    if bytes.is_empty() {
        return Ok(Value::Null);
    }
    serde_json::from_slice(&bytes).map_err(|e| format!("{method} {path}: bad JSON: {e}"))
}

async fn sync_one(
    cfg: &AgentConfig,
    client: &reqwest::Client,
    repo: &str,
    events: &[String],
    dry_run: bool,
) -> Result<(String, Option<u64>), String> {
    let url = cfg.webhook_url().unwrap_or_default();
    let secret = cfg
        .webhook_secret
        .as_ref()
        .map(|s| s.expose().to_string())
        .unwrap_or_default();
    let hooks = api(
        cfg,
        client,
        reqwest::Method::GET,
        &format!("/repos/{repo}/hooks?per_page=100"),
        None,
    )
    .await?;
    let existing = hooks.as_array().and_then(|a| {
        a.iter().find(|h| {
            h.get("config")
                .and_then(|c| c.get("url"))
                .and_then(Value::as_str)
                == Some(url.as_str())
        })
    });
    let want: BTreeSet<&str> = events.iter().map(String::as_str).collect();
    let config = json!({"url": url, "content_type": "json", "secret": secret, "insecure_ssl": "0"});
    match existing {
        Some(h) => {
            let id = h.get("id").and_then(Value::as_u64);
            let have: BTreeSet<&str> = h
                .get("events")
                .and_then(Value::as_array)
                .map(|a| a.iter().filter_map(Value::as_str).collect())
                .unwrap_or_default();
            let active = h.get("active").and_then(Value::as_bool).unwrap_or(false);
            let json_ct = h
                .get("config")
                .and_then(|c| c.get("content_type"))
                .and_then(Value::as_str)
                == Some("json");
            // The secret can't be read back, so it is rewritten on every real update.
            if have == want && active && json_ct {
                return Ok(("unchanged".into(), id));
            }
            if dry_run {
                return Ok(("would_update".into(), id));
            }
            let Some(hid) = id else {
                return Err("hook without id in GitHub's answer".into());
            };
            api(
                cfg,
                client,
                reqwest::Method::PATCH,
                &format!("/repos/{repo}/hooks/{hid}"),
                Some(json!({"active": true, "events": events, "config": config})),
            )
            .await?;
            Ok(("updated".into(), id))
        }
        None => {
            if dry_run {
                return Ok(("would_create".into(), None));
            }
            let created = api(
                cfg,
                client,
                reqwest::Method::POST,
                &format!("/repos/{repo}/hooks"),
                Some(json!({"name": "web", "active": true, "events": events, "config": config})),
            )
            .await?;
            Ok(("created".into(), created.get("id").and_then(Value::as_u64)))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

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

    fn sub(text: &str) -> Subscriptions {
        Subscriptions::parse(text).unwrap()
    }

    #[tokio::test]
    async fn unused_and_disabled_repos_skip_github() {
        let dir = tempfile::tempdir().unwrap();
        let cfg = AgentConfig::parse(
            "[auth]\ntoken=\"0123456789abcdef\"\n",
            &dir.path().join("agent.toml"),
            dir.path(),
        )
        .unwrap();
        let s = sub("[repos.\"a/one\"]\n[repos.\"a/two\"]\nevents=[\"push\"]\nhook=false\n");
        let r = sync_hooks(&cfg, &s, false).await;
        let st: Vec<_> = r.repos.iter().map(|x| x.status.as_str()).collect();
        assert_eq!(st, vec!["unused", "disabled"]);
    }

    #[tokio::test]
    async fn sync_without_token_falls_back_to_manual() {
        let dir = tempfile::tempdir().unwrap();
        let cfg = AgentConfig::parse(
            "[auth]\ntoken=\"0123456789abcdef\"\n[server]\npublic_url=\"https://r.dev\"\n[github]\nwebhook_secret=\"x\"\n",
            &dir.path().join("agent.toml"),
            dir.path(),
        )
        .unwrap();
        let w = sub("[repos.\"a/b\"]\nevents = [\"issues\"]\n");
        let r = sync_hooks(&cfg, &w, false).await;
        assert!(r.blocked.as_deref().unwrap().contains("github.token"));
        let m = r.repos[0].manual.as_ref().unwrap();
        assert_eq!(r.repos[0].status, "manual");
        assert_eq!(m.payload_url.as_deref(), Some("https://r.dev/hooks/github"));
        assert_eq!(m.events, vec!["issues"]);
        assert_eq!(m.settings_url, "https://github.com/a/b/settings/hooks/new");
    }
}
