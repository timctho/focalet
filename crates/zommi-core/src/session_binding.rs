use std::{env, fs, io, path::PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionBinding {
    pub runtime_target_id: String,
    pub session_id: String,
    pub cwd: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_metadata: Option<Value>,
}

#[derive(Debug, Clone)]
pub struct SessionBindingStore {
    path: PathBuf,
}

impl SessionBindingStore {
    pub fn platform_default() -> Self {
        if let Some(path) = env::var_os("ZOMMI_CORE_STATE_PATH") {
            return Self::new(path.into());
        }
        let home = env::var_os("HOME")
            .or_else(|| env::var_os("USERPROFILE"))
            .map(PathBuf::from)
            .unwrap_or_else(env::temp_dir);
        let path = if cfg!(target_os = "windows") {
            env::var_os("APPDATA")
                .map(PathBuf::from)
                .unwrap_or(home)
                .join("Zommi")
                .join("session-binding.json")
        } else if cfg!(target_os = "macos") {
            home.join("Library")
                .join("Application Support")
                .join("Zommi")
                .join("session-binding.json")
        } else {
            env::var_os("XDG_STATE_HOME")
                .map(PathBuf::from)
                .unwrap_or_else(|| home.join(".local").join("state"))
                .join("zommi")
                .join("session-binding.json")
        };
        Self::new(path)
    }

    pub fn new(path: PathBuf) -> Self {
        Self { path }
    }

    pub(crate) fn codex_homes_directory(&self) -> PathBuf {
        self.path.with_file_name("codex-homes")
    }

    pub(crate) fn session_locators_directory(&self) -> PathBuf {
        self.path.with_file_name("session-locators")
    }

    pub fn load(&self) -> Option<SessionBinding> {
        let bytes = fs::read(&self.path).ok()?;
        serde_json::from_slice(&bytes).ok()
    }

    pub fn save(&self, binding: &SessionBinding) -> io::Result<()> {
        let parent = self.path.parent().ok_or_else(|| {
            io::Error::new(io::ErrorKind::InvalidInput, "binding path has no parent")
        })?;
        fs::create_dir_all(parent)?;
        let temporary = self
            .path
            .with_extension(format!("tmp-{}", std::process::id()));
        fs::write(
            &temporary,
            serde_json::to_vec_pretty(binding).map_err(io::Error::other)?,
        )?;
        #[cfg(target_os = "windows")]
        if self.path.exists() {
            fs::remove_file(&self.path)?;
        }
        fs::rename(temporary, &self.path)
    }
}

#[cfg(test)]
mod tests {
    use super::{SessionBinding, SessionBindingStore};

    #[test]
    fn round_trips_exact_target_and_session_identity() {
        let root = std::env::temp_dir().join(format!("zommi-binding-{}", std::process::id()));
        let store = SessionBindingStore::new(root.join("nested").join("binding.json"));
        let binding = SessionBinding {
            runtime_target_id: "runtime-exact".into(),
            session_id: "thread-exact".into(),
            cwd: "/workspace".into(),
            session_metadata: Some(serde_json::json!({"sessionFile": "/sessions/a.jsonl"})),
        };
        store.save(&binding).expect("save binding");
        assert_eq!(store.load(), Some(binding));
        let _ = std::fs::remove_dir_all(root);
    }
}
