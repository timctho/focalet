use std::{
    collections::{HashMap, HashSet},
    path::PathBuf,
    process::Stdio,
    sync::{
        Arc, Weak,
        atomic::{AtomicBool, AtomicU64, Ordering},
    },
};

use serde_json::{Value, json};
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    process::{ChildStdin, Command},
    sync::{Mutex, oneshot},
    task::JoinHandle,
    time::{Duration, timeout},
};
use uuid::Uuid;

use crate::{
    RuntimeCommand, RuntimeTarget,
    artifacts::artifacts_from_content,
    build_context_handoff,
    codex_adapter::{CodexError, CoreEvent, EventSender, TurnReceipt},
    sanitize_diagnostic, validate_turn_input,
};

const REQUEST_TIMEOUT: Duration = Duration::from_secs(30);
const PROMPT_TIMEOUT: Duration = Duration::from_secs(10 * 60);
const APPROVAL_TIMEOUT: Duration = Duration::from_secs(300);

#[derive(Debug, Clone)]
pub struct AcpConfig {
    pub target: RuntimeTarget,
    pub command: RuntimeCommand,
    pub cwd: PathBuf,
    pub preferred_session_id: Option<String>,
    pub list_only: bool,
}

pub struct AcpTurnRequest<'a> {
    pub session_id: &'a str,
    pub message: &'a str,
    pub slash_command: bool,
    pub snapshots: &'a [Value],
    pub images: &'a [String],
    pub client_operation_id: &'a str,
    pub model: Option<&'a str>,
}

#[derive(Clone)]
pub struct AcpAdapter {
    inner: Arc<Inner>,
}

struct Inner {
    target: RuntimeTarget,
    cwd: PathBuf,
    command: RuntimeCommand,
    emit_events: AtomicBool,
    stdin: Mutex<ChildStdin>,
    pending: Mutex<HashMap<String, PendingRequest>>,
    state: Mutex<State>,
    next_request_id: AtomicU64,
    next_event_sequence: AtomicU64,
    event_tx: EventSender,
    wait_task: Mutex<Option<JoinHandle<()>>>,
    stdout_task: Mutex<Option<JoinHandle<()>>>,
    stderr_task: Mutex<Option<JoinHandle<()>>>,
}

struct PendingRequest {
    method: String,
    session_id: Option<String>,
    turn_id: Option<String>,
    completion: oneshot::Sender<Result<Value, CodexError>>,
}

#[derive(Default)]
struct State {
    command_catalogs: HashMap<String, Vec<Value>>,
    protocol_version: u64,
    runtime_version: Option<String>,
    capabilities: Vec<String>,
    agent_capabilities: Value,
    session_id: Option<String>,
    session_cwd: Option<String>,
    active_model: Option<String>,
    model_config_id: Option<String>,
    models: Vec<Value>,
    sessions: Vec<Value>,
    histories: HashMap<String, Vec<Value>>,
    active_turns: HashMap<String, String>,
    turn_operations: HashMap<String, String>,
    terminal_turns: HashSet<String>,
    approvals: HashMap<String, PendingApproval>,
    stderr: String,
    stopping: bool,
    exited: bool,
}

struct PendingApproval {
    session_id: String,
    rpc_id: Value,
    options: Vec<Value>,
}

impl AcpAdapter {
    pub async fn connect(config: AcpConfig, event_tx: EventSender) -> Result<Self, CodexError> {
        Self::connect_with_events(config, event_tx, true).await
    }

