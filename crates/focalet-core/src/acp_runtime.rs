//! ACP launch permissions are process-wide. Keep both modes alive so changing
//! the preference for a new chat cannot interrupt or escalate an existing chat.
use crate::{
    acp_adapter::{AcpAdapter, AcpConfig},
    codex_adapter::{CodexError, EventSender},
    session_permissions::{SessionPermissionStore, permission_error},
};
use serde_json::Value;
use std::{collections::HashMap, sync::Arc};
use tokio::sync::Mutex;

#[derive(Clone)]
pub struct AcpRuntime {
    inner: Arc<Inner>,
}
struct Inner {
    config: AcpConfig,
    events: EventSender,
    permissions: SessionPermissionStore,
    selection: Mutex<()>,
    state: Mutex<State>,
}
struct State {
    active: bool,
    children: HashMap<bool, AcpAdapter>,
}

impl AcpRuntime {
    pub async fn connect(mut config: AcpConfig, events: EventSender) -> Result<Self, CodexError> {
        let permissions = SessionPermissionStore::for_target(&config.target.id);
        let full_access = match config.preferred_session_id.as_deref() {
            Some(id) => permissions.full_access(id).map_err(permission_error)?,
            None => config.command.full_access,
        };
        config.command.full_access = full_access;
        let adapter = AcpAdapter::connect(config.clone(), events.clone()).await?;
        if !config.list_only
            && full_access
            && let Err(error) =
                permissions.remember_full_access(&adapter.active_session_id().await?)
        {
            adapter.shutdown().await;
            return Err(permission_error(error));
        }
        Ok(Self {
            inner: Arc::new(Inner {
                config,
                events,
                permissions,
                selection: Mutex::new(()),
                state: Mutex::new(State {
                    active: full_access,
                    children: HashMap::from([(full_access, adapter)]),
                }),
            }),
        })
    }

    pub fn target_id(&self) -> &str {
        &self.inner.config.target.id
    }

    async fn child(&self, full_access: bool) -> Result<AcpAdapter, CodexError> {
        let existing = self
            .inner
            .state
            .lock()
            .await
            .children
            .get(&full_access)
            .cloned();
        if let Some(adapter) = existing {
            if adapter.is_running().await {
                return Ok(adapter);
            }
            adapter.shutdown().await;
        }
        let mut config = self.inner.config.clone();
        config.command.full_access = full_access;
        config.preferred_session_id = None;
        config.list_only = true;
        let adapter = AcpAdapter::connect(config, self.inner.events.clone()).await?;
        self.inner
            .state
            .lock()
            .await
            .children
            .insert(full_access, adapter.clone());
        Ok(adapter)
    }

    pub async fn current(&self) -> AcpAdapter {
        let state = self.inner.state.lock().await;
        state.children[&state.active].clone()
    }

    pub async fn connection_value(&self) -> Result<Value, CodexError> {
        let child = self.current().await;
        if !child.is_running().await {
            let session = child.active_session_id().await?;
            self.activate(Some(&session), None, false).await?;
        }
        self.current().await.connection_value().await
    }

    pub async fn list_sessions(&self) -> Result<Vec<Value>, CodexError> {
        let children: Vec<_> = self
            .inner
            .state
            .lock()
            .await
            .children
            .values()
            .cloned()
            .collect();
        let mut sessions = std::collections::BTreeMap::new();
        for child in children {
            if child.is_running().await {
                for session in child.list_sessions().await? {
                    if let Some(id) = session.get("id").and_then(Value::as_str) {
                        sessions.insert(id.to_owned(), session);
                    }
                }
            }
        }
        Ok(sessions.into_values().collect())
    }

    pub async fn for_session(&self, id: &str) -> Result<AcpAdapter, CodexError> {
        let full_access = self
            .inner
            .permissions
            .full_access(id)
            .map_err(permission_error)?;
        self.inner
            .state
            .lock()
            .await
            .children
            .get(&full_access)
            .cloned()
            .ok_or_else(|| CodexError {
                code: "runtime-unavailable".into(),
                message: "Reconnect this ACP chat before using it.".into(),
                retryable: true,
            })
    }

    pub async fn is_running(&self) -> bool {
        // Retain the pool while any sibling process still owns live chats.
        let children: Vec<_> = self
            .inner
            .state
            .lock()
            .await
            .children
            .values()
            .cloned()
            .collect();
        for child in children {
            if child.is_running().await {
                return true;
            }
        }
        false
    }

    pub async fn activate(
        &self,
        session: Option<&str>,
        cwd: Option<&str>,
        full_access: bool,
    ) -> Result<(), CodexError> {
        let _selection = self.inner.selection.lock().await;
        let full_access = match session {
            Some(id) => self
                .inner
                .permissions
                .full_access(id)
                .map_err(permission_error)?,
            None => full_access,
        };
        let child = self.child(full_access).await?;
        child.activate(session, cwd).await?;
        if session.is_none() && full_access {
            self.inner
                .permissions
                .remember_full_access(&child.active_session_id().await?)
                .map_err(permission_error)?;
        }
        self.inner.state.lock().await.active = full_access;
        Ok(())
    }

    pub async fn create_session(
        &self,
        model: Option<&str>,
        cwd: Option<&str>,
        full_access: bool,
    ) -> Result<Value, CodexError> {
        let _selection = self.inner.selection.lock().await;
        let child = self.child(full_access).await?;
        let connection = child.create_session(model, cwd).await?;
        if full_access {
            self.inner
                .permissions
                .remember_full_access(&child.active_session_id().await?)
                .map_err(permission_error)?;
        }
        self.inner.state.lock().await.active = full_access;
        Ok(connection)
    }

    pub async fn open_session(&self, id: &str, cwd: Option<&str>) -> Result<Value, CodexError> {
        self.activate(Some(id), cwd, false).await?;
        self.current().await.connection_value().await
    }

    pub async fn refresh_models(&self) -> Result<Option<Vec<Value>>, CodexError> {
        let _selection = self.inner.selection.lock().await;
        let children: Vec<_> = self
            .inner
            .state
            .lock()
            .await
            .children
            .iter()
            .map(|(mode, child)| (*mode, child.clone()))
            .collect();
        for (mode, child) in children {
            let replacement = child.refreshed().await?;
            self.inner
                .state
                .lock()
                .await
                .children
                .insert(mode, replacement);
        }
        Ok(self.current().await.model_inventory().await)
    }

    pub async fn shutdown(&self) {
        let children: Vec<_> = self
            .inner
            .state
            .lock()
            .await
            .children
            .values()
            .cloned()
            .collect();
        for child in children {
            child.shutdown().await;
        }
    }
}
