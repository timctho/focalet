use std::{
    collections::{HashMap, HashSet},
    fs,
    path::{Path, PathBuf},
    process::Stdio,
    sync::{
        Arc, Weak,
        atomic::{AtomicU64, Ordering},
    },
};

use base64::Engine as _;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    process::{ChildStdin, Command},
    sync::{Mutex, oneshot},
    task::JoinHandle,
    time::{Duration, timeout},
};
use uuid::Uuid;

use crate::{
    RuntimeCommand, RuntimeTarget, SessionBindingStore,
    artifacts::artifacts_from_content,
    build_context_handoff,
    codex_adapter::{CodexError, CoreEvent, EventSender, TurnReceipt},
    sanitize_diagnostic, validate_turn_input,
};

const REQUEST_TIMEOUT: Duration = Duration::from_secs(30);

#[derive(Debug, Clone)]
pub struct PiConfig {
    pub target: RuntimeTarget,
    pub command: RuntimeCommand,
    pub cwd: PathBuf,
    pub preferred_session_id: Option<String>,
    pub preferred_session_file: Option<String>,
}

pub struct PiTurnRequest<'a> {
    pub session_id: &'a str,
    pub message: &'a str,
    pub slash_command: bool,
    pub snapshots: &'a [Value],
    pub images: &'a [String],
    pub client_operation_id: &'a str,
    pub model: Option<&'a str>,
    pub effort: Option<&'a str>,
}

#[derive(Clone)]
pub struct PiAdapter {
    inner: Arc<Inner>,
}

struct Inner {
    target: RuntimeTarget,
    command: RuntimeCommand,
    cwd: PathBuf,
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
    command: String,
    completion: oneshot::Sender<Result<Value, CodexError>>,
}

#[derive(Default)]
struct State {
    command_catalogs: HashMap<String, Vec<Value>>,
    rewind_supported: bool,
    protocol_version: u64,
    runtime_version: Option<String>,
    runtime_state: Value,
    messages: Vec<Value>,
    models: Vec<Value>,
    thinking_levels: Vec<String>,
    sessions: HashMap<String, Value>,
    active_turns: HashMap<String, String>,
    turn_operations: HashMap<String, String>,
    interrupting_turns: HashSet<String>,
    questions: HashMap<String, PendingQuestion>,
    stderr: String,
    stopping: bool,
    exited: bool,
}

struct PendingQuestion {
    session_id: String,
    rpc_id: Value,
    method: String,
}