    async fn connect_with_events(
        config: AcpConfig,
        event_tx: EventSender,
        emit_events: bool,
    ) -> Result<Self, CodexError> {
        let mut launch = config.command.clone();
        if launch.full_access {
            launch
                .enable_full_access(&config.target)
                .map_err(|error| adapter_error("invalid-configuration", error.to_string()))?;
        }
        let mut command = Command::new(&launch.command);
        config.target.apply_launch_environment(&mut command);
        if config.target.execution_host.kind != "wsl" {
            command.envs(
                config
                    .command
                    .permission_environment(&config.target.adapter_id)
                    .iter()
                    .copied(),
            );
        }
        command
            .args(&launch.args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true);
        if config.target.execution_host.kind != "wsl" && config.cwd.is_dir() {
            command.current_dir(&config.cwd);
        }
        let mut child = command.spawn().map_err(|error| {
            adapter_error(
                "runtime-unavailable",
                format!(
                    "Could not start {} ACP: {error}",
                    config.target.display_name
                ),
            )
        })?;
        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| adapter_error("runtime-unavailable", "ACP runtime has no stdin."))?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| adapter_error("runtime-unavailable", "ACP runtime has no stdout."))?;
        let stderr = child
            .stderr
            .take()
            .ok_or_else(|| adapter_error("runtime-unavailable", "ACP runtime has no stderr."))?;
        let adapter = Self {
            inner: Arc::new(Inner {
                target: config.target,
                cwd: config.cwd,
                command: config.command,
                emit_events: AtomicBool::new(emit_events),
                stdin: Mutex::new(stdin),
                pending: Mutex::new(HashMap::new()),
                state: Mutex::new(State::default()),
                next_request_id: AtomicU64::new(0),
                next_event_sequence: AtomicU64::new(0),
                event_tx,
                wait_task: Mutex::new(None),
                stdout_task: Mutex::new(None),
                stderr_task: Mutex::new(None),
            }),
        };
        adapter.inner.emit_status(
            &format!("Connecting to {}…", adapter.inner.target.display_name),
            "connecting",
            None,
            None,
        );
        let weak = Arc::downgrade(&adapter.inner);
        *adapter.inner.stdout_task.lock().await =
            Some(tokio::spawn(async move { read_stdout(weak, stdout).await }));
        let weak = Arc::downgrade(&adapter.inner);
        *adapter.inner.stderr_task.lock().await =
            Some(tokio::spawn(async move { read_stderr(weak, stderr).await }));
        let weak = Arc::downgrade(&adapter.inner);
        *adapter.inner.wait_task.lock().await = Some(tokio::spawn(async move {
            let status = child.wait().await;
            if let Some(inner) = weak.upgrade() {
                if let Some(task) = inner.stdout_task.lock().await.take() {
                    let _ = task.await;
                }
                if let Some(task) = inner.stderr_task.lock().await.take() {
                    let _ = task.await;
                }
                inner.handle_exit(status).await;
            }
        }));

        if let Err(error) = adapter
            .initialize(config.preferred_session_id, config.list_only)
            .await
        {
            adapter.shutdown().await;
            return Err(error);
        }
        Ok(adapter)
    }

    async fn initialize(
        &self,
        preferred_session_id: Option<String>,
        list_only: bool,
    ) -> Result<(), CodexError> {
        let initialized = self
            .inner
            .request(
                "initialize",
                json!({
                    "protocolVersion": 1,
                    "clientCapabilities": {},
                    "clientInfo": {"name": "zommi", "version": env!("CARGO_PKG_VERSION")}
                }),
                REQUEST_TIMEOUT,
            )
            .await?;
        let protocol_version = initialized
            .get("protocolVersion")
            .and_then(Value::as_u64)
            .unwrap_or_default();
        if protocol_version != 1 {
            return Err(adapter_error(
                "unsupported-version",
                format!("Unsupported ACP protocol version {protocol_version}."),
            ));
        }
        {
            let mut state = self.inner.state.lock().await;
            state.protocol_version = protocol_version;
            state.runtime_version = initialized
                .pointer("/agentInfo/version")
                .and_then(Value::as_str)
                .map(str::to_owned);
            state.agent_capabilities = initialized
                .get("agentCapabilities")
                .cloned()
                .unwrap_or_else(|| json!({}));
            state.capabilities = negotiated_capabilities(&initialized);
            if unsafe_gemini_resume(&self.inner.target, &state) {
                state.capabilities.retain(|c| c != "session.resume.v1");
            }
        }
        let auth_methods = initialized
            .get("authMethods")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        // Gemini's session/new and session/load reuse its configured account.
        // Calling authenticate with the first advertised method would switch
        // API-key/Vertex users to Google OAuth and can clear their credentials.
        let reuse_runtime_auth = self.inner.target.adapter_id == "gemini-acp";
        if !reuse_runtime_auth
            && let Some(auth) = auth_methods.iter().find(|method| {
                method.get("type").and_then(Value::as_str) != Some("terminal")
                    && method.get("id").and_then(Value::as_str).is_some()
            })
        {
            self.inner
                .request(
                    "authenticate",
                    json!({"methodId": auth.get("id").and_then(Value::as_str)}),
                    REQUEST_TIMEOUT,
                )
                .await?;
        } else if !reuse_runtime_auth
            && auth_methods
                .iter()
                .any(|method| method.get("type").and_then(Value::as_str) == Some("terminal"))
        {
            return Err(adapter_error(
                "authentication-required",
                format!(
                    "{} sign-in required; complete sign-in in the runtime, then refresh Zommi.",
                    self.inner.target.display_name
                ),
            ));
        }
        if list_only {
            return Ok(());
        }
        if preferred_session_id.is_some()
            && unsafe_gemini_resume(&self.inner.target, &*self.inner.state.lock().await)
        {
            return Err(gemini_resume_error());
        }
        self.load_sessions().await?;
        let can_load = self
            .inner
            .state
            .lock()
            .await
            .agent_capabilities
            .get("loadSession")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        let mut resumed = false;
        if can_load && let Some(session_id) = preferred_session_id {
            self.inner
                .state
                .lock()
                .await
                .histories
                .insert(session_id.clone(), Vec::new());
            match self
                .inner
                .request(
                    "session/load",
                    json!({
                        "cwd": self.inner.cwd.to_string_lossy(),
                        "sessionId": session_id,
                        "mcpServers": []
                    }),
                    REQUEST_TIMEOUT,
                )
                .await
            {
                Ok(result) => {
                    self.select_session(&session_id, &result).await?;
                    resumed = true;
                }
                Err(error) => self.inner.emit_status(
                    &format!("Bound ACP session could not be resumed: {}", error.message),
                    "connecting",
                    None,
                    None,
                ),
            }
        }
        if !resumed {
            self.new_session(None).await?;
        }
        let session_id = self.active_session_id().await?;
        self.inner.emit_status(
            &format!(
                "{} ready · {}",
                self.inner.target.display_name,
                short_id(&session_id)
            ),
            "ready",
            Some(&session_id),
            None,
        );
        Ok(())
    }

    /// ACP has no model-list RPC. Start a fresh process to pick up provider
    /// credentials, then load the exact existing session without replaying its
    /// history into the UI. Keep the original adapter usable if this fails.
    pub async fn refreshed(&self) -> Result<Self, CodexError> {
        let (session_id, cwd, model) = {
            let state = self.inner.state.lock().await;
            if !state.active_turns.is_empty() {
                return Err(adapter_error(
                    "session-busy",
                    "Finish the active turn before refreshing models.",
                ));
            }
            if state.session_id.is_some()
                && state
                    .agent_capabilities
                    .get("loadSession")
                    .and_then(Value::as_bool)
                    != Some(true)
            {
                return Err(adapter_error(
                    "capability-unavailable",
                    "This ACP runtime cannot reload the current session to refresh models.",
                ));
            }
            (
                state.session_id.clone(),
                state.session_cwd.clone(),
                state.active_model.clone(),
            )
        };
        let replacement = Self::connect_with_events(
            AcpConfig {
                target: self.inner.target.clone(),
                command: self.inner.command.clone(),
                cwd: cwd
                    .as_ref()
                    .map(PathBuf::from)
                    .unwrap_or_else(|| self.inner.cwd.clone()),
                preferred_session_id: None,
                list_only: true,
            },
            self.inner.event_tx.clone(),
            false,
        )
        .await?;
        // Gemini's model inventory is session-scoped. Probe an empty session in
        // isolation, retaining the live transport and its exact conversation. In
        // 0.60/0.61 session/load resets saved messages before it reads them.
        if unsafe_gemini_resume(&self.inner.target, &*self.inner.state.lock().await) {
            let result = replacement.new_session(None).await;
            if let Err(error) = result {
                replacement.shutdown().await;
                return Err(error);
            }
            {
                let probe = replacement.inner.state.lock().await;
                let mut current = self.inner.state.lock().await;
                current.models = probe.models.clone();
                current.model_config_id = probe.model_config_id.clone();
            }
            replacement.shutdown().await;
            return Ok(self.clone());
        }
        let restored = async {
            if let Some(session_id) = session_id {
                replacement
                    .open_session_with_cwd(&session_id, cwd.as_deref())
                    .await?;
                let (available, current) = {
                    let state = replacement.inner.state.lock().await;
                    (state.models.clone(), state.active_model.clone())
                };
                if let Some(model) = model
                    && current.as_deref() != Some(&model)
                    && available
                        .iter()
                        .any(|item| item["id"].as_str() == Some(&model))
                {
                    replacement.set_model(&model).await?;
                }
            }
            Ok::<(), CodexError>(())
        }
        .await;
        if let Err(error) = restored {
            replacement.shutdown().await;
            return Err(error);
        }
        {
            let previous = self.inner.state.lock().await;
            let mut next = replacement.inner.state.lock().await;
            // This is an inventory refresh, not a history refresh. ACP replay
            // synthesizes turn IDs, so retain the original transcript identities.
            next.histories = previous.histories.clone();
            for (id, commands) in &previous.command_catalogs {
                next.command_catalogs
                    .entry(id.clone())
                    .or_insert_with(|| commands.clone());
            }
            next.sessions = previous.sessions.clone();
        }
        self.shutdown().await;
        replacement.inner.emit_events.store(true, Ordering::Release);
        Ok(replacement)
    }

    pub async fn model_inventory(&self) -> Option<Vec<Value>> {
        let state = self.inner.state.lock().await;
        state.session_id.as_ref().map(|_| state.models.clone())
    }

    pub async fn is_running(&self) -> bool {
        let state = self.inner.state.lock().await;
        !state.exited && !state.stopping
    }

    pub fn target_id(&self) -> &str {
        &self.inner.target.id
    }

    pub async fn active_session_id(&self) -> Result<String, CodexError> {
        self.inner
            .state
            .lock()
            .await
            .session_id
            .clone()
            .ok_or_else(|| adapter_error("runtime-failed", "ACP has no active session."))
    }

    pub async fn list_commands(
        &self,
        session_id: &str,
        _force: bool,
    ) -> Result<Vec<Value>, CodexError> {
        Ok(self
            .inner
            .state
            .lock()
            .await
            .command_catalogs
            .get(session_id)
            .cloned()
            .unwrap_or_default())
    }

    pub async fn connection_value(&self) -> Result<Value, CodexError> {
        let state = self.inner.state.lock().await;
        let session_id = state
            .session_id
            .clone()
            .ok_or_else(|| adapter_error("runtime-failed", "ACP has no active session."))?;
        Ok(json!({
            "runtimeTargetId": self.inner.target.id,
            "sessionId": session_id,
            "protocolVersion": state.protocol_version,
            "runtimeVersion": state.runtime_version,
            "capabilities": state.capabilities,
            "models": state.models,
            "sessionMetadata": {"activeModel": state.active_model},
            "sessions": state.sessions,
            "history": {"thread": {"id": session_id, "turns": state.histories.get(&session_id).cloned().unwrap_or_default()}}
        }))
    }

    pub async fn list_sessions(&self) -> Result<Vec<Value>, CodexError> {
        self.load_sessions().await
    }

    pub async fn create_session(
        &self,
        model: Option<&str>,
        cwd: Option<&str>,
    ) -> Result<Value, CodexError> {
        self.new_session_with_cwd(model, cwd).await?;
        self.load_sessions().await?;
        self.connection_value().await
    }

    pub async fn open_session(&self, session_id: &str) -> Result<Value, CodexError> {
        self.open_session_with_cwd(session_id, None).await
    }

    pub async fn open_session_with_cwd(
        &self,
        session_id: &str,
        cwd: Option<&str>,
    ) -> Result<Value, CodexError> {
        {
            let state = self.inner.state.lock().await;
            if unsafe_gemini_resume(&self.inner.target, &state) {
                if state.session_id.as_deref() == Some(session_id) {
                    drop(state);
                    return self.connection_value().await;
                }
                return Err(gemini_resume_error());
            }
        }
        self.inner
            .state
            .lock()
            .await
            .histories
            .insert(session_id.into(), Vec::new());
        let result = self
            .inner
            .request(
                "session/load",
                json!({
                    "cwd": cwd.map(str::to_owned).unwrap_or_else(|| self.inner.cwd.to_string_lossy().into_owned()),
                    "sessionId": session_id,
                    "mcpServers": []
                }),
                REQUEST_TIMEOUT,
            )
            .await?;
        self.select_session(session_id, &result).await?;
        self.inner.state.lock().await.session_cwd = cwd.map(str::to_owned);
        self.connection_value().await
    }

    pub async fn read_session(&self, session_id: &str) -> Result<Value, CodexError> {
        let state = self.inner.state.lock().await;
        Ok(json!({
            "thread": {
                "id": session_id,
                "turns": state.histories.get(session_id).cloned().unwrap_or_default()
            }
        }))
    }

    pub async fn start_turn(&self, request: AcpTurnRequest<'_>) -> Result<TurnReceipt, CodexError> {
        let input = validate_turn_input(request.message, request.snapshots, request.images)?;
        if self.active_session_id().await? != request.session_id {
            return Err(adapter_error(
                "identity-mismatch",
                "The requested session is not the exact active ACP session.",
            ));
        }
        if let Some(model) = request.model {
            self.set_model(model).await?;
        }
        let turn_id = Uuid::new_v4().to_string();
        let mut prompt = vec![json!({
            "type": "text",
            "text": if request.slash_command { input.message.clone() } else { build_context_handoff(&input.message, &input.snapshots, input.images.len()) }
        })];
        for image in &input.images {
            prompt.push(acp_image(image)?);
        }
        {
            let mut state = self.inner.state.lock().await;
            if state.active_turns.contains_key(request.session_id) {
                return Err(adapter_error(
                    "session-busy",
                    "This ACP session already has an active turn.",
                ));
            }
            state
                .active_turns
                .insert(request.session_id.into(), turn_id.clone());
            state.turn_operations.insert(
                request.session_id.into(),
                request.client_operation_id.into(),
            );
            append_history(
                &mut state.histories,
                request.session_id,
                json!({
                    "id": format!("{turn_id}-user"),
                    "type": "userMessage",
                    "content": [{"type": "text", "text": prompt[0]["text"]}]
                }),
                true,
                Some(&turn_id),
            );
        }
        self.inner.emit(
            "turn.started",
            Some(request.session_id),
            Some(&turn_id),
            Some(request.client_operation_id),
            json!({"status": "inProgress"}),
        );
        let receiver = match self
            .inner
            .begin_turn_request(
                "session/prompt",
                json!({
                    "sessionId": request.session_id,
                    "prompt": prompt,
                    "messageId": turn_id
                }),
                request.session_id,
                &turn_id,
            )
            .await
        {
            Ok(receiver) => receiver,
            Err(error) => {
                let mut state = self.inner.state.lock().await;
                state.active_turns.remove(request.session_id);
                state.turn_operations.remove(request.session_id);
                state
                    .terminal_turns
                    .insert(format!("{}:{turn_id}", request.session_id));
                drop(state);
                self.inner.emit(
                    "turn.completed",
                    Some(request.session_id),
                    Some(&turn_id),
                    Some(request.client_operation_id),
                    json!({"status": "failed", "error": error.message}),
                );
                return Err(error);
            }
        };
        let inner = Arc::clone(&self.inner);
        let session_id = request.session_id.to_owned();
        let completion_turn_id = turn_id.clone();
        let operation_id = request.client_operation_id.to_owned();
        tokio::spawn(async move {
            let result = timeout(PROMPT_TIMEOUT, receiver).await;
            let (status, payload) = match result {
                Ok(Ok(Ok(value))) => {
                    let stop_reason = value
                        .get("stopReason")
                        .and_then(Value::as_str)
                        .unwrap_or("end_turn");
                    let status = match stop_reason {
                        "cancelled" => "interrupted",
                        "end_turn" | "max_tokens" | "max_turn_requests" => "completed",
                        _ => "failed",
                    };
                    (status, json!({"status": status, "stopReason": stop_reason}))
                }
                Ok(Ok(Err(error))) => {
                    let status = if error.code == "runtime-exited" {
                        "unknown"
                    } else {
                        "failed"
                    };
                    (status, json!({"status": status, "error": error.message}))
                }
                Ok(Err(_)) => (
                    "unknown",
                    json!({"status": "unknown", "error": "ACP response channel closed."}),
                ),
                Err(_) => (
                    "unknown",
                    json!({"status": "unknown", "error": "ACP prompt outcome timed out."}),
                ),
            };
            let mut state = inner.state.lock().await;
            let still_active = state.active_turns.get(&session_id).map(String::as_str)
                == Some(completion_turn_id.as_str());
            if still_active {
                state.active_turns.remove(&session_id);
                state.turn_operations.remove(&session_id);
            }
            drop(state);
            if still_active {
                inner
                    .cancel_approvals(Some(&session_id), "turn-ended")
                    .await;
                inner.emit(
                    "turn.completed",
                    Some(&session_id),
                    Some(&completion_turn_id),
                    Some(&operation_id),
                    payload,
                );
                if status == "failed" {
                    inner.emit_status(
                        "ACP prompt failed.",
                        "degraded",
                        Some(&session_id),
                        Some(&completion_turn_id),
                    );
                }
            }
        });
        Ok(TurnReceipt {
            accepted: true,
            runtime_target_id: self.inner.target.id.clone(),
            session_id: request.session_id.into(),
            turn_id,
            client_operation_id: request.client_operation_id.into(),
        })
    }

    pub async fn interrupt_turn(
        &self,
        session_id: &str,
        turn_id: &str,
    ) -> Result<Value, CodexError> {
        let state = self.inner.state.lock().await;
        if state.active_turns.get(session_id).map(String::as_str) != Some(turn_id) {
            return Err(adapter_error(
                "identity-mismatch",
                "The requested turn is not the exact active ACP turn.",
            ));
        }
        let operation = state.turn_operations.get(session_id).cloned();
        drop(state);
        self.inner
            .notify("session/cancel", json!({"sessionId": session_id}))
            .await?;
        Ok(json!({
            "interrupted": true,
            "runtimeTargetId": self.inner.target.id,
            "sessionId": session_id,
            "turnId": turn_id,
            "clientOperationId": operation
        }))
    }

    pub async fn resolve_approval(
        &self,
        session_id: &str,
        approval_id: &str,
        option_id: Option<&str>,
    ) -> Result<Value, CodexError> {
        let mut state = self.inner.state.lock().await;
        let pending = state.approvals.get(approval_id).ok_or_else(|| {
            adapter_error(
                "approval-expired",
                "This permission request has expired or was already answered.",
            )
        })?;
        if pending.session_id != session_id {
            return Err(adapter_error(
                "identity-mismatch",
                "The approval does not belong to the requested ACP session.",
            ));
        }
        if option_id.is_some_and(|id| {
            !pending
                .options
                .iter()
                .any(|option| option.get("optionId").and_then(Value::as_str) == Some(id))
        }) {
            return Err(adapter_error(
                "invalid-request",
                "Unknown ACP approval option.",
            ));
        }
        let pending = state.approvals.remove(approval_id).unwrap();
        drop(state);
        let selected = option_id;
        let outcome = selected.map_or_else(
            || json!({"outcome": "cancelled"}),
            |option_id| json!({"outcome": "selected", "optionId": option_id}),
        );
        self.inner
            .write_json(&json!({
                "jsonrpc": "2.0", "id": pending.rpc_id,
                "result": {"outcome": outcome}
            }))
            .await?;
        self.inner.emit(
            "approval.resolved",
            Some(session_id),
            None,
            None,
            json!({"approvalId":approval_id,"reason":"answered"}),
        );
        Ok(json!({
            "resolved": true,
            "approvalId": approval_id,
            "optionId": selected
        }))
    }

    pub async fn shutdown(&self) {
        self.inner.cancel_approvals(None, "disconnected").await;
        self.inner.state.lock().await.stopping = true;
        for task in [
            self.inner.wait_task.lock().await.take(),
            self.inner.stdout_task.lock().await.take(),
            self.inner.stderr_task.lock().await.take(),
        ]
        .into_iter()
        .flatten()
        {
            task.abort();
        }
        let pending = std::mem::take(&mut *self.inner.pending.lock().await);
        for (_, pending) in pending {
            let _ = pending.completion.send(Err(adapter_error(
                "runtime-stopped",
                "ACP process stopped.",
            )));
        }
    }

    async fn new_session(&self, model: Option<&str>) -> Result<(), CodexError> {
        self.new_session_with_cwd(model, None).await
    }

    async fn new_session_with_cwd(
        &self,
        model: Option<&str>,
        cwd: Option<&str>,
    ) -> Result<(), CodexError> {
        let result = self
            .inner
            .request(
                "session/new",
                json!({"cwd": cwd.map(str::to_owned).unwrap_or_else(|| self.inner.cwd.to_string_lossy().into_owned()), "mcpServers": []}),
                REQUEST_TIMEOUT,
            )
            .await?;
        let session_id = result
            .get("sessionId")
            .and_then(Value::as_str)
            .ok_or_else(|| {
                adapter_error("invalid-response", "ACP returned a session without an id.")
            })?;
        self.select_session(session_id, &result).await?;
        self.inner.state.lock().await.session_cwd = cwd.map(str::to_owned);
        if let Some(model) = model {
            self.set_model(model).await?;
        }
        Ok(())
    }

    pub async fn activate(
        &self,
        session_id: Option<&str>,
        cwd: Option<&str>,
    ) -> Result<(), CodexError> {
        if let Some(session_id) = session_id {
            self.open_session_with_cwd(session_id, cwd).await?;
        } else {
            self.new_session_with_cwd(None, cwd).await?;
        }
        Ok(())
    }

    async fn set_model(&self, model: &str) -> Result<(), CodexError> {
        let session_id = self.active_session_id().await?;
        let config_id = {
            let state = self.inner.state.lock().await;
            if state.active_model.as_deref() == Some(model) {
                return Ok(());
            }
            if !state
                .models
                .iter()
                .any(|candidate| candidate["id"] == model)
            {
                return Err(adapter_error(
                    "invalid-request",
                    "This agent no longer advertises that model. Refresh agents and select an available model.",
                ));
            }
            state.model_config_id.clone()
        };
        let result = if let Some(config_id) = config_id {
            self.inner
                .request(
                    "session/set_config_option",
                    json!({"sessionId": session_id, "configId": config_id, "value": model}),
                    REQUEST_TIMEOUT,
                )
                .await?
        } else {
            self.inner
                .request(
                    "session/set_model",
                    json!({"sessionId": session_id, "modelId": model}),
                    REQUEST_TIMEOUT,
                )
                .await?
        };
        let mut state = self.inner.state.lock().await;
        // Legacy ACP set_model commonly acknowledges with an empty result.
        state.active_model = Some(model.into());
        apply_model_configuration(&mut state, &result);
        Ok(())
    }

    async fn select_session(&self, session_id: &str, result: &Value) -> Result<(), CodexError> {
        if session_id.is_empty() {
            return Err(adapter_error(
                "invalid-response",
                "ACP returned a session without an id.",
            ));
        }
        {
            let mut state = self.inner.state.lock().await;
            state.session_id = Some(session_id.into());
            state.histories.entry(session_id.into()).or_default();
        }
        let mut state = self.inner.state.lock().await;
        state.model_config_id = None;
        state.active_model = None;
        state.models.clear();
        state
            .capabilities
            .retain(|value| value != "model.select.v1");
        apply_model_configuration(&mut state, result);
        Ok(())
    }

    async fn load_sessions(&self) -> Result<Vec<Value>, CodexError> {
        let supports_list = self
            .inner
            .state
            .lock()
            .await
            .agent_capabilities
            .pointer("/sessionCapabilities/list")
            .is_some();
        if !supports_list {
            let mut state = self.inner.state.lock().await;
            state.sessions = state
                .session_id
                .as_ref()
                .map(|session_id| {
                    vec![json!({
                        "id": session_id,
                        "preview": format!("{} session", self.inner.target.display_name)
                    })]
                })
                .unwrap_or_default();
            return Ok(state.sessions.clone());
        }
        let mut sessions = Vec::new();
        let mut cursor: Option<String> = None;
        for _ in 0..5 {
            let mut params = json!({"cwd": self.inner.cwd.to_string_lossy()});
            if let Some(value) = &cursor {
                params["cursor"] = Value::String(value.clone());
            }
            let result = self
                .inner
                .request("session/list", params, REQUEST_TIMEOUT)
                .await?;
            sessions.extend(
                result
                    .get("sessions")
                    .and_then(Value::as_array)
                    .into_iter()
                    .flatten()
                    .filter_map(|session| {
                        let id = session.get("sessionId")?.as_str()?;
                        let title = session.get("title").and_then(Value::as_str);
                        Some(json!({
                            "id": id,
                            "name": title,
                            "preview": title.unwrap_or("ACP session"),
                            "updatedAt": session.get("updatedAt"),
                            "cwd": session.get("cwd")
                        }))
                    }),
            );
            cursor = result
                .get("nextCursor")
                .and_then(Value::as_str)
                .map(str::to_owned);
            if cursor.is_none() {
                break;
            }
        }
        let current = self.inner.state.lock().await.session_id.clone();
        if let Some(current) = current
            && !sessions
                .iter()
                .any(|session| session.get("id").and_then(Value::as_str) == Some(&current))
        {
            sessions.insert(
                0,
                json!({"id": current, "preview": "Current ACP session", "cwd": self.inner.cwd}),
            );
        }
        self.inner.state.lock().await.sessions = sessions.clone();
        Ok(sessions)
    }
}

