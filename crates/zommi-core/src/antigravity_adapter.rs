//! Antigravity's documented headless NDJSON interface. Credentials, conversation
//! persistence and tool policy belong to `agy`; no interactive approval bypass
//! or private history format is used here.
use std::{
    collections::HashMap,
    path::{Path, PathBuf},
    process::Stdio,
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
};

use serde_json::{Value, json};
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    process::{ChildStdin, Command},
    sync::{Mutex, Notify},
    task::JoinHandle,
    time::{Duration, timeout},
};
use uuid::Uuid;

use crate::{
    RuntimeCommand, RuntimeTarget, build_context_handoff,
    codex_adapter::{CodexError, CoreEvent, EventSender, TurnReceipt},
    runtime_adapter::AdapterTurnRequest,
    runtime_discovery::ANTIGRAVITY_CAPABILITIES,
    sanitize_diagnostic, validate_turn_input,
};

const START_TIMEOUT: Duration = Duration::from_secs(30);

#[derive(Clone)]
pub struct AntigravityAdapter {
    inner: Arc<Inner>,
}

struct Inner {
    target: RuntimeTarget,
    command: RuntimeCommand,
    cwd: PathBuf,
    state: Mutex<State>,
    control: Mutex<()>,
    events: EventSender,
    sequence: AtomicU64,
}

#[derive(Default)]
struct State {
    stream: Option<Arc<Stream>>,
    models: Vec<Value>,
    sessions: HashMap<String, Value>,
    stopped: bool,
}

struct Stream {
    owner: Arc<Inner>,
    cwd: PathBuf,
    model: Option<String>,
    stdin: Mutex<ChildStdin>,
    state: Mutex<StreamState>,
    changed: Notify,
    stop: Notify,
    task: Mutex<Option<JoinHandle<()>>>,
}

#[derive(Default)]
struct StreamState {
    session_id: Option<String>,
    startup_error: Option<CodexError>,
    active: Option<ActiveTurn>,
    stderr: String,
    stopping: bool,
    exited: bool,
}

struct ActiveTurn {
    id: String,
    operation: String,
    text: String,
}

impl AntigravityAdapter {
    pub async fn connect(
        target: RuntimeTarget,
        command: RuntimeCommand,
        cwd: PathBuf,
        preferred: Option<String>,
        events: EventSender,
        prepare_only: bool,
    ) -> Result<Self, CodexError> {
        let adapter = Self {
            inner: Arc::new(Inner {
                target,
                command,
                cwd,
                state: Mutex::new(State::default()),
                control: Mutex::new(()),
                events,
                sequence: AtomicU64::new(0),
            }),
        };
        adapter.refresh_models().await?;
        if !prepare_only {
            adapter.activate(preferred.as_deref(), None, None).await?;
        }
        Ok(adapter)
    }

    pub fn target_id(&self) -> &str {
        &self.inner.target.id
    }

    pub async fn is_running(&self) -> bool {
        let state = self.inner.state.lock().await;
        if state.stopped {
            return false;
        }
        match &state.stream {
            Some(stream) => !stream.state.lock().await.exited,
            None => true,
        }
    }

    async fn stream(&self) -> Result<Arc<Stream>, CodexError> {
        self.inner.state.lock().await.stream.clone().ok_or_else(|| {
            error(
                "runtime-unavailable",
                "Antigravity has no active conversation.",
            )
        })
    }

    pub async fn active_session_id(&self) -> Result<String, CodexError> {
        self.stream().await?.session_id().await
    }

    pub async fn connection_value(&self) -> Result<Value, CodexError> {
        let stream = self.stream().await?;
        let id = stream.session_id().await?;
        let state = self.inner.state.lock().await;
        Ok(json!({
            "runtimeTargetId": self.target_id(), "sessionId": id,
            "capabilities": ANTIGRAVITY_CAPABILITIES,
            "models": state.models,
            "sessions": state.sessions.values().collect::<Vec<_>>(),
            "sessionMetadata": {"cwd": stream.cwd, "activeModel": stream.model},
            "historyAuthority": "none"
        }))
    }

    pub async fn refresh_models(&self) -> Result<Vec<Value>, CodexError> {
        let mut command = self.inner.launch(&self.inner.cwd)?;
        command.arg("models").stdin(Stdio::null());
        let output = timeout(START_TIMEOUT, command.output())
            .await
            .map_err(|_| {
                error(
                    "runtime-timeout",
                    "Antigravity model discovery timed out; retry Refresh agents.",
                )
            })?
            .map_err(|e| {
                error(
                    "runtime-unavailable",
                    format!("Could not start Antigravity: {e}"),
                )
            })?;
        if !output.status.success() {
            return Err(runtime_error(&String::from_utf8_lossy(&output.stderr)));
        }
        let models = parse_models(&String::from_utf8_lossy(&output.stdout));
        if models.is_empty() {
            return Err(error(
                "invalid-response",
                "Antigravity returned no recognizable models; update the CLI and retry Refresh agents.",
            ));
        }
        self.inner.state.lock().await.models = models.clone();
        Ok(models)
    }