impl PiAdapter {
    pub async fn connect(mut config: PiConfig, event_tx: EventSender) -> Result<Self, CodexError> {
        if config.preferred_session_file.is_none()
            && let Some(id) = &config.preferred_session_id
        {
            config.preferred_session_file = stored_session_file(&config.target.id, id)?;
        }
        set_launch_cwd(&mut config.command, &config.target, &config.cwd)?;
        let mut command = Command::new(&config.command.command);
        config.target.apply_launch_environment(&mut command);
        command.args(&config.command.args);
        if let Some(file) = &config.preferred_session_file {
            command.args(["--session", file]);
        } else if let Some(id) = &config.preferred_session_id {
            // Legacy catalogs retained only the ID. Let Pi resolve its own
            // complete UUID; never invent a path or treat an ID as a file.
            Uuid::parse_str(id).map_err(|_| {
                pi_error(
                    "invalid-request",
                    "Pi needs an exact saved session ID or its native session file.",
                )
            })?;
            command.args(["--session", id]);
        }
        command
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true);
        if config.target.execution_host.kind != "wsl" && config.cwd.is_dir() {
            command.current_dir(&config.cwd);
        }
        let mut child = command.spawn().map_err(|error| {
            pi_error(
                "runtime-unavailable",
                format!("Could not start Pi RPC: {error}"),
            )
        })?;
        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| pi_error("runtime-unavailable", "Pi RPC has no stdin."))?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| pi_error("runtime-unavailable", "Pi RPC has no stdout."))?;
        let stderr = child
            .stderr
            .take()
            .ok_or_else(|| pi_error("runtime-unavailable", "Pi RPC has no stderr."))?;
        let adapter = Self {
            inner: Arc::new(Inner {
                target: config.target,
                command: config.command,
                cwd: config.cwd,
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
        adapter
            .inner
            .emit_status("Connecting to Pi RPC…", "connecting", None, None);
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
            .initialize(config.preferred_session_file, config.preferred_session_id)
            .await
        {
            adapter.shutdown().await;
            return Err(error);
        }
        Ok(adapter)
    }

    async fn initialize(
        &self,
        preferred_session_file: Option<String>,
        preferred_session_id: Option<String>,
    ) -> Result<(), CodexError> {
        self.refresh_state(false).await?;
        self.inner.state.lock().await.protocol_version = 1;
        let current_file = self
            .inner
            .state
            .lock()
            .await
            .runtime_state
            .get("sessionFile")
            .and_then(Value::as_str)
            .map(str::to_owned);
        if let Some(session_file) = preferred_session_file
            && current_file.as_deref() != Some(&session_file)
        {
            let result = self
                .inner
                .request(json!({"type": "switch_session", "sessionPath": session_file}))
                .await?;
            if result.pointer("/data/cancelled").and_then(Value::as_bool) == Some(true) {
                return Err(pi_error(
                    "runtime-rejected",
                    "Pi cancelled the bound session resume.",
                ));
            }
        }
        self.refresh_state(true).await?;
        if let Some(expected) = preferred_session_id
            && self.active_session_id().await? != expected
        {
            return Err(pi_error(
                "identity-mismatch",
                "Pi resumed a different session than requested.",
            ));
        }
        let fork_entries = self
            .inner
            .request(json!({"type":"get_fork_messages"}))
            .await
            .ok()
            .and_then(|value| {
                value
                    .pointer("/data/messages")
                    .and_then(Value::as_array)
                    .cloned()
            });
        {
            let mut state = self.inner.state.lock().await;
            state.rewind_supported = fork_entries.is_some();
            if let Some(entries) = fork_entries {
                let _ = identify_user_entries(&mut state.messages, &entries);
            }
        }
        let state = self.inner.state.lock().await;
        if state.runtime_state.get("model").is_none() || state.models.is_empty() {
            return Err(pi_error(
                "authentication-required",
                "Pi sign-in required; open Pi and use /login or configure an API key.",
            ));
        }
        let session_id = runtime_session_id(&state.runtime_state)?;
        drop(state);
        self.inner.emit_status(
            &format!("Pi ready · {}", short_id(&session_id)),
            "ready",
            Some(&session_id),
            None,
        );
        Ok(())
    }

    pub async fn is_running(&self) -> bool {
        let state = self.inner.state.lock().await;
        !state.exited && !state.stopping
    }

    pub fn target_id(&self) -> &str {
        &self.inner.target.id
    }

    pub async fn active_session_id(&self) -> Result<String, CodexError> {
        runtime_session_id(&self.inner.state.lock().await.runtime_state)
    }

    pub async fn binding_metadata(&self) -> Option<Value> {
        self.inner
            .state
            .lock()
            .await
            .runtime_state
            .get("sessionFile")
            .and_then(Value::as_str)
            .map(|session_file| json!({"sessionFile": session_file}))
    }

    pub async fn list_commands(
        &self,
        session_id: &str,
        force: bool,
    ) -> Result<Vec<Value>, CodexError> {
        if self.active_session_id().await? != session_id {
            return Err(crate::command_catalog::error(
                "Command catalog belongs to a different session.",
            ));
        }
        if !force
            && let Some(commands) = self
                .inner
                .state
                .lock()
                .await
                .command_catalogs
                .get(session_id)
                .cloned()
        {
            return Ok(commands);
        }
        let response = self.inner.request(json!({"type":"get_commands"})).await?;
        let commands = crate::command_catalog::normalize(
            response
                .pointer("/data/commands")
                .and_then(Value::as_array)
                .ok_or_else(|| {
                    crate::command_catalog::error("Pi did not return a command catalog.")
                })?,
        );
        self.inner
            .state
            .lock()
            .await
            .command_catalogs
            .insert(session_id.into(), commands.clone());
        Ok(commands)
    }

    pub async fn connection_value(&self) -> Result<Value, CodexError> {
        let state = self.inner.state.lock().await;
        let session_id = runtime_session_id(&state.runtime_state)?;
        let mut capabilities = vec![
            "session.create.v1",
            "session.resume.v1",
            "history.read.v1",
            "turn.stream.v1",
            "turn.interrupt.v1",
            "turn.steer.v1",
            "input.image.v1",
            "model.select.v1",
            "reasoning.select.v1",
            "question.resolve.v1",
        ];
        if state.rewind_supported {
            capabilities.extend(["session.rewind.v1", "session.rewind.prepare.v1"]);
        }
        Ok(json!({
            "runtimeTargetId": self.inner.target.id,
            "sessionId": session_id,
            "protocolVersion": state.protocol_version,
            "runtimeVersion": state.runtime_version,
            "capabilities": capabilities,
            "models": state.models,
            "sessions": state.sessions.values().cloned().collect::<Vec<_>>(),
            "history": {"thread": {"id": session_id, "turns": messages_to_turns(&state.messages)}},
            "sessionMetadata": {
                "sessionFile": state.runtime_state.get("sessionFile"),
                "activeModel": state.runtime_state.get("model").and_then(pi_model_id),
                "activeEffort": state.runtime_state.get("thinkingLevel")
            }
        }))
    }

    pub async fn list_sessions(&self) -> Result<Vec<Value>, CodexError> {
        self.refresh_state(false).await?;
        Ok(self
            .inner
            .state
            .lock()
            .await
            .sessions
            .values()
            .cloned()
            .collect())
    }

    pub async fn create_session(
        &self,
        model: Option<&str>,
        effort: Option<&str>,
    ) -> Result<Value, CodexError> {
        let result = self.inner.request(json!({"type": "new_session"})).await?;
        if result.pointer("/data/cancelled").and_then(Value::as_bool) == Some(true) {
            return Err(pi_error(
                "runtime-rejected",
                "Pi cancelled the new session.",
            ));
        }
        self.refresh_state(true).await?;
        self.apply_options(model, effort).await?;
        self.connection_value().await
    }

    pub async fn open_session(
        &self,
        session_id: &str,
        cwd: Option<&str>,
    ) -> Result<Value, CodexError> {
        let known_file = self
            .inner
            .state
            .lock()
            .await
            .sessions
            .get(session_id)
            .and_then(|session| session.get("sessionFile"))
            .and_then(Value::as_str)
            .map(str::to_owned);
        let session_file =
            match known_file.or(stored_session_file(&self.inner.target.id, session_id)?) {
                Some(file) => file,
                None => {
                    // Recover pre-index catalog entries through Pi's native CLI.
                    // The temporary connection must return the exact ID before its
                    // file is used; no prompt, fork or new_session is requested.
                    let (events, _discarded) = tokio::sync::mpsc::unbounded_channel();
                    let probe = Self::connect(
                        PiConfig {
                            target: self.inner.target.clone(),
                            command: self.inner.command.clone(),
                            cwd: cwd
                                .map(PathBuf::from)
                                .unwrap_or_else(|| self.inner.cwd.clone()),
                            preferred_session_id: Some(session_id.into()),
                            preferred_session_file: None,
                        },
                        events,
                    )
                    .await?;
                    let file = probe
                        .binding_metadata()
                        .await
                        .and_then(|value| value["sessionFile"].as_str().map(str::to_owned));
                    probe.shutdown().await;
                    file.ok_or_else(|| {
                        pi_error(
                            "session-not-found",
                            "Pi did not return a file for this saved session.",
                        )
                    })?
                }
            };
        let previous_file = self
            .binding_metadata()
            .await
            .and_then(|metadata| metadata["sessionFile"].as_str().map(str::to_owned));
        let previous_id = self.active_session_id().await?;
        let result = self
            .inner
            .request(json!({"type": "switch_session", "sessionPath": session_file}))
            .await?;
        if result.pointer("/data/cancelled").and_then(Value::as_bool) == Some(true) {
            return Err(pi_error(
                "runtime-rejected",
                "Pi cancelled the session switch.",
            ));
        }
        self.refresh_state(true).await?;
        if self.active_session_id().await? != session_id {
            // Never leave a failed selection pointing at another native chat.
            let restored = if let Some(file) = previous_file {
                self.inner
                    .request(json!({"type":"switch_session","sessionPath":file}))
                    .await
                    .is_ok()
                    && self.refresh_state(true).await.is_ok()
                    && self.active_session_id().await.as_deref() == Ok(previous_id.as_str())
            } else {
                false
            };
            if !restored {
                self.shutdown().await;
            }
            return Err(pi_error(
                "identity-mismatch",
                "Pi switched to a different session than requested.",
            ));
        }
        self.connection_value().await
    }

    pub async fn read_session(&self, session_id: &str) -> Result<Value, CodexError> {
        if self.active_session_id().await? != session_id {
            return Err(pi_error(
                "identity-mismatch",
                "Pi history is available only for the exact loaded session.",
            ));
        }
        let messages = self.load_messages().await?;
        self.inner.state.lock().await.messages = messages.clone();
        Ok(json!({"thread": {"id": session_id, "turns": messages_to_turns(&messages)}}))
    }

    async fn load_messages(&self) -> Result<Vec<Value>, CodexError> {
        let response = self.inner.request(json!({"type": "get_messages"})).await?;
        let mut messages = response
            .pointer("/data/messages")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        if self.inner.state.lock().await.rewind_supported {
            let fork = self
                .inner
                .request(json!({"type":"get_fork_messages"}))
                .await?;
            if let Some(entries) = fork.pointer("/data/messages").and_then(Value::as_array) {
                // Ambiguous historical branches remain readable; preparation
                // will refuse to mutate without exact entry identities.
                let _ = identify_user_entries(&mut messages, entries);
            }
        }
        Ok(messages)
    }

    pub async fn prepare_rewind(&self, session_id: &str) -> Result<Value, CodexError> {
        let live = self.inner.request(json!({"type":"get_state"})).await?;
        if live.pointer("/data/sessionId").and_then(Value::as_str) != Some(session_id) {
            return Err(pi_error(
                "identity-mismatch",
                "The requested Pi chat is not active.",
            ));
        }
        if live["data"]["isStreaming"] == true
            || live["data"]["isCompacting"] == true
            || live["data"]["pendingMessageCount"].as_u64().unwrap_or(0) > 0
            || self
                .inner
                .state
                .lock()
                .await
                .active_turns
                .contains_key(session_id)
        {
            return Err(pi_error(
                "session-busy",
                "Stop Pi before editing an earlier message.",
            ));
        }
        let response = self.inner.request(json!({"type":"get_messages"})).await?;
        let mut messages = response
            .pointer("/data/messages")
            .and_then(Value::as_array)
            .cloned()
            .ok_or_else(|| crate::session_rewind::error("Pi did not return history."))?;
        let fork = self
            .inner
            .request(json!({"type":"get_fork_messages"}))
            .await?;
        let entries = fork
            .pointer("/data/messages")
            .and_then(Value::as_array)
            .ok_or_else(|| crate::session_rewind::error("Pi does not expose message entry IDs."))?;
        identify_user_entries(&mut messages, entries)?;
        Ok(json!({"thread":{"id":session_id,"turns":messages_to_turns(&messages)}}))
    }

    pub async fn rewind_session(
        &self,
        session_id: &str,
        turn_id: &str,
        last_id: &str,
    ) -> Result<Value, CodexError> {
        let before = self.prepare_rewind(session_id).await?;
        let index = crate::session_rewind::target(&before, turn_id, last_id)?;
        let old_file = self
            .binding_metadata()
            .await
            .and_then(|value| value["sessionFile"].as_str().map(str::to_owned))
            .ok_or_else(|| {
                crate::session_rewind::error("Pi did not expose its original session file.")
            })?;
        let fork = self
            .inner
            .request(json!({"type":"fork","entryId":turn_id}))
            .await
            .map_err(|mut error| {
                error.retryable = false;
                error
            })?;
        if fork.pointer("/data/cancelled").and_then(Value::as_bool) == Some(true) {
            return Err(pi_error(
                "runtime-rejected",
                "Pi cancelled the edit branch.",
            ));
        }
        let verify = async {
            self.refresh_state(true).await?;
            let new_id = self.active_session_id().await?;
            if new_id == session_id {
                return Err(crate::session_rewind::error(
                    "Pi did not create a new edit branch.",
                ));
            }
            let mut after = self.prepare_rewind(&new_id).await?;
            crate::session_rewind::verify_prefix(&before, &after, index)?;
            after["sourceSessionId"] = json!(session_id);
            after["connection"] = self.connection_value().await?;
            Ok(after)
        }
        .await;
        if verify.is_err() {
            // Fork never edits the source file. Restore the original selection
            // if the new branch cannot be verified; do not retry the fork.
            if self
                .inner
                .request(json!({"type":"switch_session","sessionPath":old_file}))
                .await
                .is_ok()
            {
                let _ = self.refresh_state(true).await;
            }
        }
        verify
    }

    pub async fn start_turn(&self, request: PiTurnRequest<'_>) -> Result<TurnReceipt, CodexError> {
        let input = validate_turn_input(request.message, request.snapshots, request.images)?;
        self.apply_options(request.model, request.effort).await?;
        if self.active_session_id().await? != request.session_id {
            return Err(pi_error(
                "identity-mismatch",
                "The requested session is not the exact active Pi session.",
            ));
        }
        let mut command = json!({
            "type": "prompt",
            "message": if request.slash_command { input.message.clone() } else { build_context_handoff(&input.message, &input.snapshots, input.images.len()) }
        });
        if !input.images.is_empty() {
            command["images"] = Value::Array(
                input
                    .images
                    .iter()
                    .map(|image| pi_image(image))
                    .collect::<Result<Vec<_>, _>>()?,
            );
        }
        let turn_id = Uuid::new_v4().to_string();
        {
            let mut state = self.inner.state.lock().await;
            if state.active_turns.contains_key(request.session_id) {
                return Err(pi_error(
                    "session-busy",
                    "This Pi session already has an active turn.",
                ));
            }
            state
                .active_turns
                .insert(request.session_id.into(), turn_id.clone());
            state.turn_operations.insert(
                request.session_id.into(),
                request.client_operation_id.into(),
            );
        }
        self.inner.emit(
            "turn.started",
            Some(request.session_id),
            Some(&turn_id),
            Some(request.client_operation_id),
            json!({"status": "inProgress"}),
        );
        if let Err(error) = self.inner.request(command).await {
            let mut state = self.inner.state.lock().await;
            let matches = state
                .active_turns
                .get(request.session_id)
                .map(String::as_str)
                == Some(turn_id.as_str());
            if matches {
                state.active_turns.remove(request.session_id);
                state.turn_operations.remove(request.session_id);
            }
            drop(state);
            if matches {
                self.inner.emit(
                    "turn.completed",
                    Some(request.session_id),
                    Some(&turn_id),
                    Some(request.client_operation_id),
                    json!({
                        "status": if error.code == "unknown-outcome" { "unknown" } else { "failed" },
                        "error": error.message
                    }),
                );
            }
            return Err(error);
        }
        // Extension commands can finish during prompt preflight without emitting
        // agent_start/agent_end. A state read after the ACK distinguishes these
        // from commands that launched an actual model turn.
        if request.slash_command {
            let response = self.inner.request(json!({"type":"get_state"})).await?;
            let state_value = &response["data"];
            if state_value["isStreaming"] == false
                && state_value["isCompacting"] != true
                && state_value["pendingMessageCount"].as_u64().unwrap_or(0) == 0
            {
                let mut state = self.inner.state.lock().await;
                let complete = state.active_turns.get(request.session_id) == Some(&turn_id);
                if complete {
                    state.active_turns.remove(request.session_id);
                    state.turn_operations.remove(request.session_id);
                }
                drop(state);
                if complete {
                    self.inner.emit("item.update", Some(request.session_id), Some(&turn_id), Some(request.client_operation_id), json!({"kind":"assistant", "lifecycle":"completed", "text":"Command completed.", "itemId":format!("{turn_id}-command")}));
                    self.inner.emit(
                        "turn.completed",
                        Some(request.session_id),
                        Some(&turn_id),
                        Some(request.client_operation_id),
                        json!({"status":"completed"}),
                    );
                }
            }
        }
        Ok(TurnReceipt {
            accepted: true,
            runtime_target_id: self.inner.target.id.clone(),
            session_id: request.session_id.into(),
            turn_id,
            client_operation_id: request.client_operation_id.into(),
        })
    }

    pub async fn steer_turn(
        &self,
        session_id: &str,
        turn_id: &str,
        message: &str,
        images: &[String],
    ) -> Result<Value, CodexError> {
        let state = self.inner.state.lock().await;
        if state.active_turns.get(session_id).map(String::as_str) != Some(turn_id) {
            return Err(pi_error(
                "identity-mismatch",
                "Pi steering identity does not match the exact active turn.",
            ));
        }
        let operation = state.turn_operations.get(session_id).cloned();
        drop(state);
        let mut command = json!({"type": "steer", "message": message});
        if !images.is_empty() {
            command["images"] = Value::Array(
                images
                    .iter()
                    .map(|image| pi_image(image))
                    .collect::<Result<Vec<_>, _>>()?,
            );
        }
        let result = self.inner.request(command).await?;
        Ok(json!({
            "accepted": result.get("success").and_then(Value::as_bool).unwrap_or(true),
            "runtimeTargetId": self.inner.target.id,
            "sessionId": session_id,
            "turnId": turn_id,
            "clientOperationId": operation
        }))
    }

    pub async fn interrupt_turn(
        &self,
        session_id: &str,
        turn_id: &str,
    ) -> Result<Value, CodexError> {
        let state = self.inner.state.lock().await;
        if state.active_turns.get(session_id).map(String::as_str) != Some(turn_id) {
            return Err(pi_error(
                "identity-mismatch",
                "The requested turn is not the exact active Pi turn.",
            ));
        }
        let operation = state.turn_operations.get(session_id).cloned();
        drop(state);
        self.inner.request(json!({"type": "clear_queue"})).await?;
        self.inner
            .state
            .lock()
            .await
            .interrupting_turns
            .insert(format!("{session_id}:{turn_id}"));
        if let Err(error) = self.inner.request(json!({"type": "abort"})).await {
            self.inner
                .state
                .lock()
                .await
                .interrupting_turns
                .remove(&format!("{session_id}:{turn_id}"));
            return Err(error);
        }
        Ok(json!({
            "interrupted": true,
            "runtimeTargetId": self.inner.target.id,
            "sessionId": session_id,
            "turnId": turn_id,
            "clientOperationId": operation
        }))
    }

    pub async fn resolve_question(
        &self,
        session_id: &str,
        question_id: &str,
        answer: &Value,
    ) -> Result<Value, CodexError> {
        let question = self
            .inner
            .state
            .lock()
            .await
            .questions
            .remove(question_id)
            .ok_or_else(|| {
                pi_error(
                    "invalid-request",
                    format!("Unknown Pi question '{question_id}'."),
                )
            })?;
        if question.session_id != session_id {
            self.inner
                .state
                .lock()
                .await
                .questions
                .insert(question_id.into(), question);
            return Err(pi_error(
                "identity-mismatch",
                "The question does not belong to the requested Pi session.",
            ));
        }
        let response = if question.method == "confirm" && answer.get("confirmed").is_some() {
            json!({
                "type": "extension_ui_response", "id": question.rpc_id,
                "confirmed": answer.get("confirmed").and_then(Value::as_bool)
            })
        } else if let Some(value) = answer.get("value").and_then(Value::as_str) {
            json!({"type": "extension_ui_response", "id": question.rpc_id, "value": value})
        } else {
            json!({"type": "extension_ui_response", "id": question.rpc_id, "cancelled": true})
        };
        self.inner.write_json(&response).await?;
        Ok(json!({"resolved": true, "questionId": question_id}))
    }

    pub async fn shutdown(&self) {
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
            let _ = pending
                .completion
                .send(Err(pi_error("runtime-stopped", "Pi RPC stopped.")));
        }
    }

    pub async fn refresh_models(&self) -> Result<Vec<Value>, CodexError> {
        self.refresh_state(false).await?;
        Ok(self.inner.state.lock().await.models.clone())
    }

    async fn refresh_state(&self, include_messages: bool) -> Result<(), CodexError> {
        let state_response = self.inner.request(json!({"type": "get_state"})).await?;
        let runtime_state = state_response
            .get("data")
            .cloned()
            .unwrap_or_else(|| json!({}));
        if let (Ok(id), Some(file)) = (
            runtime_session_id(&runtime_state),
            runtime_state.get("sessionFile").and_then(Value::as_str),
        ) {
            remember_session_file(&self.inner.target.id, &id, file)?;
        }
        let models_response = self
            .inner
            .request(json!({"type": "get_available_models"}))
            .await?;
        let messages_response = if include_messages {
            Some(self.load_messages().await?)
        } else {
            None
        };
        let models = models_response
            .pointer("/data/models")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(model_for_ui)
            .collect::<Vec<_>>();
        let model_id = runtime_state.get("model").and_then(pi_model_id);
        let thinking_levels = model_id
            .as_deref()
            .and_then(|id| {
                models
                    .iter()
                    .find(|model| model.get("id").and_then(Value::as_str) == Some(id))
            })
            .and_then(|model| model.get("supportedReasoningEfforts"))
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(|effort| effort.get("reasoningEffort")?.as_str().map(str::to_owned))
            .collect::<Vec<_>>();
        let mut state = self.inner.state.lock().await;
        state.runtime_version = runtime_state
            .get("version")
            .and_then(Value::as_str)
            .map(str::to_owned)
            .or_else(|| state.runtime_version.clone());
        if let Ok(session_id) = runtime_session_id(&runtime_state) {
            state.sessions.insert(
                session_id.clone(),
                json!({
                    "id": session_id,
                    "name": runtime_state.get("sessionName"),
                    "preview": runtime_state.get("sessionName").and_then(Value::as_str).unwrap_or("Pi session"),
                    "sessionFile": runtime_state.get("sessionFile")
                }),
            );
        }
        state.runtime_state = runtime_state;
        state.models = models;
        state.thinking_levels = thinking_levels;
        if let Some(messages) = messages_response {
            state.messages = messages;
        }
        Ok(())
    }

    async fn apply_options(
        &self,
        model: Option<&str>,
        effort: Option<&str>,
    ) -> Result<(), CodexError> {
        let current_model = self
            .inner
            .state
            .lock()
            .await
            .runtime_state
            .get("model")
            .and_then(pi_model_id);
        if let Some(model_id) =
            model.filter(|model| !model.is_empty() && Some(*model) != current_model.as_deref())
        {
            let model = self
                .inner
                .state
                .lock()
                .await
                .models
                .iter()
                .find(|model| {
                    model.get("id").and_then(Value::as_str) == Some(model_id)
                        || model.get("model").and_then(Value::as_str) == Some(model_id)
                })
                .cloned();
            if let Some(model) = model {
                self.inner
                    .request(json!({
                        "type": "set_model",
                        "provider": model.get("provider"),
                        "modelId": model.get("rawModelId")
                    }))
                    .await?;
                self.inner.state.lock().await.runtime_state["model"] = json!({
                    "provider": model.get("provider"), "id": model.get("rawModelId")
                });
            } else {
                return Err(pi_error(
                    "invalid-request",
                    "Pi no longer advertises that model. Refresh agents and select an available model.",
                ));
            }
        }
        if let Some(effort) = effort {
            let mut state = self.inner.state.lock().await;
            let supported = state.thinking_levels.iter().any(|level| level == effort);
            let changed = state
                .runtime_state
                .get("thinkingLevel")
                .and_then(Value::as_str)
                != Some(effort);
            drop(state);
            if supported && changed {
                self.inner
                    .request(json!({"type": "set_thinking_level", "level": effort}))
                    .await?;
                state = self.inner.state.lock().await;
                state.runtime_state["thinkingLevel"] = Value::String(effort.into());
            }
        }
        Ok(())
    }
}