impl Inner {
    async fn begin_request(
        &self,
        method: &str,
        params: Value,
    ) -> Result<oneshot::Receiver<Result<Value, CodexError>>, CodexError> {
        self.begin_request_with_identity(method, params, None, None)
            .await
    }

    async fn begin_turn_request(
        &self,
        method: &str,
        params: Value,
        session_id: &str,
        turn_id: &str,
    ) -> Result<oneshot::Receiver<Result<Value, CodexError>>, CodexError> {
        self.begin_request_with_identity(
            method,
            params,
            Some(session_id.into()),
            Some(turn_id.into()),
        )
        .await
    }

    async fn begin_request_with_identity(
        &self,
        method: &str,
        params: Value,
        session_id: Option<String>,
        turn_id: Option<String>,
    ) -> Result<oneshot::Receiver<Result<Value, CodexError>>, CodexError> {
        if self.state.lock().await.exited {
            return Err(adapter_error(
                "runtime-exited",
                "ACP runtime is not running.",
            ));
        }
        let id = self
            .next_request_id
            .fetch_add(1, Ordering::Relaxed)
            .saturating_add(1)
            .to_string();
        let (completion, receiver) = oneshot::channel();
        self.pending.lock().await.insert(
            id.clone(),
            PendingRequest {
                method: method.into(),
                session_id,
                turn_id,
                completion,
            },
        );
        if let Err(error) = self
            .write_json(&json!({
                "jsonrpc": "2.0", "id": id, "method": method, "params": params
            }))
            .await
        {
            self.pending.lock().await.remove(&id);
            return Err(error);
        }
        Ok(receiver)
    }

