//! GitHub webhook payloads reduced to the fields triggers filter on and runs use.

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Longest text field kept (issue bodies, comments); the full payload travels alongside.
const MAX_TEXT: usize = 16 * 1024;

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(default)]
pub struct EventInfo {
    pub event: String,
    pub action: Option<String>,
    pub repo: Option<String>,
    pub default_branch: Option<String>,
    pub sender: Option<String>,
    pub sender_is_bot: bool,
    pub number: Option<u64>,
    pub title: Option<String>,
    pub body: Option<String>,
    pub url: Option<String>,
    /// Branch the event is about: pushed branch, PR base branch, workflow_run head branch.
    pub branch: Option<String>,
    pub sha: Option<String>,
    /// What a checkout fetches: a sha, `refs/pull/N/head`, `refs/tags/T` or a branch.
    pub fetch_ref: Option<String>,
    pub labels: Vec<String>,
    /// The label a `labeled`/`unlabeled` action is about.
    pub label: Option<String>,
    pub comment: Option<String>,
    /// `author_association` of the content's author (comment, review, issue or PR).
    pub association: Option<String>,
    pub workflow_name: Option<String>,
    pub conclusion: Option<String>,
    pub is_pr: bool,
    /// Repository the event's code comes from (PR head, workflow_run/check head), when known.
    pub head_repo: Option<String>,
    /// The code comes from another repository (a fork).
    pub from_fork: bool,
}

fn s(v: &Value, path: &[&str]) -> Option<String> {
    let mut cur = v;
    for p in path {
        cur = cur.get(p)?;
    }
    match cur {
        Value::String(x) => Some(x.clone()),
        Value::Number(n) => Some(n.to_string()),
        Value::Bool(b) => Some(b.to_string()),
        _ => None,
    }
}

fn u(v: &Value, path: &[&str]) -> Option<u64> {
    let mut cur = v;
    for p in path {
        cur = cur.get(p)?;
    }
    cur.as_u64()
}

fn labels(v: Option<&Value>) -> Vec<String> {
    v.and_then(|l| l.get("labels"))
        .and_then(Value::as_array)
        .map(|a| {
            a.iter()
                .filter_map(|l| l.get("name").and_then(Value::as_str).map(str::to_string))
                .collect()
        })
        .unwrap_or_default()
}