impl Inner {
    async fn request(&self, command: Value) -> Result<Value, CodexError> {
        if self.state.lock().await.exited {
            return Err(pi_error("runtime-exited", "Pi RPC is not running."));
        }
        let command_type = command
            .get("type")
            .and_then(Value::as_str)
            .unwrap_or("unknown")
            .to_owned();
        let id = format!(
            "focalet-{}",
            self.next_request_id
                .fetch_add(1, Ordering::Relaxed)
                .saturating_add(1)
        );
        let (completion, receiver) = oneshot::channel();
        self.pending.lock().await.insert(
            id.clone(),
            PendingRequest {
                command: command_type.clone(),
                completion,
            },
        );
        let mut request = command;
        request["id"] = Value::String(id.clone());
        if let Err(error) = self.write_json(&request).await {
            self.pending.lock().await.remove(&id);
            return Err(error);
        }
        match timeout(REQUEST_TIMEOUT, receiver).await {
            Ok(Ok(result)) => result,
            Ok(Err(_)) => Err(pi_error(
                "runtime-exited",
                "Pi RPC response channel closed.",
            )),
            Err(_) => {
                self.pending.lock().await.remove(&id);
                Err(CodexError {
                    code: "unknown-outcome".into(),
                    message: format!("Pi RPC did not respond to '{command_type}' in time."),
                    retryable: true,
                })
            }
        }
    }