    async fn request(
        &self,
        method: &str,
        params: Value,
        request_timeout: Duration,
    ) -> Result<Value, CodexError> {
        let receiver = self.begin_request(method, params).await?;
        match timeout(request_timeout, receiver).await {
            Ok(Ok(result)) => result,
            Ok(Err(_)) => Err(adapter_error(
                "runtime-exited",
                "ACP response channel closed.",
            )),
            Err(_) => Err(CodexError {
                code: "unknown-outcome".into(),
                message: format!("ACP did not respond to '{method}' in time."),
                retryable: true,
            }),
        }
    }

    async fn notify(&self, method: &str, params: Value) -> Result<(), CodexError> {
        self.write_json(&json!({"jsonrpc": "2.0", "method": method, "params": params}))
            .await
    }

    async fn write_json(&self, value: &Value) -> Result<(), CodexError> {
        let mut bytes = serde_json::to_vec(value)
            .map_err(|error| adapter_error("protocol-error", error.to_string()))?;
        bytes.push(b'\n');
        let mut stdin = self.stdin.lock().await;
        stdin
            .write_all(&bytes)
            .await
            .map_err(|error| adapter_error("runtime-exited", error.to_string()))?;
        stdin
            .flush()
            .await
            .map_err(|error| adapter_error("runtime-exited", error.to_string()))
    }