    pub async fn activate(
        &self,
        id: Option<&str>,
        cwd: Option<&str>,
        model: Option<&str>,
    ) -> Result<(), CodexError> {
        let _control = self.inner.control.lock().await;
        self.replace(id, cwd, model).await
    }

    async fn replace(
        &self,
        id: Option<&str>,
        cwd: Option<&str>,
        model: Option<&str>,
    ) -> Result<(), CodexError> {
        if let Some(id) = id {
            Uuid::parse_str(id).map_err(|_| {
                error(
                    "invalid-request",
                    "Antigravity needs an exact conversation UUID.",
                )
            })?;
        }
        let (old, saved) = {
            let state = self.inner.state.lock().await;
            if state.stopped {
                return Err(error("runtime-exited", "Antigravity connection is closed."));
            }
            if let Some(model) = model
                && !state
                    .models
                    .iter()
                    .any(|entry| entry["id"].as_str() == Some(model))
            {
                return Err(error(
                    "invalid-request",
                    "The selected Antigravity model is unavailable; Refresh agents.",
                ));
            }
            (
                state.stream.clone(),
                id.and_then(|id| state.sessions.get(id)).cloned(),
            )
        };
        if let Some(old) = &old
            && old.state.lock().await.active.is_some()
        {
            return Err(error(
                "session-busy",
                "Finish or stop the active Antigravity turn first.",
            ));
        }
        let cwd = cwd
            .map(PathBuf::from)
            .or_else(|| {
                saved
                    .as_ref()
                    .and_then(|s| s["cwd"].as_str())
                    .map(PathBuf::from)
            })
            .unwrap_or_else(|| self.inner.cwd.clone());
        let model = model.map(str::to_owned).or_else(|| {
            saved
                .as_ref()
                .and_then(|s| s["model"].as_str())
                .map(str::to_owned)
        });
        let stream = Stream::start(self.inner.clone(), cwd, id, model).await?;
        let session_id = stream.session_id().await?;
        {
            let mut state = self.inner.state.lock().await;
            state.sessions.insert(session_id.clone(), json!({
                "id": session_id, "name": "Antigravity chat", "cwd": stream.cwd, "model": stream.model,
            }));
            state.stream = Some(stream);
        }
        if let Some(old) = old {
            old.shutdown(None).await;
        }
        Ok(())
    }

    pub async fn create_session(
        &self,
        model: Option<&str>,
        cwd: Option<&str>,
    ) -> Result<Value, CodexError> {
        self.activate(None, cwd, model).await?;
        self.connection_value().await
    }

    pub async fn open_session(&self, id: &str, cwd: Option<&str>) -> Result<Value, CodexError> {
        self.activate(Some(id), cwd, None).await?;
        self.connection_value().await
    }

    pub async fn configure_session(
        &self,
        id: &str,
        cwd: Option<&str>,
        model: Option<&str>,
    ) -> Result<Value, CodexError> {
        if self.active_session_id().await? != id {
            return Err(error(
                "identity-mismatch",
                "Antigravity configuration belongs to another chat.",
            ));
        }
        self.activate(Some(id), cwd, model).await?;
        self.connection_value().await
    }

