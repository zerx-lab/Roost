//! Secret values in `agent.toml`: a literal, `env:NAME` or `file:/path`.
//! Resolved once at load; the resolved value never shows in `Debug` output.

use std::fmt;
use std::io::Read;
use std::path::Path;

/// Largest secret file we read (a token or HMAC key, not a document).
const MAX_SECRET_FILE: u64 = 64 * 1024;

#[derive(Clone, Default, PartialEq, Eq)]
pub struct Secret(String);

impl Secret {
    pub fn expose(&self) -> &str {
        &self.0
    }

    /// Resolves a spec; an empty spec or an empty resolved value is `None`.
    /// Relative `file:` paths resolve against `base` (the config file's directory).
    pub fn resolve(spec: &str, base: &Path) -> Result<Option<Secret>, String> {
        let spec = spec.trim();
        let value = if let Some(name) = spec.strip_prefix("env:") {
            match std::env::var(name.trim()) {
                Ok(v) => v,
                Err(std::env::VarError::NotPresent) => {
                    return Err(format!("environment variable {name} is not set"));
                }
                Err(e) => return Err(format!("environment variable {name}: {e}")),
            }
        } else if let Some(path) = spec.strip_prefix("file:") {
            let path = base.join(path.trim());
            let file = std::fs::File::open(&path)
                .map_err(|e| format!("cannot open {}: {e}", path.display()))?;
            let mut buf = String::new();
            file.take(MAX_SECRET_FILE + 1)
                .read_to_string(&mut buf)
                .map_err(|e| format!("cannot read {}: {e}", path.display()))?;
            if buf.len() as u64 > MAX_SECRET_FILE {
                return Err(format!(
                    "{} is larger than {MAX_SECRET_FILE} bytes",
                    path.display()
                ));
            }
            buf
        } else {
            spec.to_string()
        };
        let value = value.trim().to_string();
        Ok(if value.is_empty() {
            None
        } else {
            Some(Secret(value))
        })
    }
}

impl fmt::Debug for Secret {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("Secret(***)")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn literal_env_file_and_empty() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("tok"), "  abc\n").unwrap();
        assert_eq!(
            Secret::resolve("file:tok", dir.path())
                .unwrap()
                .unwrap()
                .expose(),
            "abc"
        );
        assert_eq!(
            Secret::resolve("lit", dir.path())
                .unwrap()
                .unwrap()
                .expose(),
            "lit"
        );
        assert!(Secret::resolve("", dir.path()).unwrap().is_none());
        assert!(Secret::resolve("env:ROOST_SURELY_UNSET_VAR", dir.path()).is_err());
        assert!(Secret::resolve("file:missing", dir.path()).is_err());
        assert_eq!(
            format!("{:?}", Secret::resolve("x", dir.path()).unwrap()),
            "Some(Secret(***))"
        );
    }
}
