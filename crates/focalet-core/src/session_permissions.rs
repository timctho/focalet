use std::{fs, io, path::PathBuf};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::SessionBindingStore;

// Full access belongs to a chat, not the shared process or current preference.
pub(crate) struct SessionPermissionStore {
    directory: PathBuf,
    target_id: String,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Permission {
    runtime_target_id: String,
    session_id: String,
    full_access: bool,
}

impl SessionPermissionStore {
    pub(crate) fn for_target(target_id: &str) -> Self {
        Self::at(
            SessionBindingStore::platform_default().session_permissions_directory(),
            target_id,
        )
    }

    fn at(directory: PathBuf, target_id: &str) -> Self {
        Self {
            directory: directory.join(format!("{:x}", Sha256::digest(target_id.as_bytes()))),
            target_id: target_id.into(),
        }
    }

    fn path(&self, session_id: &str) -> PathBuf {
        self.directory
            .join(format!("{:x}.json", Sha256::digest(session_id.as_bytes())))
    }

    pub(crate) fn full_access(&self, session_id: &str) -> io::Result<bool> {
        let bytes = match fs::read(self.path(session_id)) {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                // Preserve chats created by the first Codex-only implementation.
                let previous = Self::at(
                    SessionBindingStore::platform_default().codex_permissions_directory(),
                    &self.target_id,
                );
                match fs::read(previous.path(session_id)) {
                    Ok(bytes) => bytes,
                    Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(false),
                    Err(error) => return Err(error),
                }
            }
            Err(error) => return Err(error),
        };
        let permission: Permission = serde_json::from_slice(&bytes).map_err(io::Error::other)?;
        if permission.runtime_target_id != self.target_id || permission.session_id != session_id {
            return Err(io::Error::other(
                "Session permissions belong to another chat.",
            ));
        }
        Ok(permission.full_access)
    }

    pub(crate) fn remember_full_access(&self, session_id: &str) -> io::Result<()> {
        let permission = Permission {
            runtime_target_id: self.target_id.clone(),
            session_id: session_id.into(),
            full_access: true,
        };
        fs::create_dir_all(&self.directory)?;
        let path = self.path(session_id);
        let temporary = path.with_extension(format!("tmp-{}", uuid::Uuid::new_v4()));
        fs::write(
            &temporary,
            serde_json::to_vec(&permission).map_err(io::Error::other)?,
        )?;
        // Immutable per-chat records avoid concurrent hosts losing each other's
        // settings. A reader only ever sees a complete record.
        let published = fs::hard_link(&temporary, &path);
        let _ = fs::remove_file(&temporary);
        match published {
            Ok(()) => Ok(()),
            Err(error)
                if error.kind() == io::ErrorKind::AlreadyExists
                    && self.full_access(session_id)? =>
            {
                Ok(())
            }
            Err(error) => Err(error),
        }
    }
}

pub(crate) fn permission_error(error: io::Error) -> crate::codex_adapter::CodexError {
    crate::codex_adapter::CodexError {
        code: "persistence-failed".into(),
        message: crate::sanitize_diagnostic(format!(
            "Could not preserve this chat's permissions: {error}"
        )),
        retryable: false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn permissions_are_durable_and_scoped_to_exact_runtime_and_chat() {
        let root =
            std::env::temp_dir().join(format!("focalet-permissions-{}", uuid::Uuid::new_v4()));
        let store = SessionPermissionStore::at(root.clone(), "runtime-one");
        assert!(!store.full_access("chat-one").unwrap());
        store.remember_full_access("chat-one").unwrap();
        let reopened = SessionPermissionStore::at(root.clone(), "runtime-one");
        assert!(reopened.full_access("chat-one").unwrap());
        reopened.remember_full_access("chat-one").unwrap();
        assert!(!reopened.full_access("chat-two").unwrap());
        assert!(
            !SessionPermissionStore::at(root.clone(), "runtime-two")
                .full_access("chat-one")
                .unwrap()
        );
        fs::copy(store.path("chat-one"), store.path("chat-two")).unwrap();
        assert!(store.full_access("chat-two").is_err());
        fs::write(store.path("chat-one"), "invalid").unwrap();
        assert!(store.full_access("chat-one").is_err());
        assert!(store.remember_full_access("chat-one").is_err());
        fs::remove_dir_all(root).unwrap();
    }
}
