//! roost-agent: a small relay node for the Roost Tern plugin.
//!
//! GitHub can't reach a laptop, so this runs on a server with a public URL: it verifies GitHub
//! webhooks, keeps the ones the plugin subscribed to, and hands them out to the plugin's
//! long-poll. It runs no workflows itself; omp runs on the plugin side.

mod api;
mod config;
mod event;
mod github;
mod secret;
mod store;
mod util;

use std::collections::{BTreeMap, VecDeque};
use std::ffi::OsString;
use std::path::PathBuf;
use std::process::ExitCode;
use std::sync::{Arc, Mutex, RwLock};
use std::time::Duration;

use chrono::Utc;
use sha2::{Digest, Sha256};
use tokio::sync::watch;

use crate::api::{AppState, Shutdown};
use crate::config::{AgentConfig, Issue, Subscriptions};
use crate::store::{EventStore, Limits};

const USAGE: &str = "usage: roost-agent [serve|check|version] [--config PATH]

  serve     run the relay (default)
  check     validate agent.toml and subscriptions.toml, then exit
  version   print the version

  --config  agent.toml path (default ./agent.toml, or $ROOST_AGENT_CONFIG)";

struct Args {
    command: String,
    config: PathBuf,
}

fn parse_args(argv: &[OsString]) -> Result<Args, String> {
    let mut command = None;
    let mut config = std::env::var_os("ROOST_AGENT_CONFIG").map(PathBuf::from);
    let mut it = argv.iter().skip(1);
    while let Some(a) = it.next() {
        let a = a.to_string_lossy();
        match a.as_ref() {
            "--config" | "-c" => {
                let v = it.next().ok_or("--config needs a path")?;
                config = Some(PathBuf::from(v));
            }
            "-h" | "--help" | "help" => return Err(String::new()),
            s if s.starts_with("--config=") => {
                config = Some(PathBuf::from(s.trim_start_matches("--config=")));
            }
            "serve" | "check" | "version" if command.is_none() => command = Some(a.to_string()),
            other => return Err(format!("unknown argument {other:?}")),
        }
    }
    Ok(Args {
        command: command.unwrap_or_else(|| "serve".into()),
        config: config.unwrap_or_else(|| PathBuf::from("agent.toml")),
    })
}

fn print_issues(what: &str, list: &[Issue]) {
    eprintln!("{what}:");
    for i in list {
        eprintln!("  {i}");
    }
}

fn main() -> ExitCode {
    let argv: Vec<OsString> = std::env::args_os().collect();
    // Captured before anything can replace the binary on disk, so a restart execs the new one.
    let exe = std::env::current_exe().ok();
    let args = match parse_args(&argv) {
        Ok(a) => a,
        Err(e) => {
            if !e.is_empty() {
                eprintln!("{e}\n");
            }
            eprintln!("{USAGE}");
            return if e.is_empty() {
                ExitCode::SUCCESS
            } else {
                ExitCode::from(2)
            };
        }
    };
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_env("ROOST_LOG")
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .with_target(false)
        .init();

    match args.command.as_str() {
        "version" => {
            println!("roost-agent {}", env!("CARGO_PKG_VERSION"));
            ExitCode::SUCCESS
        }
        "check" => check(&args.config),
        _ => {
            let rt = match tokio::runtime::Builder::new_multi_thread()
                .enable_all()
                .build()
            {
                Ok(rt) => rt,
                Err(e) => {
                    eprintln!("cannot start runtime: {e}");
                    return ExitCode::FAILURE;
                }
            };
            let outcome = rt.block_on(serve(&args.config));
            drop(rt);
            match outcome {
                Ok(Shutdown::Stop) => ExitCode::SUCCESS,
                Ok(Shutdown::Restart) => reexec(exe, &argv),
                Err(code) => code,
            }
        }
    }
}

fn check(path: &std::path::Path) -> ExitCode {
    let cfg = match AgentConfig::load(path) {
        Ok(c) => c,
        Err(list) => {
            print_issues(&path.display().to_string(), &list);
            return ExitCode::from(2);
        }
    };
    match Subscriptions::load(&cfg.subscriptions_path) {
        Ok(s) => {
            println!("agent.toml ok: listen {}", cfg.listen);
            println!(
                "webhook url: {}",
                cfg.webhook_url()
                    .unwrap_or_else(|| "(server.public_url not set)".into())
            );
            println!(
                "subscriptions ok: {} repos, revision {}",
                s.repos.len(),
                s.revision
            );
            ExitCode::SUCCESS
        }
        Err(list) => {
            print_issues(&cfg.subscriptions_path.display().to_string(), &list);
            ExitCode::from(2)
        }
    }
}

fn reexec(exe: Option<PathBuf>, argv: &[OsString]) -> ExitCode {
    use std::os::unix::process::CommandExt;
    let Some(exe) = exe else {
        tracing::error!("cannot find own executable; exiting so a supervisor restarts it");
        return ExitCode::from(75);
    };
    tracing::info!("restarting: exec {}", exe.display());
    let err = std::process::Command::new(&exe)
        .args(argv.iter().skip(1))
        .exec();
    tracing::error!(
        "exec {} failed: {err}; exiting so a supervisor restarts it",
        exe.display()
    );
    ExitCode::from(75)
}