    async fn handle_message(self: &Arc<Self>, message: Value) {
        if let Some(method) = message.get("method").and_then(Value::as_str) {
            if message.get("id").is_some() {
                self.handle_incoming_request(method, &message).await;
            } else if method == "session/update" {
                self.handle_session_update(message.get("params").unwrap_or(&Value::Null))
                    .await;
            } else {
                self.emit(
                    "runtime.diagnostic",
                    None,
                    None,
                    None,
                    json!({"method": method}),
                );
            }
            return;
        }
        let id = value_string(message.get("id"));
        let Some(pending) = self.pending.lock().await.remove(&id) else {
            return;
        };
        if let (Some(session_id), Some(turn_id)) = (&pending.session_id, &pending.turn_id) {
            let mut state = self.state.lock().await;
            state
                .terminal_turns
                .insert(format!("{session_id}:{turn_id}"));
            if state.terminal_turns.len() > 1_024
                && let Some(oldest) = state.terminal_turns.iter().next().cloned()
            {
                state.terminal_turns.remove(&oldest);
            }
        }
        let result = if let Some(error) = message.get("error") {
            let authentication_required = error.get("code").and_then(Value::as_i64) == Some(-32000)
                && (self.target.adapter_id == "gemini-acp"
                    || error.get("message").and_then(Value::as_str)
                        == Some("Authentication required"));
            if authentication_required {
                Err(adapter_error(
                    "authentication-required",
                    format!(
                        "{} sign-in required. Complete sign-in in the runtime on the same host, then retry or Refresh agents. {}",
                        self.target.display_name,
                        error
                            .get("message")
                            .and_then(Value::as_str)
                            .unwrap_or_default(),
                    ),
                ))
            } else {
                Err(adapter_error(
                    "runtime-request-failed",
                    format!("ACP request '{}' failed: {error}", pending.method),
                ))
            }
        } else {
            Ok(message.get("result").cloned().unwrap_or_else(|| json!({})))
        };
        let _ = pending.completion.send(result);
    }

    async fn cancel_approvals(&self, session: Option<&str>, reason: &str) {
        let mut state = self.state.lock().await;
        let ids: Vec<String> = state
            .approvals
            .iter()
            .filter(|(_, value)| session.is_none_or(|id| value.session_id == id))
            .map(|(id, _)| id.clone())
            .collect();
        let pending: Vec<_> = ids
            .into_iter()
            .map(|id| {
                let value = state.approvals.remove(&id).unwrap();
                (id, value)
            })
            .collect();
        drop(state);
        for (id, value) in pending {
            let _ = self.write_json(&json!({"jsonrpc":"2.0", "id":value.rpc_id,"result":{"outcome":{"outcome":"cancelled"}}})).await;
            self.emit(
                "approval.resolved",
                Some(&value.session_id),
                None,
                None,
                json!({"approvalId":id,"reason":reason}),
            );
        }
    }