    pub async fn start_turn(
        &self,
        request: AdapterTurnRequest<'_>,
    ) -> Result<TurnReceipt, CodexError> {
        let input = validate_turn_input(request.message, request.snapshots, request.images)?;
        if !input.images.is_empty() {
            return Err(error(
                "capability-unavailable",
                "Antigravity's streaming interface accepts text only. Remove image attachments or choose an image-capable agent.",
            ));
        }
        let _control = self.inner.control.lock().await;
        let mut stream = self.stream().await?;
        if stream.session_id().await? != request.session_id {
            return Err(error(
                "identity-mismatch",
                "The requested Antigravity conversation is not active.",
            ));
        }
        if stream.state.lock().await.exited
            || request
                .model
                .is_some_and(|m| stream.model.as_deref() != Some(m))
        {
            self.replace(
                Some(request.session_id),
                stream.cwd.to_str(),
                request.model.or(stream.model.as_deref()),
            )
            .await?;
            stream = self.stream().await?;
        }
        let id = Uuid::new_v4().to_string();
        let mut state = stream.state.lock().await;
        if state.active.is_some() {
            return Err(error(
                "session-busy",
                "Antigravity is already working on this chat.",
            ));
        }
        state.active = Some(ActiveTurn {
            id: id.clone(),
            operation: request.client_operation_id.into(),
            text: String::new(),
        });
        self.inner.emit(
            "turn.started",
            request.session_id,
            state.active.as_ref(),
            json!({"status":"inProgress"}),
        );
        drop(state);
        let message = json!({"event":"user", "message":{"content":build_context_handoff(&input.message, &input.snapshots, 0)}});
        let mut bytes = serde_json::to_vec(&message).expect("JSON value");
        bytes.push(b'\n');
        let sent = stream.stdin.lock().await.write_all(&bytes).await;
        if let Err(e) = sent {
            stream
                .finish("failed", Some(&format!("Antigravity input closed: {e}")))
                .await;
            stream.shutdown(None).await;
            return Err(error(
                "unknown-outcome",
                "Antigravity disconnected while sending; check the conversation before retrying.",
            ));
        }
        Ok(TurnReceipt {
            accepted: true,
            runtime_target_id: self.target_id().into(),
            session_id: request.session_id.into(),
            turn_id: id,
            client_operation_id: request.client_operation_id.into(),
        })
    }

    pub async fn interrupt_turn(&self, id: &str, turn: &str) -> Result<Value, CodexError> {
        let _control = self.inner.control.lock().await;
        let stream = self.stream().await?;
        let state = stream.state.lock().await;
        if state.session_id.as_deref() != Some(id)
            || state.active.as_ref().is_none_or(|active| active.id != turn)
        {
            return Err(error(
                "identity-mismatch",
                "That Antigravity turn is not active.",
            ));
        }
        drop(state);
        // The documented stream has no control-request protocol. Stop this
        // process; a later prompt resumes the same native conversation ID.
        stream.shutdown(Some("interrupted")).await;
        Ok(json!({"interrupted":true}))
    }

    pub async fn list_sessions(&self) -> Vec<Value> {
        self.inner
            .state
            .lock()
            .await
            .sessions
            .values()
            .cloned()
            .collect()
    }

    pub async fn shutdown(&self) {
        let _control = self.inner.control.lock().await;
        let stream = {
            let mut state = self.inner.state.lock().await;
            state.stopped = true;
            state.stream.take()
        };
        if let Some(stream) = stream {
            stream.shutdown(Some("interrupted")).await;
        }
    }
}

impl Inner {
    fn launch(&self, cwd: &Path) -> Result<Command, CodexError> {
        let mut launch = self.command.clone();
        if self.target.execution_host.kind == "wsl" {
            let cwd = cwd
                .to_str()
                .filter(|s| s.starts_with('/') && !s.contains('\0'))
                .ok_or_else(|| {
                    error(
                        "invalid-request",
                        "Antigravity needs an absolute WSL workspace path.",
                    )
                })?;
            let boundary = launch
                .args
                .iter()
                .position(|s| s == "--" || s == "-e")
                .ok_or_else(|| {
                    error(
                        "invalid-configuration",
                        "Antigravity WSL command has no execution boundary.",
                    )
                })?;
            if let Some(index) = launch.args[..boundary]
                .iter()
                .position(|s| s == "--cwd" || s == "--cd")
            {
                if index + 1 >= boundary {
                    return Err(error(
                        "invalid-configuration",
                        "Antigravity WSL command has no workspace.",
                    ));
                }
                launch.args[index + 1] = cwd.into();
            } else {
                launch
                    .args
                    .splice(boundary..boundary, ["--cd".into(), cwd.into()]);
            }
        }
        let mut command = Command::new(&launch.command);
        command
            .args(&launch.args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true);
        if self.target.execution_host.kind != "wsl" {
            command.current_dir(cwd);
        }
        Ok(command)
    }

    fn emit(&self, name: &str, session: &str, turn: Option<&ActiveTurn>, payload: Value) {
        let _ = self.events.send(CoreEvent {
            name: name.into(),
            sequence: self.sequence.fetch_add(1, Ordering::Relaxed) + 1,
            runtime_target_id: self.target.id.clone(),
            session_id: Some(session.into()),
            turn_id: turn.map(|t| t.id.clone()),
            client_operation_id: turn.map(|t| t.operation.clone()),
            payload,
        });
    }
}