    async fn write_json(&self, value: &Value) -> Result<(), CodexError> {
        let mut bytes = serde_json::to_vec(value)
            .map_err(|error| pi_error("protocol-error", error.to_string()))?;
        bytes.push(b'\n');
        let mut stdin = self.stdin.lock().await;
        stdin
            .write_all(&bytes)
            .await
            .map_err(|error| pi_error("runtime-exited", error.to_string()))?;
        stdin
            .flush()
            .await
            .map_err(|error| pi_error("runtime-exited", error.to_string()))
    }

    async fn handle_message(&self, message: Value) {
        if message.get("type").and_then(Value::as_str) == Some("response") {
            let id = value_string(message.get("id"));
            let Some(pending) = self.pending.lock().await.remove(&id) else {
                return;
            };
            let result = if message.get("success").and_then(Value::as_bool) == Some(true) {
                Ok(message)
            } else {
                Err(pi_error(
                    "runtime-request-failed",
                    message
                        .get("error")
                        .and_then(Value::as_str)
                        .map(str::to_owned)
                        .unwrap_or_else(|| format!("Pi {} failed.", pending.command)),
                ))
            };
            let _ = pending.completion.send(result);
            return;
        }
        if message.get("type").and_then(Value::as_str) == Some("extension_ui_request") {
            self.handle_question(&message).await;
            return;
        }
        self.handle_event(&message).await;
    }