impl EventInfo {
    pub fn from_github(event: &str, p: &Value) -> EventInfo {
        let mut e = EventInfo {
            event: event.to_string(),
            action: s(p, &["action"]),
            repo: s(p, &["repository", "full_name"]),
            default_branch: s(p, &["repository", "default_branch"]),
            sender: s(p, &["sender", "login"]),
            sender_is_bot: s(p, &["sender", "type"]).as_deref() == Some("Bot"),
            label: s(p, &["label", "name"]),
            ..Default::default()
        };
        let issue = p.get("issue");
        let pr = p.get("pull_request");
        let comment = p.get("comment");
        let review = p.get("review");

        if let Some(pr) = pr {
            e.is_pr = true;
            e.number = u(pr, &["number"]);
            e.title = s(pr, &["title"]);
            e.body = s(pr, &["body"]);
            e.url = s(pr, &["html_url"]);
            e.branch = s(pr, &["base", "ref"]);
            e.sha = s(pr, &["head", "sha"]);
            e.labels = labels(Some(pr));
            e.association = s(pr, &["author_association"]);
            e.fetch_ref = e.number.map(|n| format!("refs/pull/{n}/head"));
        } else if let Some(issue) = issue {
            e.is_pr = issue.get("pull_request").is_some();
            e.number = u(issue, &["number"]);
            e.title = s(issue, &["title"]);
            e.body = s(issue, &["body"]);
            e.url = s(issue, &["html_url"]);
            e.labels = labels(Some(issue));
            e.association = s(issue, &["author_association"]);
            if e.is_pr {
                e.fetch_ref = e.number.map(|n| format!("refs/pull/{n}/head"));
            }
        }
        if let Some(r) = review {
            e.comment = s(r, &["body"]);
            e.association = s(r, &["author_association"]).or(e.association);
            e.url = s(r, &["html_url"]).or(e.url);
        }
        if let Some(c) = comment {
            e.comment = s(c, &["body"]);
            e.association = s(c, &["author_association"]).or(e.association);
            e.url = s(c, &["html_url"]).or(e.url);
        }

        match event {
            "push" => {
                let r = s(p, &["ref"]);
                e.branch = r
                    .as_deref()
                    .and_then(|r| r.strip_prefix("refs/heads/"))
                    .map(str::to_string);
                let deleted = p.get("deleted").and_then(Value::as_bool).unwrap_or(false);
                e.sha = s(p, &["after"]);
                if !deleted {
                    e.fetch_ref = e.sha.clone();
                }
                e.title = s(p, &["head_commit", "message"])
                    .map(|m| m.lines().next().unwrap_or_default().to_string());
                e.url = s(p, &["compare"]);
            }
            "workflow_run" | "check_suite" | "check_run" => {
                let key = event;
                e.workflow_name = s(p, &[key, "name"]).or_else(|| s(p, &[key, "app", "name"]));
                e.conclusion = s(p, &[key, "conclusion"]);
                e.sha = s(p, &[key, "head_sha"]);
                e.branch = s(p, &[key, "head_branch"])
                    .or_else(|| s(p, &[key, "check_suite", "head_branch"]));
                e.url = s(p, &[key, "html_url"]);
                e.title = e.workflow_name.clone();
                e.fetch_ref = e.sha.clone();
                if let Some(n) = p
                    .get(key)
                    .and_then(|w| w.get("pull_requests"))
                    .and_then(Value::as_array)
                    .and_then(|a| a.first())
                    .and_then(|pr| pr.get("number"))
                    .and_then(Value::as_u64)
                {
                    e.number = Some(n);
                    e.is_pr = true;
                }
            }
            "release" => {
                let tag = s(p, &["release", "tag_name"]);
                e.title = s(p, &["release", "name"]).or_else(|| tag.clone());
                e.body = s(p, &["release", "body"]);
                e.url = s(p, &["release", "html_url"]);
                e.fetch_ref = tag.map(|t| format!("refs/tags/{t}"));
            }
            "discussion" | "discussion_comment" => {
                if let Some(d) = p.get("discussion") {
                    e.number = u(d, &["number"]);
                    e.title = s(d, &["title"]);
                    if e.comment.is_none() {
                        e.body = s(d, &["body"]);
                    }
                    e.url = e.url.or_else(|| s(d, &["html_url"]));
                    e.association = e.association.or_else(|| s(d, &["author_association"]));
                }
            }
            _ => {}
        }
        if e.fetch_ref.is_none() {
            e.fetch_ref = e.default_branch.clone();
        }
        let head_repo = match event {
            "workflow_run" => s(p, &["workflow_run", "head_repository", "full_name"]),
            "check_suite" => s(p, &["check_suite", "head_repository", "full_name"]),
            "check_run" => s(
                p,
                &["check_run", "check_suite", "head_repository", "full_name"],
            ),
            _ => pr.and_then(|pr| s(pr, &["head", "repo", "full_name"])),
        };
        e.from_fork =
            matches!((&head_repo, &e.repo), (Some(h), Some(r)) if !h.eq_ignore_ascii_case(r));
        e.head_repo = head_repo;
        e.body = clip(e.body);
        e.comment = clip(e.comment);
        e
    }
}