    async fn handle_incoming_request(self: &Arc<Self>, method: &str, message: &Value) {
        if method != "session/request_permission" {
            self.emit(
                "runtime.diagnostic",
                None,
                None,
                None,
                json!({"method": method}),
            );
            let _ = self
                .write_json(&json!({
                    "jsonrpc": "2.0", "id": message.get("id"),
                    "error": {"code": -32601, "message": format!("Unsupported ACP client request {method}")}
                }))
                .await;
            return;
        }
        let approval_id = Uuid::new_v4().to_string();
        let params = message.get("params").cloned().unwrap_or_else(|| json!({}));
        let options = params
            .get("options")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        if self.command.full_access {
            let selected = ["allow_once", "allow_always"].iter().find_map(|kind| {
                options
                    .iter()
                    .find(|option| option.get("kind").and_then(Value::as_str) == Some(*kind))
                    .and_then(|option| option.get("optionId"))
                    .cloned()
            });
            if let Some(option_id) = selected {
                let _ = self
                    .write_json(&json!({"jsonrpc":"2.0", "id": message.get("id"),
                    "result":{"outcome":{"outcome":"selected", "optionId": option_id}}}))
                    .await;
                return;
            }
        }
        self.state.lock().await.approvals.insert(
            approval_id.clone(),
            PendingApproval {
                session_id: params
                    .get("sessionId")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .into(),
                rpc_id: message.get("id").cloned().unwrap_or(Value::Null),
                options: options.clone(),
            },
        );
        let turn_id = self
            .state
            .lock()
            .await
            .active_turns
            .get(params["sessionId"].as_str().unwrap_or_default())
            .cloned();
        self.emit(
            "approval.requested",
            params.get("sessionId").and_then(Value::as_str),
            turn_id.as_deref(),
            None,
            json!({
                "approvalId": approval_id,
                "toolCall": params.get("toolCall"),
                "options": options
            }),
        );
        let weak = Arc::downgrade(self);
        tokio::spawn(async move {
            tokio::time::sleep(APPROVAL_TIMEOUT).await;
            let Some(inner) = weak.upgrade() else {
                return;
            };
            let pending = inner.state.lock().await.approvals.remove(&approval_id);
            if let Some(pending) = pending {
                let _ = inner
                    .write_json(&json!({
                        "jsonrpc": "2.0", "id": pending.rpc_id,
                        "result": {"outcome": {"outcome": "cancelled"}}
                    }))
                    .await;
                inner.emit(
                    "approval.resolved",
                    Some(&pending.session_id),
                    None,
                    None,
                    json!({"approvalId":approval_id,"reason":"expired"}),
                );
            }
        });
    }

    async fn handle_session_update(&self, params: &Value) {
        let mut state = self.state.lock().await;
        let session_id = params
            .get("sessionId")
            .and_then(Value::as_str)
            .map(str::to_owned)
            .or_else(|| state.session_id.clone())
            .unwrap_or_default();
        if session_id.is_empty() {
            return;
        }
        let update = params.get("update").cloned().unwrap_or_else(|| json!({}));
        let kind = update
            .get("sessionUpdate")
            .and_then(Value::as_str)
            .unwrap_or_default();
        if kind == "config_option_update" {
            if state.session_id.as_deref() == Some(session_id.as_str()) {
                apply_model_configuration(&mut state, &update);
            }
            return;
        }
        if kind == "available_commands_update" {
            let Some(values) = update.get("availableCommands").and_then(Value::as_array) else {
                return;
            };
            let commands = crate::command_catalog::with_client_limits(
                crate::command_catalog::normalize(values),
            );
            state
                .command_catalogs
                .insert(session_id.clone(), commands.clone());
            drop(state);
            self.emit(
                "commands.updated",
                Some(&session_id),
                None,
                None,
                json!({"commands":commands}),
            );
            return;
        }
        let turn_id = state.active_turns.get(&session_id).cloned();
        let operation = state.turn_operations.get(&session_id).cloned();
        if turn_id.as_ref().is_some_and(|turn_id| {
            state
                .terminal_turns
                .contains(&format!("{session_id}:{turn_id}"))
        }) {
            return;
        }
        let payload = match kind {
            "user_message_chunk" => {
                let text = content_text(update.get("content"));
                if !text.is_empty() {
                    append_history(
                        &mut state.histories,
                        &session_id,
                        json!({
                            "id": update.get("messageId").and_then(Value::as_str).unwrap_or("user"),
                            "type": "userMessage", "content": [{"type": "text", "text": text}]
                        }),
                        true,
                        None,
                    );
                }
                None
            }
            "agent_message_chunk" | "agent_thought_chunk" => {
                let text = content_text(update.get("content"));
                let item_id = update
                    .get("messageId")
                    .and_then(Value::as_str)
                    .map(str::to_owned)
                    .unwrap_or_else(|| format!("{session_id}-{kind}"));
                merge_history_item(
                    &mut state.histories,
                    &session_id,
                    &item_id,
                    if kind == "agent_message_chunk" {
                        "agentMessage"
                    } else {
                        "reasoning"
                    },
                    &text,
                );
                let mut payload = json!({
                    "kind": if kind == "agent_message_chunk" { "assistant" } else { "thinking" },
                    "lifecycle": "delta",
                    "title": if kind == "agent_message_chunk" { self.target.display_name.as_str() } else { "Thinking" },
                    "text": text,
                    "itemId": item_id
                });
                let artifacts = artifacts_from_content(update.get("content"), self.cwd.to_str());
                if !artifacts.is_empty() {
                    payload["artifacts"] = Value::Array(artifacts);
                }
                Some(payload)
            }
            "tool_call" | "tool_call_update" => {
                let status = update.get("status").and_then(Value::as_str);
                let lifecycle = if kind == "tool_call" {
                    "started"
                } else if matches!(status, Some("completed" | "failed")) {
                    "completed"
                } else {
                    "delta"
                };
                let mut payload = json!({
                    "kind": if lifecycle == "delta" { "toolOutput" } else { "tool" },
                    "lifecycle": lifecycle,
                    "title": update.get("title").and_then(Value::as_str).unwrap_or("Tool"),
                    "text": tool_text(&update),
                    "itemId": update.get("toolCallId").and_then(Value::as_str).unwrap_or("tool"),
                    "status": status
                });
                let artifacts = artifacts_from_content(update.get("content"), self.cwd.to_str());
                if !artifacts.is_empty() {
                    payload["artifacts"] = Value::Array(artifacts);
                }
                Some(payload)
            }
            "plan" => Some(json!({
                "kind": "plan", "lifecycle": "delta", "title": "Plan",
                "text": update.get("entries").and_then(Value::as_array).into_iter().flatten()
                    .map(|entry| format!("{}: {}", value_string(entry.get("status")), value_string(entry.get("content"))))
                    .collect::<Vec<_>>().join("\n"),
                "itemId": format!("{session_id}-plan")
            })),
            _ => {
                drop(state);
                self.emit(
                    "runtime.diagnostic",
                    Some(&session_id),
                    turn_id.as_deref(),
                    operation.as_deref(),
                    json!({"method": format!("session/update:{kind}")}),
                );
                return;
            }
        };
        if turn_id.is_none() {
            return;
        }
        drop(state);
        if let Some(payload) = payload {
            self.emit(
                "item.update",
                Some(&session_id),
                turn_id.as_deref(),
                operation.as_deref(),
                payload,
            );
        }
    }