    async fn handle_question(&self, message: &Value) {
        let method = message
            .get("method")
            .and_then(Value::as_str)
            .unwrap_or_default();
        if matches!(method, "notify" | "setStatus") {
            let text = message
                .get("message")
                .or_else(|| message.get("statusText"))
                .and_then(Value::as_str)
                .unwrap_or_default();
            if !text.is_empty() {
                self.emit_status(text, "ready", None, None);
            }
            return;
        }
        if !matches!(method, "select" | "confirm" | "input" | "editor") {
            self.emit(
                "runtime.diagnostic",
                None,
                None,
                None,
                json!({"method": format!("extension:{method}")}),
            );
            return;
        }
        let question_id = Uuid::new_v4().to_string();
        let mut state = self.state.lock().await;
        let session_id = state
            .runtime_state
            .get("sessionId")
            .and_then(Value::as_str)
            .map(str::to_owned)
            .unwrap_or_default();
        state.questions.insert(
            question_id.clone(),
            PendingQuestion {
                session_id: session_id.clone(),
                rpc_id: message.get("id").cloned().unwrap_or(Value::Null),
                method: method.into(),
            },
        );
        drop(state);
        self.emit(
            "question.requested",
            Some(&session_id),
            None,
            None,
            json!({
                "questionId": question_id,
                "method": method,
                "title": message.get("title").and_then(Value::as_str).unwrap_or("Pi requests input"),
                "message": message.get("message").and_then(Value::as_str).unwrap_or(""),
                "options": message.get("options").cloned().unwrap_or_else(|| json!([])),
                "placeholder": message.get("placeholder").and_then(Value::as_str).unwrap_or(""),
                "prefill": message.get("prefill").and_then(Value::as_str).unwrap_or("")
            }),
        );
    }