impl Stream {
    async fn start(
        owner: Arc<Inner>,
        cwd: PathBuf,
        expected: Option<&str>,
        model: Option<String>,
    ) -> Result<Arc<Self>, CodexError> {
        let mut command = owner.launch(&cwd)?;
        command.args([
            "--input-format",
            "stream-json",
            "--output-format",
            "stream-json",
        ]);
        if let Some(id) = expected {
            command.args(["--conversation", id]);
        }
        if let Some(model) = &model {
            command.args(["--model", model]);
        }
        let mut child = command.spawn().map_err(|e| {
            error(
                "runtime-unavailable",
                format!("Could not start Antigravity: {e}"),
            )
        })?;
        let stdin = child.stdin.take().expect("piped stdin");
        let mut stdout = BufReader::new(child.stdout.take().expect("piped stdout")).lines();
        let mut stderr = BufReader::new(child.stderr.take().expect("piped stderr")).lines();
        let stream = Arc::new(Self {
            owner,
            cwd,
            model,
            stdin: Mutex::new(stdin),
            state: Mutex::new(StreamState::default()),
            changed: Notify::new(),
            stop: Notify::new(),
            task: Mutex::new(None),
        });
        let reader = stream.clone();
        *stream.task.lock().await = Some(tokio::spawn(async move {
            let mut out_open = true;
            let mut err_open = true;
            loop {
                tokio::select! {
                    _ = reader.stop.notified() => { let _ = child.kill().await; break; }
                    line = stdout.next_line(), if out_open => match line {
                        Ok(Some(line)) => match serde_json::from_str::<Value>(&line) {
                            Ok(value) => reader.message(value).await,
                            Err(_) => {
                                reader.state.lock().await.startup_error = Some(error("protocol-error", "Antigravity returned invalid streaming JSON."));
                                reader.finish("failed", Some("Antigravity returned invalid streaming JSON.")).await;
                                let _ = child.kill().await; break;
                            }
                        },
                        _ => out_open = false,
                    },
                    line = stderr.next_line(), if err_open => match line {
                        Ok(Some(line)) => {
                            let mut state = reader.state.lock().await;
                            state.stderr.push_str(&line); state.stderr.push('\n');
                            if state.stderr.len() > 8000 {
                                let mut cut = state.stderr.len() - 8000;
                                while !state.stderr.is_char_boundary(cut) { cut += 1; }
                                state.stderr.drain(..cut);
                            }
                        },
                        _ => err_open = false,
                    },
                    status = child.wait(), if !out_open && !err_open => {
                        let mut state = reader.state.lock().await;
                        if state.session_id.is_none() && state.startup_error.is_none() {
                            state.startup_error = Some(runtime_error(&format!("{}\nAntigravity exited: {status:?}", state.stderr)));
                        }
                        break;
                    }
                }
            }
            let mut state = reader.state.lock().await;
            state.exited = true;
            let stopping = state.stopping;
            let diagnostic = sanitize_diagnostic(&state.stderr);
            drop(state);
            if !stopping {
                reader
                    .finish(
                        "failed",
                        Some(&format!("Antigravity disconnected. {diagnostic}")),
                    )
                    .await;
                if let Ok(id) = reader.session_id().await {
                    reader.owner.emit("runtime.status", &id, None, json!({"status":"unavailable", "message":"Antigravity disconnected; reconnect to resume the conversation."}));
                }
            }
            reader.changed.notify_waiters();
        }));
        let ready = timeout(START_TIMEOUT, async {
            loop {
                let changed = stream.changed.notified();
                let state = stream.state.lock().await;
                if let Some(error) = &state.startup_error { return Err(error.clone()); }
                if let Some(id) = &state.session_id {
                    if expected.is_some_and(|expected| expected != id) { return Err(error("identity-mismatch", "Antigravity resumed a different conversation.")); }
                    return Ok(());
                }
                if state.exited { return Err(runtime_error(&state.stderr)); }
                drop(state); changed.await;
            }
        }).await.unwrap_or_else(|_| Err(error("runtime-timeout", "Antigravity did not initialize within 30 seconds. Run agy in the same host to finish sign-in, then retry.")));
        if let Err(error) = ready {
            stream.shutdown(None).await;
            return Err(error);
        }
        Ok(stream)
    }

    async fn session_id(&self) -> Result<String, CodexError> {
        self.state
            .lock()
            .await
            .session_id
            .clone()
            .ok_or_else(|| error("runtime-unavailable", "Antigravity has no conversation ID."))
    }