    async fn handle_exit(&self, status: std::io::Result<std::process::ExitStatus>) {
        self.cancel_approvals(None, "disconnected").await;
        let mut state = self.state.lock().await;
        state.exited = true;
        if state.stopping {
            return;
        }
        let code = status
            .map(|status| {
                status
                    .code()
                    .map_or_else(|| "signal".into(), |value| value.to_string())
            })
            .unwrap_or_else(|error| error.to_string());
        let failure = acp_exit_error(
            &self.target.adapter_id,
            state.protocol_version == 0,
            &code,
            &state.stderr,
        );
        let message = failure.message.clone();
        let active = std::mem::take(&mut state.active_turns);
        let operations = std::mem::take(&mut state.turn_operations);
        drop(state);
        let pending = std::mem::take(&mut *self.pending.lock().await);
        for (_, pending) in pending {
            let _ = pending.completion.send(Err(failure.clone()));
        }
        for (session_id, turn_id) in active {
            self.emit(
                "turn.completed",
                Some(&session_id),
                Some(&turn_id),
                operations.get(&session_id).map(String::as_str),
                json!({"status": "unknown", "error": message}),
            );
        }
        self.emit_status(&message, "unavailable", None, None);
    }

    fn emit(
        &self,
        name: &str,
        session_id: Option<&str>,
        turn_id: Option<&str>,
        operation_id: Option<&str>,
        payload: Value,
    ) {
        if !self.emit_events.load(Ordering::Acquire) {
            return;
        }
        let _ = self.event_tx.send(CoreEvent {
            name: name.into(),
            sequence: self
                .next_event_sequence
                .fetch_add(1, Ordering::Relaxed)
                .saturating_add(1),
            runtime_target_id: self.target.id.clone(),
            session_id: session_id.map(str::to_owned),
            turn_id: turn_id.map(str::to_owned),
            client_operation_id: operation_id.map(str::to_owned),
            payload,
        });
    }

    fn emit_status(
        &self,
        message: &str,
        status: &str,
        session_id: Option<&str>,
        turn_id: Option<&str>,
    ) {
        self.emit(
            "runtime.status",
            session_id,
            turn_id,
            None,
            json!({"status": status, "message": sanitize_diagnostic(message)}),
        );
    }
}

async fn read_stdout(inner: Weak<Inner>, stdout: tokio::process::ChildStdout) {
    let mut lines = BufReader::new(stdout).lines();
    loop {
        match lines.next_line().await {
            Ok(Some(line)) => {
                let Some(inner) = inner.upgrade() else {
                    return;
                };
                match serde_json::from_str(&line) {
                    Ok(message) => inner.handle_message(message).await,
                    Err(_) => {
                        inner.emit_status("ACP emitted invalid JSON.", "degraded", None, None)
                    }
                }
            }
            Ok(None) | Err(_) => return,
        }
    }
}

async fn read_stderr(inner: Weak<Inner>, stderr: tokio::process::ChildStderr) {
    let mut lines = BufReader::new(stderr).lines();
    while let Ok(Some(line)) = lines.next_line().await {
        let Some(inner) = inner.upgrade() else {
            return;
        };
        let mut state = inner.state.lock().await;
        state.stderr.push_str(&line);
        state.stderr.push('\n');
        if state.stderr.len() > 8_000 {
            let mut start = state.stderr.len() - 8_000;
            while !state.stderr.is_char_boundary(start) {
                start += 1;
            }
            state.stderr.drain(..start);
        }
    }
}

// New ACP agents expose models as a categorized session configuration option;
// older agents still use the experimental models/session.set_model extension.
fn apply_model_configuration(state: &mut State, result: &Value) {
    let model_state = if let Some(options) = result.get("configOptions").and_then(Value::as_array) {
        let model = options.iter().find(|option| {
            option.get("category").and_then(Value::as_str) == Some("model")
                && option.get("type").and_then(Value::as_str) == Some("select")
                && option.get("id").and_then(Value::as_str).is_some()
        });
        state.model_config_id = model
            .and_then(|option| option["id"].as_str())
            .map(str::to_owned);
        let mut models = Vec::new();
        if let Some(model) = model {
            for option in model
                .get("options")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
            {
                // ACP select options may be flat or grouped by provider.
                let values = option
                    .get("options")
                    .and_then(Value::as_array)
                    .map(Vec::as_slice)
                    .unwrap_or_else(|| std::slice::from_ref(option));
                for value in values {
                    if let Some(id) = value.get("value").and_then(Value::as_str) {
                        models.push(json!({"modelId": id, "name": value.get("name"), "description": value.get("description")}));
                    }
                }
            }
        }
        json!({"currentModelId": model.and_then(|option| option.get("currentValue")), "availableModels": models})
    } else if let Some(models) = result.get("models") {
        models.clone()
    } else if result.get("currentModelId").is_some() || result.get("availableModels").is_some() {
        result.clone()
    } else {
        return;
    };
    state.active_model = model_state
        .get("currentModelId")
        .and_then(Value::as_str)
        .map(str::to_owned);
    if let Some(models) = model_state.get("availableModels").and_then(Value::as_array) {
        state.models = models
            .iter()
            .filter_map(|model| {
                let id = model.get("modelId")?.as_str()?;
                Some(json!({
                    "id": id, "model": id,
                    "displayName": model.get("name").and_then(Value::as_str).unwrap_or(id),
                    "description": model.get("description").and_then(Value::as_str).unwrap_or(""),
                    "supportedReasoningEfforts": []
                }))
            })
            .collect();
    }
    state
        .capabilities
        .retain(|value| value != "model.select.v1");
    if !state.models.is_empty() {
        state.capabilities.push("model.select.v1".into());
    }
}

fn negotiated_capabilities(initialized: &Value) -> Vec<String> {
    let agent = initialized
        .get("agentCapabilities")
        .cloned()
        .unwrap_or_else(|| json!({}));
    let mut capabilities = vec![
        "session.create.v1".into(),
        "turn.stream.v1".into(),
        "turn.interrupt.v1".into(),
        "approval.resolve.v1".into(),
    ];
    if agent.get("loadSession").and_then(Value::as_bool) == Some(true) {
        capabilities.extend(["session.resume.v1".into(), "history.read.v1".into()]);
    }
    if agent.pointer("/sessionCapabilities/list").is_some() {
        capabilities.push("session.list.v1".into());
    }
    if agent
        .pointer("/promptCapabilities/image")
        .and_then(Value::as_bool)
        == Some(true)
    {
        capabilities.push("input.image.v1".into());
    }
    capabilities
}

fn acp_image(value: &str) -> Result<Value, CodexError> {
    let (header, data) = value.split_once(',').ok_or_else(|| {
        adapter_error(
            "invalid-request",
            "ACP image context must be a base64 image data URL.",
        )
    })?;
    let mime_type = header
        .strip_prefix("data:")
        .and_then(|value| value.strip_suffix(";base64"))
        .filter(|value| value.starts_with("image/"))
        .ok_or_else(|| {
            adapter_error(
                "invalid-request",
                "ACP image context must be a base64 image data URL.",
            )
        })?;
    Ok(json!({"type": "image", "mimeType": mime_type, "data": data}))
}

fn content_text(content: Option<&Value>) -> String {
    match content {
        Some(Value::String(value)) => value.clone(),
        Some(value) if value.get("type").and_then(Value::as_str) == Some("text") => {
            value_string(value.get("text"))
        }
        _ => String::new(),
    }
}