    async fn handle_event(&self, event: &Value) {
        let event_type = event
            .get("type")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let mut state = self.state.lock().await;
        let session_id = state
            .runtime_state
            .get("sessionId")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned();
        let turn_id = state.active_turns.get(&session_id).cloned();
        let operation = state.turn_operations.get(&session_id).cloned();
        if event_type == "agent_end" || event_type == "agent_settled" {
            let Some(turn_id) = turn_id else {
                return;
            };
            state.active_turns.remove(&session_id);
            state.turn_operations.remove(&session_id);
            let interrupted = state
                .interrupting_turns
                .remove(&format!("{session_id}:{turn_id}"));
            drop(state);
            self.emit(
                "turn.completed",
                Some(&session_id),
                Some(&turn_id),
                operation.as_deref(),
                json!({"status": if interrupted { "interrupted" } else { "completed" }}),
            );
            return;
        }
        if turn_id.is_none()
            && matches!(
                event_type,
                "message_update"
                    | "tool_execution_start"
                    | "tool_execution_update"
                    | "tool_execution_end"
            )
        {
            return;
        }
        let payload = if event_type == "message_update" {
            let update = event
                .get("assistantMessageEvent")
                .cloned()
                .unwrap_or_else(|| json!({}));
            let update_type = update
                .get("type")
                .and_then(Value::as_str)
                .unwrap_or_default();
            if matches!(update_type, "text_delta" | "thinking_delta") {
                Some(json!({
                    "kind": if update_type == "text_delta" { "assistant" } else { "thinking" },
                    "lifecycle": "delta",
                    "title": if update_type == "text_delta" { "Pi" } else { "Thinking" },
                    "text": update.get("delta").and_then(Value::as_str).unwrap_or(""),
                    "itemId": format!("{}-{}", turn_id.as_deref().unwrap_or(&session_id),
                        update.get("contentIndex").map(Value::to_string).unwrap_or_else(|| update_type.into()))
                }))
            } else if update_type == "toolcall_start" {
                Some(json!({
                    "kind": "tool", "lifecycle": "started",
                    "title": update.get("toolName").and_then(Value::as_str).unwrap_or("Tool"),
                    "text": "", "itemId": update.get("id")
                }))
            } else {
                None
            }
        } else if matches!(
            event_type,
            "tool_execution_start" | "tool_execution_update" | "tool_execution_end"
        ) {
            let lifecycle = if event_type.ends_with("_start") {
                "started"
            } else if event_type.ends_with("_end") {
                "completed"
            } else {
                "delta"
            };
            let content = event
                .get("result")
                .or_else(|| event.get("partialResult"))
                .and_then(|result| result.get("content"));
            let mut payload = json!({
                "kind": if lifecycle == "delta" { "toolOutput" } else { "tool" },
                "lifecycle": lifecycle,
                "title": event.get("toolName").and_then(Value::as_str).unwrap_or("Tool"),
                "text": content_text(content).unwrap_or_else(|| event.get("args").map(Value::to_string).unwrap_or_default()),
                "itemId": event.get("toolCallId"),
                "status": if event.get("isError").and_then(Value::as_bool) == Some(true) { "failed" } else if lifecycle == "completed" { "completed" } else { "" }
            });
            let artifacts = artifacts_from_content(content, self.cwd.to_str());
            if !artifacts.is_empty() {
                payload["artifacts"] = Value::Array(artifacts);
            }
            Some(payload)
        } else {
            None
        };
        drop(state);
        if let Some(payload) = payload {
            self.emit(
                "item.update",
                Some(&session_id),
                turn_id.as_deref(),
                operation.as_deref(),
                payload,
            );
        } else if event_type == "extension_error" {
            self.emit_status(
                event
                    .get("error")
                    .and_then(Value::as_str)
                    .unwrap_or("Pi extension failed."),
                "degraded",
                Some(&session_id),
                turn_id.as_deref(),
            );
        } else {
            self.emit(
                "runtime.diagnostic",
                Some(&session_id),
                turn_id.as_deref(),
                operation.as_deref(),
                json!({"method": event_type}),
            );
        }
    }