async fn serve(path: &std::path::Path) -> Result<Shutdown, ExitCode> {
    let cfg = AgentConfig::load(path).map_err(|list| {
        print_issues(&path.display().to_string(), &list);
        ExitCode::from(2)
    })?;
    let subs = match Subscriptions::load(&cfg.subscriptions_path) {
        Ok(s) => s,
        Err(list) => {
            // Start anyway: the plugin can push a fixed file, or it can be fixed by hand + reload.
            print_issues(&cfg.subscriptions_path.display().to_string(), &list);
            tracing::warn!("starting with no subscriptions");
            Subscriptions::empty()
        }
    };
    let store = EventStore::open(
        cfg.data_dir.clone(),
        Limits {
            keep: cfg.keep_events,
            max_age: cfg.max_age,
            max_total_bytes: cfg.max_total_bytes,
            max_file_bytes: (cfg.max_payload_bytes as u64) + 1024 * 1024,
        },
    )
    .map_err(|e| {
        eprintln!("cannot open event store in {}: {e}", cfg.data_dir.display());
        ExitCode::FAILURE
    })?;

    let started_at = Utc::now();
    let boot_id = hex::encode(
        Sha256::digest(
            format!(
                "{}:{}",
                started_at.timestamp_nanos_opt().unwrap_or(0),
                std::process::id()
            )
            .as_bytes(),
        )
        .get(..6)
        .unwrap_or_default(),
    );
    let (shutdown_tx, mut shutdown_rx) = watch::channel(None);
    let listen = cfg.listen;
    let state = Arc::new(AppState {
        cfg: Arc::new(cfg),
        subs: RwLock::new(Arc::new(subs)),
        store: Arc::new(store),
        deliveries: Mutex::new(VecDeque::new()),
        delivery_total: Mutex::new(0),
        clients: Mutex::new(BTreeMap::new()),
        hooks: Mutex::new(None),
        boot_id: boot_id.clone(),
        started_at,
        shutdown: shutdown_tx.clone(),
        subs_write: tokio::sync::Mutex::new(()),
        hook_lock: tokio::sync::Mutex::new(()),
    });

    let listener = tokio::net::TcpListener::bind(listen).await.map_err(|e| {
        eprintln!("cannot listen on {listen}: {e}");
        ExitCode::FAILURE
    })?;
    tracing::info!(%listen, boot_id = %boot_id, "roost-agent {} ready", env!("CARGO_PKG_VERSION"));
    if let Some(u) = state.cfg.webhook_url() {
        tracing::info!("GitHub webhook payload URL: {u}");
    }

    spawn_signals(state.clone(), shutdown_tx.clone());
    if state.cfg.auto_sync_hooks && !state.subs().repos.is_empty() {
        let st = state.clone();
        tokio::spawn(async move {
            st.sync_hooks_now(false).await;
        });
    }

    let app = api::router(state.clone());
    let mut wait_rx = shutdown_rx.clone();
    let served = axum::serve(listener, app)
        .with_graceful_shutdown(async move {
            while wait_rx.borrow_and_update().is_none() {
                if wait_rx.changed().await.is_err() {
                    break;
                }
            }
        })
        .await;
    if let Err(e) = served {
        tracing::error!("server error: {e}");
        return Err(ExitCode::FAILURE);
    }
    let kind = (*shutdown_rx.borrow_and_update()).unwrap_or(Shutdown::Stop);
    // Give in-flight file writes a moment; long-polls already returned on the shutdown signal.
    tokio::time::sleep(Duration::from_millis(100)).await;
    Ok(kind)
}

fn spawn_signals(state: Arc<AppState>, tx: watch::Sender<Option<Shutdown>>) {
    use tokio::signal::unix::{SignalKind, signal};
    tokio::spawn(async move {
        let (Ok(mut term), Ok(mut int), Ok(mut hup)) = (
            signal(SignalKind::terminate()),
            signal(SignalKind::interrupt()),
            signal(SignalKind::hangup()),
        ) else {
            tracing::warn!("cannot install signal handlers");
            return;
        };
        loop {
            tokio::select! {
                _ = term.recv() => { tx.send_replace(Some(Shutdown::Stop)); return; }
                _ = int.recv() => { tx.send_replace(Some(Shutdown::Stop)); return; }
                _ = hup.recv() => {
                    match state.reload().await {
                        Ok(s) => tracing::info!(revision = %s.revision, "SIGHUP: subscriptions reloaded"),
                        Err(list) => for i in list { tracing::error!("SIGHUP reload: {i}") },
                    }
                }
            }
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    fn os(v: &[&str]) -> Vec<OsString> {
        v.iter().map(OsString::from).collect()
    }

    #[test]
    fn args() {
        let a = parse_args(&os(&["x", "check", "--config", "/etc/r.toml"])).unwrap();
        assert_eq!(a.command, "check");
        assert_eq!(a.config, PathBuf::from("/etc/r.toml"));
        let a = parse_args(&os(&["x", "--config=a.toml"])).unwrap();
        assert_eq!(a.command, "serve");
        assert!(parse_args(&os(&["x", "bogus"])).is_err());
        assert_eq!(parse_args(&os(&["x", "--help"])).err().as_deref(), Some(""));
    }
}