/// Keeps at most `MAX_TEXT` bytes of a text field, cut at a character boundary.
fn clip(s: Option<String>) -> Option<String> {
    s.map(|mut t| {
        if t.len() > MAX_TEXT {
            let mut cut = MAX_TEXT;
            while cut > 0 && !t.is_char_boundary(cut) {
                cut -= 1;
            }
            t.truncate(cut);
            t.push('…');
        }
        t
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn comment_on_pr_extracts_fields() {
        let p = json!({
            "action": "created",
            "repository": {"full_name": "acme/web", "default_branch": "main"},
            "sender": {"login": "zed", "type": "User"},
            "issue": {"number": 4, "title": "T", "labels": [{"name": "bug"}],
                      "author_association": "NONE", "pull_request": {}},
            "comment": {"body": "/roost fix", "author_association": "MEMBER"}
        });
        let e = EventInfo::from_github("issue_comment", &p);
        assert!(e.is_pr);
        assert_eq!(e.fetch_ref.as_deref(), Some("refs/pull/4/head"));
        assert_eq!(
            e.association.as_deref(),
            Some("MEMBER"),
            "comment author wins"
        );
        assert_eq!(e.comment.as_deref(), Some("/roost fix"));
        assert_eq!(e.labels, vec!["bug".to_string()]);
    }

    #[test]
    fn push_branch_title_and_deleted() {
        let p = json!({"ref": "refs/heads/release/1.2", "after": "abc", "deleted": false,
            "repository": {"full_name": "a/b", "default_branch": "main"},
            "head_commit": {"message": "fix: x\n\nbody"}});
        let e = EventInfo::from_github("push", &p);
        assert_eq!(e.branch.as_deref(), Some("release/1.2"));
        assert_eq!(e.title.as_deref(), Some("fix: x"));
        assert_eq!(e.fetch_ref.as_deref(), Some("abc"));
        let del = EventInfo::from_github(
            "push",
            &json!({"ref": "refs/heads/x", "after": "000", "deleted": true,
                "repository": {"default_branch": "main"}}),
        );
        assert_eq!(
            del.fetch_ref.as_deref(),
            Some("main"),
            "deleted branch: default branch"
        );
    }

    #[test]
    fn workflow_run_fields() {
        let p = json!({"action": "completed", "workflow_run": {"name": "CI", "conclusion": "failure",
            "head_sha": "s1", "head_branch": "main", "pull_requests": [{"number": 9}]}});
        let e = EventInfo::from_github("workflow_run", &p);
        assert_eq!(e.workflow_name.as_deref(), Some("CI"));
        assert_eq!(e.conclusion.as_deref(), Some("failure"));
        assert_eq!(e.number, Some(9));
        assert!(e.is_pr);
        assert_eq!(e.fetch_ref.as_deref(), Some("s1"));
    }

    #[test]
    fn fork_origin_is_flagged() {
        let p = json!({"action": "completed", "repository": {"full_name": "acme/web"},
            "workflow_run": {"name": "CI", "head_sha": "s", "head_repository": {"full_name": "evil/web"}}});
        let e = EventInfo::from_github("workflow_run", &p);
        assert!(e.from_fork);
        assert_eq!(e.head_repo.as_deref(), Some("evil/web"));
        let same = json!({"repository": {"full_name": "acme/web"},
            "workflow_run": {"head_repository": {"full_name": "ACME/web"}}});
        assert!(!EventInfo::from_github("workflow_run", &same).from_fork);
        let unknown =
            json!({"repository": {"full_name": "acme/web"}, "check_suite": {"head_sha": "s"}});
        let e = EventInfo::from_github("check_suite", &unknown);
        assert!(
            !e.from_fork && e.head_repo.is_none(),
            "unknown origin is left to the client gate"
        );
    }

    #[test]
    fn labeled_pr_and_long_bodies() {
        let p = json!({"action": "labeled", "label": {"name": "roost"},
            "pull_request": {"number": 3, "base": {"ref": "main"}, "head": {"sha": "h"},
                "body": "é".repeat(MAX_TEXT),
                "labels": [{"name": "roost"}], "author_association": "CONTRIBUTOR"}});
        let e = EventInfo::from_github("pull_request", &p);
        assert_eq!(e.label.as_deref(), Some("roost"));
        assert_eq!(e.branch.as_deref(), Some("main"));
        assert_eq!(e.sha.as_deref(), Some("h"));
        assert_eq!(e.fetch_ref.as_deref(), Some("refs/pull/3/head"));
        assert!(e.body.unwrap().len() <= MAX_TEXT + '…'.len_utf8());
    }
}