    async fn message(&self, value: Value) {
        let mut state = self.state.lock().await;
        match value["event"].as_str() {
            Some("init") => {
                if state.session_id.is_some() {
                    return;
                }
                if let Some(id) = value["conversation_id"]
                    .as_str()
                    .filter(|id| Uuid::parse_str(id).is_ok())
                {
                    state.session_id = Some(id.into());
                } else {
                    state.startup_error = Some(error(
                        "invalid-response",
                        "Antigravity omitted its conversation UUID.",
                    ));
                }
                self.changed.notify_waiters();
            }
            Some("step_update") => {
                let update = &value["step_update"];
                let Some(session) = state.session_id.clone() else {
                    return;
                };
                if update["conversation_id"]
                    .as_str()
                    .is_some_and(|id| id != session)
                {
                    return;
                }
                let Some(turn) = &mut state.active else {
                    return;
                };
                if update["step_type"] == "agent_response" {
                    let text = update["text_delta"].as_str().unwrap_or_default();
                    if !text.is_empty() {
                        turn.text.push_str(text);
                        self.owner.emit("item.update", &session, Some(turn), json!({"kind":"assistant", "lifecycle":"delta", "textMode":"append", "text":text, "itemId":format!("{}-response", turn.id)}));
                    }
                } else if update["step_type"] == "tool" {
                    self.owner.emit("item.update", &session, Some(turn), json!({
                        "kind":"tool", "lifecycle":if update["state"] == "DONE" {"completed"} else {"started"},
                        "title":update["tool_name"], "text":update["tool_info"].to_string(),
                        "itemId":format!("{}-step-{}", turn.id, update["step_index"])
                    }));
                }
            }
            Some("result") => {
                let result = &value["result"];
                if state.session_id.is_none() {
                    state.startup_error = Some(runtime_error(
                        result["error"]
                            .as_str()
                            .unwrap_or("Antigravity could not initialize."),
                    ));
                    self.changed.notify_waiters();
                    return;
                }
                let session = state.session_id.clone().unwrap();
                if result["conversation_id"]
                    .as_str()
                    .is_some_and(|id| !id.is_empty() && id != session)
                {
                    return;
                }
                if let Some(turn) = &mut state.active {
                    let response = result["response"].as_str().unwrap_or_default();
                    // Results repeat all streamed text. Emit only the missing
                    // suffix, or the complete response when no deltas arrived.
                    if let Some(suffix) = response.strip_prefix(&turn.text)
                        && !suffix.is_empty()
                    {
                        self.owner.emit("item.update", &session, Some(turn), json!({"kind":"assistant", "lifecycle":"delta", "textMode":"append", "text":suffix, "itemId":format!("{}-response", turn.id)}));
                    }
                }
                let status = match result["status"].as_str() {
                    Some("SUCCESS") => "completed",
                    Some("CANCELED" | "INTERRUPTED") => "interrupted",
                    _ => "failed",
                };
                let message = result["error"].as_str().map(str::to_owned);
                drop(state);
                self.finish(status, message.as_deref()).await;
            }
            _ => {}
        }
    }

    async fn finish(&self, status: &str, message: Option<&str>) {
        let mut state = self.state.lock().await;
        if let Some(turn) = state.active.take() {
            self.owner.emit(
                "turn.completed",
                state.session_id.as_deref().unwrap_or_default(),
                Some(&turn),
                json!({"status":status, "error":message.map(sanitize_diagnostic)}),
            );
        }
    }

    async fn shutdown(&self, terminal: Option<&str>) {
        self.state.lock().await.stopping = true;
        if let Some(status) = terminal {
            self.finish(status, None).await;
        }
        self.stop.notify_one();
        if let Some(task) = self.task.lock().await.take() {
            let _ = task.await;
        }
    }
}

fn error(code: &str, message: impl Into<String>) -> CodexError {
    CodexError {
        code: code.into(),
        message: sanitize_diagnostic(message.into()),
        retryable: matches!(code, "runtime-timeout" | "runtime-exited"),
    }
}

fn runtime_error(message: &str) -> CodexError {
    let lower = message.to_ascii_lowercase();
    if lower.contains("sign in") || lower.contains("authentication") || lower.contains("log in") {
        error(
            "authentication-required",
            format!(
                "Antigravity CLI sign-in required. Run agy on the same host, then retry or Refresh agents. {message}"
            ),
        )
    } else {
        error(
            "runtime-request-failed",
            format!("Antigravity CLI: {message}"),
        )
    }
}

fn parse_models(output: &str) -> Vec<Value> {
    let row = regex::Regex::new(r"^\s*([a-z0-9][a-z0-9._/-]*)(?:\t+| {2,})(\S.*)$")
        .expect("model row regex");
    output.lines().filter_map(|line| {
        let captures = row.captures(line)?;
        Some(json!({"id":&captures[1], "model":&captures[1], "displayName":captures[2].trim(), "supportedReasoningEfforts":[]}))
    }).collect()
}