    async fn handle_exit(&self, status: std::io::Result<std::process::ExitStatus>) {
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
        let message =
            sanitize_diagnostic(format!("Pi RPC exited with code {code}. {}", state.stderr));
        let active = std::mem::take(&mut state.active_turns);
        let operations = std::mem::take(&mut state.turn_operations);
        drop(state);
        let pending = std::mem::take(&mut *self.pending.lock().await);
        for (_, pending) in pending {
            let _ = pending
                .completion
                .send(Err(pi_error("runtime-exited", message.clone())));
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
                        inner.emit_status("Pi RPC emitted invalid JSON.", "degraded", None, None)
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

fn pi_model_id(model: &Value) -> Option<String> {
    Some(format!(
        "{}/{}",
        model.get("provider")?.as_str()?,
        model.get("id")?.as_str()?
    ))
}

fn model_for_ui(model: &Value) -> Option<Value> {
    let provider = model.get("provider")?.as_str()?;
    let raw_id = model.get("id")?.as_str()?;
    let id = format!("{provider}/{raw_id}");
    let efforts = pi_thinking_levels(model)
        .into_iter()
        .map(|reasoning_effort| json!({"reasoningEffort": reasoning_effort}))
        .collect::<Vec<_>>();
    Some(json!({
        "id": id,
        "model": id,
        "provider": provider,
        "rawModelId": raw_id,
        "displayName": model.get("name").and_then(Value::as_str).unwrap_or(&id),
        "description": provider,
        "supportedReasoningEfforts": efforts
    }))
}

fn pi_thinking_levels(model: &Value) -> Vec<&'static str> {
    if model.get("reasoning").and_then(Value::as_bool) != Some(true) {
        return vec!["off"];
    }
    ["off", "minimal", "low", "medium", "high", "xhigh"]
        .into_iter()
        .filter(|level| {
            let mapped = model.pointer(&format!("/thinkingLevelMap/{level}"));
            !mapped.is_some_and(Value::is_null) && (*level != "xhigh" || mapped.is_some())
        })
        .collect()
}

fn identify_user_entries(messages: &mut [Value], entries: &[Value]) -> Result<(), CodexError> {
    let users = messages
        .iter()
        .enumerate()
        .filter(|(_, message)| message["role"] == "user")
        .map(|(index, message)| {
            let text = if let Some(text) = message["content"].as_str() {
                text.to_owned()
            } else {
                message["content"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter(|part| part["type"] == "text")
                    .filter_map(|part| part["text"].as_str())
                    .collect::<String>()
            };
            (index, text)
        })
        .collect::<Vec<_>>();
    let mut forward = Vec::new();
    let mut next = 0;
    for (_, text) in &users {
        let found = (next..entries.len())
            .find(|&index| entries[index]["text"].as_str() == Some(text.as_str()))
            .ok_or_else(|| {
                crate::session_rewind::error(
                    "Pi history could not be matched to native message entries.",
                )
            })?;
        forward.push(found);
        next = found + 1;
    }
    let mut previous = entries.len();
    for ((_, text), &expected) in users.iter().zip(&forward).rev() {
        let found = (0..previous)
            .rev()
            .find(|&index| entries[index]["text"].as_str() == Some(text.as_str()));
        if found != Some(expected) {
            return Err(crate::session_rewind::error(
                "Pi history matches more than one branch; select an unambiguous branch before editing.",
            ));
        }
        previous = expected;
    }
    for ((index, _), entry) in users.iter().zip(forward) {
        let id = entries[entry]["entryId"]
            .as_str()
            .filter(|id| !id.is_empty())
            .ok_or_else(|| {
                crate::session_rewind::error("Pi returned an empty message entry ID.")
            })?;
        messages[*index]["id"] = json!(id);
    }
    Ok(())
}

fn messages_to_turns(messages: &[Value]) -> Vec<Value> {
    let mut turns = Vec::<Value>::new();
    for message in messages {
        let role = message
            .get("role")
            .and_then(Value::as_str)
            .unwrap_or_default();
        if role == "user" {
            let id = value_string(message.get("id"));
            turns.push(json!({
                "id": if id.is_empty() { Uuid::new_v4().to_string() } else { id.clone() },
                "items": [{
                    "id": format!("{}-user", if id.is_empty() { Uuid::new_v4().to_string() } else { id }),
                    "type": "userMessage", "content": [{"type": "text", "text": message_text(message, None)}]
                }]
            }));
            continue;
        }
        if turns.is_empty() {
            turns.push(json!({"id": Uuid::new_v4().to_string(), "items": []}));
        }
        let items = turns
            .last_mut()
            .and_then(|turn| turn.get_mut("items"))
            .and_then(Value::as_array_mut)
            .expect("turn items");
        let id = value_string(message.get("id"));
        if role == "assistant" {
            let reasoning = message_text(message, Some("thinking"));
            let text = message_text(message, Some("text"));
            if !reasoning.is_empty() {
                items.push(json!({
                    "id": format!("{id}-thinking"), "type": "reasoning",
                    "status": "completed", "summary": [reasoning]
                }));
            }
            if !text.is_empty() {
                items.push(json!({
                    "id": format!("{id}-assistant"), "type": "agentMessage",
                    "phase": "final", "status": "completed", "text": text
                }));
            }
            for content in message
                .get("content")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter(|content| content.get("type").and_then(Value::as_str) == Some("toolCall"))
            {
                items.push(json!({
                    "id": content.get("id"), "type": "dynamicToolCall",
                    "tool": content.get("name").and_then(Value::as_str).unwrap_or("Tool"),
                    "status": "completed", "rawInput": content.get("arguments")
                }));
            }
        } else if role == "toolResult" {
            let artifacts = artifacts_from_content(message.get("content"), None);
            items.push(json!({
                "id": message.get("toolCallId").or_else(|| message.get("id")),
                "type": "commandExecution",
                "status": if message.get("isError").and_then(Value::as_bool) == Some(true) { "failed" } else { "completed" },
                "aggregatedOutput": message_text(message, None),
                "artifacts": artifacts
            }));
        }
    }
    turns
}

fn message_text(message: &Value, content_type: Option<&str>) -> String {
    if let Some(text) = message.get("content").and_then(Value::as_str) {
        return if content_type.is_none() || content_type == Some("text") {
            text.into()
        } else {
            String::new()
        };
    }
    message
        .get("content")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter(|content| {
            content_type.is_none() || content.get("type").and_then(Value::as_str) == content_type
        })
        .filter_map(|content| content.get("text").and_then(Value::as_str))
        .collect::<Vec<_>>()
        .join("\n")
}

fn content_text(content: Option<&Value>) -> Option<String> {
    let values = content?.as_array()?;
    let text = values
        .iter()
        .filter_map(|item| item.get("text").and_then(Value::as_str))
        .collect::<Vec<_>>()
        .join("\n");
    (!text.is_empty()).then_some(text)
}

fn pi_image(value: &str) -> Result<Value, CodexError> {
    let (header, data) = value.split_once(',').ok_or_else(|| {
        pi_error(
            "invalid-request",
            "Pi image context must be a base64 image data URL.",
        )
    })?;
    let mime_type = header
        .strip_prefix("data:")
        .and_then(|value| value.strip_suffix(";base64"))
        .filter(|value| value.starts_with("image/"))
        .ok_or_else(|| {
            pi_error(
                "invalid-request",
                "Pi image context must be a base64 image data URL.",
            )
        })?;
    base64::engine::general_purpose::STANDARD
        .decode(data)
        .map_err(|_| pi_error("invalid-request", "Pi image data is invalid base64."))?;
    Ok(json!({"type": "image", "mimeType": mime_type, "data": data}))
}

fn runtime_session_id(state: &Value) -> Result<String, CodexError> {
    state
        .get("sessionId")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .map(str::to_owned)
        .ok_or_else(|| pi_error("invalid-response", "Pi did not expose a session id."))
}

fn set_launch_cwd(
    command: &mut RuntimeCommand,
    target: &RuntimeTarget,
    cwd: &Path,
) -> Result<(), CodexError> {
    if target.execution_host.kind != "wsl" {
        return Ok(());
    }
    let cwd = cwd
        .to_str()
        .filter(|value| value.starts_with('/') && !value.contains('\0'))
        .ok_or_else(|| {
            pi_error(
                "invalid-request",
                "Pi needs an absolute workspace path in WSL.",
            )
        })?;
    let boundary = command
        .args
        .iter()
        .position(|arg| arg == "--" || arg == "-e")
        .ok_or_else(|| {
            pi_error(
                "invalid-configuration",
                "Pi WSL command has no execution boundary.",
            )
        })?;
    if let Some(index) = command.args[..boundary]
        .iter()
        .position(|arg| arg == "--cwd" || arg == "--cd")
    {
        if index + 1 >= boundary {
            return Err(pi_error(
                "invalid-configuration",
                "Pi WSL command has no workspace.",
            ));
        }
        command.args[index + 1] = cwd.into();
    } else {
        command
            .args
            .splice(boundary..boundary, ["--cd".into(), cwd.into()]);
    }
    Ok(())
}

fn session_locator_path(target_id: &str, session_id: &str) -> PathBuf {
    SessionBindingStore::platform_default()
        .session_locators_directory()
        .join(format!(
            "pi-{:x}.json",
            Sha256::digest(format!("{target_id}\0{session_id}"))
        ))
}

fn stored_session_file(target_id: &str, session_id: &str) -> Result<Option<String>, CodexError> {
    let bytes = match fs::read(session_locator_path(target_id, session_id)) {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(pi_error("persistence-failed", error.to_string())),
    };
    let value: Value = serde_json::from_slice(&bytes)
        .map_err(|error| pi_error("persistence-failed", error.to_string()))?;
    if value["runtimeTargetId"].as_str() != Some(target_id)
        || value["sessionId"].as_str() != Some(session_id)
    {
        return Err(pi_error(
            "identity-mismatch",
            "Pi session locator belongs to another runtime or chat.",
        ));
    }
    let file = value["sessionFile"]
        .as_str()
        .filter(|file| valid_session_file(file))
        .ok_or_else(|| pi_error("invalid-response", "Saved Pi session file is invalid."))?;
    Ok(Some(file.into()))
}

fn valid_session_file(file: &str) -> bool {
    !file.contains('\0') && (file.starts_with('/') || Path::new(file).is_absolute())
}

fn remember_session_file(target_id: &str, session_id: &str, file: &str) -> Result<(), CodexError> {
    if !valid_session_file(file) {
        return Err(pi_error(
            "invalid-response",
            "Pi did not return an absolute session file.",
        ));
    }
    let path = session_locator_path(target_id, session_id);
    let value = json!({"runtimeTargetId":target_id,"sessionId":session_id,"sessionFile":file});
    let bytes = serde_json::to_vec(&value).expect("session locator JSON");
    if fs::read(&path).ok().as_deref() == Some(bytes.as_slice()) {
        return Ok(());
    }
    let temporary = path.with_extension(format!("tmp-{}", Uuid::new_v4()));
    let save = || -> std::io::Result<()> {
        fs::create_dir_all(path.parent().expect("locator directory"))?;
        fs::write(&temporary, bytes)?;
        fs::rename(&temporary, &path)
    };
    let result = save().map_err(|error| pi_error("persistence-failed", error.to_string()));
    let _ = fs::remove_file(temporary);
    result
}

fn value_string(value: Option<&Value>) -> String {
    match value {
        Some(Value::String(value)) => value.clone(),
        Some(Value::Number(value)) => value.to_string(),
        Some(Value::Bool(value)) => value.to_string(),
        _ => String::new(),
    }
}

fn pi_error(code: impl Into<String>, message: impl Into<String>) -> CodexError {
    CodexError {
        code: code.into(),
        message: sanitize_diagnostic(message.into()),
        retryable: false,
    }
}

fn short_id(value: &str) -> &str {
    value.get(..8).unwrap_or(value)
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::{identify_user_entries, messages_to_turns, pi_image, pi_thinking_levels};

    #[test]
    fn fork_entries_distinguish_repeated_messages_and_refuse_ambiguous_branches() {
        let mut messages = vec![
            json!({"role":"user","content":"same"}),
            json!({"role":"user","content":"same"}),
        ];
        identify_user_entries(
            &mut messages,
            &[
                json!({"entryId":"a","text":"same"}),
                json!({"entryId":"b","text":"same"}),
            ],
        )
        .unwrap();
        assert_eq!(messages[0]["id"], "a");
        assert_eq!(messages[1]["id"], "b");
        assert!(
            identify_user_entries(
                &mut messages,
                &[
                    json!({"entryId":"a","text":"same"}),
                    json!({"entryId":"b","text":"same"}),
                    json!({"entryId":"c","text":"same"})
                ]
            )
            .is_err()
        );
    }

    #[test]
    fn maps_pi_history_and_reasoning_levels() {
        let turns = messages_to_turns(&[
            json!({"id": "u", "role": "user", "content": [{"type": "text", "text": "question"}]}),
            json!({"id": "a", "role": "assistant", "content": [
                {"type": "thinking", "text": "thought"}, {"type": "text", "text": "answer"}
            ]}),
        ]);
        assert_eq!(turns[0]["items"][2]["text"], "answer");
        assert_eq!(
            pi_thinking_levels(&json!({"reasoning": true, "thinkingLevelMap": {"xhigh": "xhigh"}})),
            ["off", "minimal", "low", "medium", "high", "xhigh"]
        );
    }

    #[test]
    fn validates_pi_images() {
        assert_eq!(
            pi_image("data:image/png;base64,aGVsbG8=").expect("image")["mimeType"],
            "image/png"
        );
    }
}