fn tool_text(update: &Value) -> String {
    let mut values = Vec::new();
    for name in ["rawInput", "rawOutput"] {
        if let Some(value) = update.get(name).filter(|value| !value.is_null()) {
            values.push(if let Some(text) = value.as_str() {
                text.into()
            } else {
                value.to_string()
            });
        }
    }
    for content in update
        .get("content")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        let text = content_text(content.get("content").or(Some(content)));
        if !text.is_empty() {
            values.push(text);
        }
    }
    values.join("\n")
}

fn append_history(
    histories: &mut HashMap<String, Vec<Value>>,
    session_id: &str,
    item: Value,
    start_turn: bool,
    turn_id: Option<&str>,
) {
    let turns = histories.entry(session_id.into()).or_default();
    if start_turn || turns.is_empty() {
        turns.push(json!({
            "id": turn_id.map(str::to_owned).unwrap_or_else(|| Uuid::new_v4().to_string()),
            "items": [item]
        }));
    } else if let Some(items) = turns
        .last_mut()
        .and_then(|turn| turn.get_mut("items"))
        .and_then(Value::as_array_mut)
    {
        items.push(item);
    }
}

fn merge_history_item(
    histories: &mut HashMap<String, Vec<Value>>,
    session_id: &str,
    item_id: &str,
    item_type: &str,
    text: &str,
) {
    let turns = histories.entry(session_id.into()).or_default();
    if turns.is_empty() {
        turns.push(json!({"id": Uuid::new_v4().to_string(), "items": []}));
    }
    let items = turns
        .last_mut()
        .and_then(|turn| turn.get_mut("items"))
        .and_then(Value::as_array_mut)
        .expect("history turns contain items");
    if let Some(item) = items
        .iter_mut()
        .find(|item| item.get("id").and_then(Value::as_str) == Some(item_id))
    {
        if item_type == "reasoning" {
            let previous = item
                .pointer("/summary/0")
                .and_then(Value::as_str)
                .unwrap_or_default();
            item["summary"] = json!([format!("{previous}{text}")]);
        } else {
            let previous = item.get("text").and_then(Value::as_str).unwrap_or_default();
            item["text"] = Value::String(format!("{previous}{text}"));
        }
        return;
    }
    items.push(if item_type == "reasoning" {
        json!({"id": item_id, "type": item_type, "summary": [text]})
    } else {
        json!({"id": item_id, "type": item_type, "phase": "final", "text": text})
    });
}

fn value_string(value: Option<&Value>) -> String {
    match value {
        Some(Value::String(value)) => value.clone(),
        Some(Value::Number(value)) => value.to_string(),
        Some(Value::Bool(value)) => value.to_string(),
        _ => String::new(),
    }
}

fn adapter_error(code: impl Into<String>, message: impl Into<String>) -> CodexError {
    CodexError {
        code: code.into(),
        message: sanitize_diagnostic(message.into()),
        retryable: false,
    }
}

fn acp_exit_error(adapter: &str, initializing: bool, code: &str, stderr: &str) -> CodexError {
    let diagnostic = stderr
        .lines()
        .filter(|line| {
            !line.starts_with("Zommi: preparing WSL transport.")
                && !line.starts_with("Zommi: WSL transport ready; launching agent.")
        })
        .collect::<Vec<_>>()
        .join("\n");
    let lower = diagnostic.to_lowercase();
    if adapter == "openclaw-acp"
        && initializing
        && lower.contains("acp bridge failed")
        && [
            "handshake",
            "econnrefused",
            "gateway closed",
            "gateway connection",
            "event loop readiness timeout",
        ]
        .iter()
        .any(|reason| lower.contains(reason))
    {
        return adapter_error(
            "gateway-unavailable",
            format!(
                "OpenClaw ACP started, but could not connect to its Gateway. Run `openclaw gateway status` in the same runtime. Start a stopped local Gateway with `openclaw gateway start`, or check the configured remote Gateway URL and access. Then retry; other agents remain available.\n{diagnostic}"
            ),
        );
    }
    adapter_error(
        "runtime-exited",
        format!("ACP process exited with code {code}. {diagnostic}"),
    )
}

fn short_id(value: &str) -> &str {
    value.get(..8).unwrap_or(value)
}

// These upstream versions recreate a recording with the requested ID before
// resolving session/load. Keep the CLI-owned file untouched until fixed upstream.
fn unsafe_gemini_resume(target: &RuntimeTarget, state: &State) -> bool {
    target.adapter_id == "gemini-acp"
        && state
            .runtime_version
            .as_deref()
            .is_some_and(|v| v.starts_with("0.60.") || v.starts_with("0.61."))
}
fn gemini_resume_error() -> CodexError {
    adapter_error(
        "capability-unavailable",
        "Gemini CLI 0.60/0.61 cannot safely resume saved chats through ACP. The saved conversation was left unchanged. Start a new chat or use a CLI release that fixes session/load.",
    )
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::{State, acp_image, apply_model_configuration, negotiated_capabilities};

    #[test]
    fn model_configuration_handles_grouped_options_and_authoritative_updates() {
        let mut state = State::default();
        apply_model_configuration(
            &mut state,
            &json!({"configOptions": [{
                "id": "provider-model", "category": "model", "type": "select",
                "currentValue": "provider/a", "options": [
                    {"value": "provider/a", "name": "A"},
                    {"group": "provider", "name": "Provider", "options": [
                        {"value": "provider/b", "name": "B"}
                    ]}
                ]
            }]}),
        );
        assert_eq!(state.model_config_id.as_deref(), Some("provider-model"));
        assert_eq!(state.active_model.as_deref(), Some("provider/a"));
        assert_eq!(state.models.len(), 2);
        assert_eq!(state.models[1]["displayName"], "B");
        assert!(state.capabilities.contains(&"model.select.v1".into()));
        apply_model_configuration(&mut state, &json!({}));
        assert_eq!(
            state.models.len(),
            2,
            "empty legacy acknowledgement preserves inventory"
        );
        apply_model_configuration(&mut state, &json!({"configOptions": []}));
        assert!(state.models.is_empty());
        assert!(state.model_config_id.is_none());
        assert!(!state.capabilities.contains(&"model.select.v1".into()));
        apply_model_configuration(
            &mut state,
            &json!({
                "currentModelId": "legacy/a",
                "availableModels": [{"modelId": "legacy/a", "name": "Legacy A"}]
            }),
        );
        assert_eq!(state.active_model.as_deref(), Some("legacy/a"));
        assert_eq!(state.models[0]["id"], "legacy/a");
    }

    #[test]
    fn capabilities_come_from_the_acp_handshake() {
        let capabilities = negotiated_capabilities(&json!({
            "agentCapabilities": {
                "loadSession": true,
                "promptCapabilities": {"image": true},
                "sessionCapabilities": {"list": {}}
            }
        }));
        assert!(capabilities.contains(&"session.resume.v1".into()));
        assert!(capabilities.contains(&"session.list.v1".into()));
        assert!(capabilities.contains(&"input.image.v1".into()));
    }

    #[test]
    fn converts_image_data_urls_to_acp_content() {
        assert_eq!(
            acp_image("data:image/png;base64,aGVsbG8=").expect("valid image"),
            json!({"type": "image", "mimeType": "image/png", "data": "aGVsbG8="})
        );
    }
}
