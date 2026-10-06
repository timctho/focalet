//! Claude Code's bidirectional stream-json protocol. The CLI owns authentication,
//! permissions and durable sessions; each conversation keeps its own process.
use crate::{
    RuntimeCommand, RuntimeTarget, build_context_handoff,
    codex_adapter::{CodexError, CoreEvent, EventSender, TurnReceipt},
    runtime_adapter::AdapterTurnRequest,
    sanitize_diagnostic,
    session_permissions::{SessionPermissionStore, permission_error},
    validate_turn_input,
};
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    path::{Path, PathBuf},
    process::Stdio,
    sync::{
        Arc, Weak,
        atomic::{AtomicBool, AtomicU64, Ordering},
    },
};
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    process::{ChildStdin, Command},
    sync::{Mutex, oneshot},
    task::AbortHandle,
    time::{Duration, timeout},
};
use uuid::Uuid;

pub(crate) const CAPABILITIES: &[&str] = &[
    "session.create.v1",
    "session.resume.v1",
    "turn.stream.v1",
    "turn.interrupt.v1",
    "input.image.v1",
    "approval.resolve.v1",
    "model.select.v1",
    "commands.list.v1",
    "commands.execute.v1",
];
const CONTROL_TIMEOUT: Duration = Duration::from_secs(30);

#[derive(Clone)]
pub struct ClaudeAdapter {
    inner: Arc<Inner>,
}
struct Inner {
    target: RuntimeTarget,
    command: RuntimeCommand,
    permissions: SessionPermissionStore,
    cwd: PathBuf,
    events: EventSender,
    sequence: AtomicU64,
    include_partial_messages: AtomicBool,
    state: Mutex<AdapterState>,
    selection: Mutex<()>,
}
#[derive(Default)]
struct AdapterState {
    active: Option<String>,
    prepared: Option<Arc<Stream>>,
    sessions: HashMap<String, Arc<Stream>>,
    models: Vec<Value>,
}
struct Stream {
    full_access: bool,
    events_enabled: AtomicBool,
    owner: Weak<Inner>,
    id: String,
    cwd: PathBuf,
    stdin: Mutex<ChildStdin>,
    state: Mutex<StreamState>,
    pending: Mutex<HashMap<String, oneshot::Sender<Result<Value, CodexError>>>>,
    tasks: Mutex<Vec<AbortHandle>>,
    operation: Mutex<()>,
}
#[derive(Default)]
struct StreamState {
    exited: bool,
    exit_error: Option<CodexError>,
    turn: Option<Turn>,
    approvals: HashMap<String, Value>,
    models: Vec<Value>,
    commands: Vec<Value>,
    model: Option<String>,
    stderr: String,
    message_id: String,
    blocks: HashMap<String, String>,
}
struct Turn {
    id: String,
    operation: String,
    interrupted: bool,
}

impl ClaudeAdapter {
    pub async fn connect(
        target: RuntimeTarget,
        command: RuntimeCommand,
        cwd: PathBuf,
        preferred: Option<String>,
        events: EventSender,
        prepare: bool,
    ) -> Result<Self, CodexError> {
        let adapter = Self {
            inner: Arc::new(Inner {
                permissions: SessionPermissionStore::for_target(&target.id),
                target,
                command,
                cwd,
                events,
                sequence: AtomicU64::new(0),
                include_partial_messages: AtomicBool::new(true),
                state: Mutex::new(AdapterState::default()),
                selection: Mutex::new(()),
            }),
        };
        if prepare {
            let stream = adapter
                .inner
                .spawn(None, None, adapter.inner.command.full_access)
                .await?;
            let models = stream.state.lock().await.models.clone();
            let mut state = adapter.inner.state.lock().await;
            state.models = models;
            state.prepared = Some(stream);
        } else {
            adapter
                .activate(
                    preferred.as_deref(),
                    None,
                    adapter.inner.command.full_access,
                )
                .await?;
        }
        Ok(adapter)
    }
    pub fn target_id(&self) -> &str {
        &self.inner.target.id
    }
    pub async fn is_running(&self) -> bool {
        let state = self.inner.state.lock().await;
        let streams: Vec<_> = state
            .sessions
            .values()
            .chain(state.prepared.iter())
            .cloned()
            .collect();
        drop(state);
        for stream in streams {
            if !stream.state.lock().await.exited {
                return true;
            }
        }
        false
    }
    pub async fn active_session_id(&self) -> Result<String, CodexError> {
        self.inner.state.lock().await.active.clone().ok_or_else(|| {
            error(
                "runtime-unavailable",
                "Claude has no selected conversation.",
            )
        })
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
        if let Some(id) = session {
            Uuid::parse_str(id).map_err(|_| error("invalid-request", "Claude needs an exact saved session UUID. Start a new chat for older terminal-only conversations."))?;
            let previous = self.inner.state.lock().await.sessions.get(id).cloned();
            if let Some(stream) = previous
                && !stream.state.lock().await.exited
            {
                self.inner.state.lock().await.active = Some(id.into());
                return Ok(());
            }
        }
        let prepared = if session.is_none() && cwd.is_none_or(|p| Path::new(p) == self.inner.cwd) {
            self.inner.state.lock().await.prepared.take()
        } else {
            None
        };
        let stream = match prepared {
            Some(stream)
                if stream.full_access == full_access && !stream.state.lock().await.exited =>
            {
                stream
            }
            previous => {
                if let Some(previous) = previous {
                    previous
                        .stop("runtime-stopped", "Runtime preparation settings changed.")
                        .await;
                }
                self.inner.spawn(session, cwd, full_access).await?
            }
        };
        if full_access && let Err(error) = self.inner.permissions.remember_full_access(&stream.id) {
            stream
                .stop("persistence-failed", "Could not save chat permissions.")
                .await;
            return Err(permission_error(error));
        }
        stream.events_enabled.store(true, Ordering::Release);
        let mut state = self.inner.state.lock().await;
        state.models = stream.state.lock().await.models.clone();
        state.active = Some(stream.id.clone());
        state.sessions.insert(stream.id.clone(), stream);
        Ok(())
    }
    pub async fn connection_value(&self) -> Result<Value, CodexError> {
        let active = self.inner.state.lock().await.active.clone();
        if let Some(id) = active {
            let stream = self.stream(&id).await?;
            if stream.state.lock().await.exited {
                self.activate(Some(&id), stream.cwd.to_str(), false).await?;
            }
        }
        let state = self.inner.state.lock().await;
        let stream = state
            .active
            .as_ref()
            .and_then(|id| state.sessions.get(id))
            .cloned();
        let mut value = json!({"runtimeTargetId": self.target_id(), "runtimeId":"claude", "adapterId":"claude-stream-json", "sessionId":state.active, "capabilities":CAPABILITIES, "models":state.models, "sessions":[], "sessionMetadata":{}});
        drop(state);
        if let Some(stream) = stream {
            value["sessionMetadata"] =
                json!({"cwd":stream.cwd, "activeModel":stream.state.lock().await.model});
        }
        Ok(value)
    }
    pub async fn create_session(
        &self,
        model: Option<&str>,
        cwd: Option<&str>,
        full_access: bool,
    ) -> Result<Value, CodexError> {
        let previous = self.inner.state.lock().await.active.clone();
        self.activate(None, cwd, full_access).await?;
        let stream = self.stream(&self.active_session_id().await?).await?;
        if let Err(error) = stream.set_model(model).await {
            let mut state = self.inner.state.lock().await;
            state.active = previous;
            state.sessions.remove(&stream.id);
            drop(state);
            stream.events_enabled.store(false, Ordering::Release);
            stream
                .stop("runtime-stopped", "New conversation was not selected.")
                .await;
            return Err(error);
        }
        self.connection_value().await
    }
    pub async fn open_session(&self, id: &str, cwd: Option<&str>) -> Result<Value, CodexError> {
        self.activate(Some(id), cwd, false).await?;
        self.connection_value().await
    }
    pub async fn list_sessions(&self) -> Vec<Value> {
        // No native saved-session enumeration is exposed by this wire protocol.
        self.inner
            .state
            .lock()
            .await
            .sessions
            .values()
            .map(|s| json!({"id":s.id,"name":"Claude chat","cwd":s.cwd}))
            .collect()
    }
    pub async fn refresh_models(&self) -> Result<Vec<Value>, CodexError> {
        let probe = self.inner.spawn(None, None, false).await?;
        let models = probe.state.lock().await.models.clone();
        probe
            .stop("runtime-stopped", "Model refresh finished.")
            .await;
        let sessions = {
            let mut state = self.inner.state.lock().await;
            state.models = models.clone();
            state
                .sessions
                .values()
                .cloned()
                .chain(state.prepared.iter().cloned())
                .collect::<Vec<_>>()
        };
        for session in sessions {
            session.state.lock().await.models = models.clone();
        }
        Ok(models)
    }
    pub async fn list_commands(&self, session: &str) -> Result<Vec<Value>, CodexError> {
        Ok(self
            .stream(session)
            .await?
            .state
            .lock()
            .await
            .commands
            .clone())
    }
    async fn stream(&self, id: &str) -> Result<Arc<Stream>, CodexError> {
        self.inner
            .state
            .lock()
            .await
            .sessions
            .get(id)
            .cloned()
            .ok_or_else(|| {
                error(
                    "identity-mismatch",
                    "The requested Claude conversation is not connected.",
                )
            })
    }
    pub async fn start_turn(
        &self,
        request: AdapterTurnRequest<'_>,
    ) -> Result<TurnReceipt, CodexError> {
        validate_turn_input(request.message, request.snapshots, request.images)
            .map_err(|e| error(&e.code, e.message))?;
        let stream = self.stream(request.session_id).await?;
        let _operation = stream.operation.lock().await;
        {
            let state = stream.state.lock().await;
            if state.exited {
                return Err(error(
                    "runtime-exited",
                    "Claude disconnected. Reconnect to resume the conversation.",
                ));
            }
            if state.turn.is_some() {
                return Err(error(
                    "runtime-busy",
                    "Claude is already working on this conversation.",
                ));
            }
        }
        stream.set_model(request.model).await?;
        let text = if request.slash_command {
            request.message.to_owned()
        } else {
            build_context_handoff(request.message, request.snapshots, request.images.len())
        };
        let mut content = vec![json!({"type":"text", "text":text})];
        for image in request.images {
            let (prefix, data) = image
                .split_once(",")
                .ok_or_else(|| error("invalid-request", "Invalid image data URL."))?;
            let media = prefix
                .trim_start_matches("data:")
                .trim_end_matches(";base64");
            if !["image/png", "image/jpeg", "image/gif", "image/webp"].contains(&media) {
                return Err(error(
                    "invalid-request",
                    "Claude supports PNG, JPEG, GIF and WebP images.",
                ));
            }
            content.push(
                json!({"type":"image","source":{"type":"base64","media_type":media,"data":data}}),
            );
        }
        let id = Uuid::new_v4().to_string();
        {
            let mut state = stream.state.lock().await;
            state.blocks.clear();
            state.message_id.clear();
            state.turn = Some(Turn {
                id: id.clone(),
                operation: request.client_operation_id.into(),
                interrupted: false,
            });
        }
        stream.emit(
            "turn.started",
            Some(&id),
            Some(request.client_operation_id),
            json!({}),
        );
        let message = json!({"type":"user", "session_id":stream.id, "parent_tool_use_id":null, "client_composed":!request.slash_command, "message":{"role":"user","content":content}});
        if let Err(e) = stream.write(&message).await {
            stream
                .stop(
                    "runtime-exited",
                    "Claude disconnected while sending. Check the conversation before retrying.",
                )
                .await;
            return Err(e);
        }
        let weak = Arc::downgrade(&stream);
        let expected = id.clone();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_secs(600)).await;
            if let Some(s) = weak.upgrade() {
                let active = s
                    .state
                    .lock()
                    .await
                    .turn
                    .as_ref()
                    .is_some_and(|t| t.id == expected);
                if active {
                    s.stop("runtime-timeout", "Claude did not finish within 10 minutes. Reconnect and inspect the saved conversation before retrying.").await;
                }
            }
        });
        Ok(TurnReceipt {
            accepted: true,
            runtime_target_id: self.target_id().into(),
            session_id: stream.id.clone(),
            turn_id: id,
            client_operation_id: request.client_operation_id.into(),
        })
    }
    pub async fn interrupt_turn(&self, session: &str, turn: &str) -> Result<Value, CodexError> {
        let stream = self.stream(session).await?;
        {
            let mut state = stream.state.lock().await;
            let active = state
                .turn
                .as_mut()
                .filter(|t| t.id == turn)
                .ok_or_else(|| error("identity-mismatch", "That Claude turn is not active."))?;
            active.interrupted = true;
        }
        stream.control(json!({"subtype":"interrupt"})).await?;
        let weak = Arc::downgrade(&stream);
        let expected = turn.to_owned();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_secs(10)).await;
            if let Some(s) = weak.upgrade() {
                let active = s
                    .state
                    .lock()
                    .await
                    .turn
                    .as_ref()
                    .is_some_and(|t| t.id == expected);
                if active {
                    s.stop("runtime-timeout", "Claude did not acknowledge turn completion after cancellation. Reconnect to inspect its state.").await;
                }
            }
        });
        Ok(json!({"interrupted":true,"sessionId":session,"turnId":turn}))
    }
    pub async fn resolve_approval(
        &self,
        session: &str,
        approval: &str,
        option: Option<&str>,
    ) -> Result<Value, CodexError> {
        if !matches!(option, Some("allow_once" | "reject_once") | None) {
            return Err(error("invalid-request", "Unknown Claude approval option."));
        }
        let stream = self.stream(session).await?;
        let request = stream
            .state
            .lock()
            .await
            .approvals
            .remove(approval)
            .ok_or_else(|| {
                error(
                    "identity-mismatch",
                    "That approval is expired or belongs to another conversation.",
                )
            })?;
        let result = if option == Some("allow_once") {
            json!({"behavior":"allow", "updatedInput":request["input"]})
        } else {
            json!({"behavior":"deny","message":"Denied by the user."})
        };
        stream.write(&json!({"type":"control_response","response":{"subtype":"success","request_id":approval,"response":result}})).await?;
        stream.emit(
            "approval.resolved",
            None,
            None,
            json!({"approvalId":approval,"reason":"answered"}),
        );
        Ok(json!({"resolved":true,"approvalId":approval}))
    }
    pub async fn shutdown(&self) {
        let mut state = self.inner.state.lock().await;
        let mut streams = state.sessions.drain().map(|(_, s)| s).collect::<Vec<_>>();
        streams.extend(state.prepared.take());
        state.active = None;
        drop(state);
        for stream in streams {
            stream
                .stop("runtime-stopped", "Claude connection closed.")
                .await;
        }
    }
}

impl Inner {
    async fn spawn(
        self: &Arc<Self>,
        resume: Option<&str>,
        cwd: Option<&str>,
        full_access: bool,
    ) -> Result<Arc<Stream>, CodexError> {
        let result = self.spawn_once(resume, cwd, full_access).await;
        if let Err(failure) = &result
            && self
                .command
                .args
                .iter()
                .any(|arg| arg == "--include-partial-messages")
            && failure.message.lines().any(|line| {
                line.contains("unknown option") && line.contains("--include-partial-messages")
            })
        {
            // The CLI rejected its arguments before accepting a session or
            // prompt. Only this optional streaming flag may be removed; the
            // permission/control flags and any exact resume identity stay intact.
            self.include_partial_messages
                .store(false, Ordering::Release);
            if resume.is_some() {
                // Legacy CLIs such as 1.0.107 fork the UUID on --resume.
                // Argument rejection happened before touching the saved chat.
                return Err(error(
                    "runtime-update-required",
                    "Update Claude Code with `claude update` in the same runtime before reopening this chat. This older CLI cannot safely preserve the saved conversation ID. Your saved chat has not been changed.",
                ));
            }
            return self.spawn_once(resume, cwd, full_access).await;
        }
        result
    }

    async fn spawn_once(
        self: &Arc<Self>,
        resume: Option<&str>,
        cwd: Option<&str>,
        full_access: bool,
    ) -> Result<Arc<Stream>, CodexError> {
        let cwd = cwd.map(PathBuf::from).unwrap_or_else(|| self.cwd.clone());
        let id = resume
            .map(str::to_owned)
            .unwrap_or_else(|| Uuid::new_v4().to_string());
        let mut launch = self.command.clone();
        // A resume always rechecks the optional flag so updating the CLI lets
        // the same adapter recover without restarting other conversations.
        if resume.is_none() && !self.include_partial_messages.load(Ordering::Acquire) {
            launch
                .args
                .retain(|arg| arg != "--include-partial-messages");
        }
        launch.full_access = full_access;
        if full_access {
            launch.enable_full_access(&self.target).map_err(|error| {
                crate::claude_adapter::error("invalid-configuration", error.to_string())
            })?;
        }
        if self.target.execution_host.kind == "wsl" {
            if !cwd.to_string_lossy().starts_with('/') {
                return Err(error(
                    "invalid-request",
                    "Claude needs an absolute WSL workspace path.",
                ));
            }
            let boundary = launch
                .args
                .iter()
                .position(|a| a == "--" || a == "-e")
                .ok_or_else(|| {
                    error(
                        "invalid-configuration",
                        "WSL command has no execution boundary.",
                    )
                })?;
            if let Some(i) = launch.args[..boundary]
                .iter()
                .position(|a| a == "--cd" || a == "--cwd")
            {
                if i + 1 >= boundary {
                    return Err(error(
                        "invalid-configuration",
                        "WSL command has no workspace.",
                    ));
                }
                launch.args[i + 1] = cwd.to_string_lossy().into_owned();
            } else {
                launch.args.splice(
                    boundary..boundary,
                    ["--cd".into(), cwd.to_string_lossy().into_owned()],
                );
            }
        }
        let mut command = Command::new(&launch.command);
        self.target.apply_launch_environment(&mut command);
        command.args(&launch.args).args([
            if resume.is_some() {
                "--resume"
            } else {
                "--session-id"
            },
            &id,
        ]);
        command
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true);
        if self.target.execution_host.kind != "wsl" {
            command.current_dir(&cwd);
        }
        let mut child = command.spawn().map_err(|e| {
            error(
                "runtime-unavailable",
                format!("Could not start Claude Code: {e}"),
            )
        })?;
        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| error("runtime-unavailable", "Claude has no stdin."))?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| error("runtime-unavailable", "Claude has no stdout."))?;
        let stderr = child
            .stderr
            .take()
            .ok_or_else(|| error("runtime-unavailable", "Claude has no stderr."))?;
        let stream = Arc::new(Stream {
            full_access,
            events_enabled: AtomicBool::new(false),
            owner: Arc::downgrade(self),
            id,
            cwd,
            stdin: Mutex::new(stdin),
            state: Mutex::new(StreamState::default()),
            pending: Mutex::new(HashMap::new()),
            tasks: Mutex::new(Vec::new()),
            operation: Mutex::new(()),
        });
        let (stderr_finished, mut stderr_done) = oneshot::channel::<()>();
        let weak = Arc::downgrade(&stream);
        let stdout_task = tokio::spawn(async move {
            let mut lines = BufReader::new(stdout).lines();
            loop {
                match lines.next_line().await {
                    Ok(Some(line)) => {
                        let Some(s) = weak.upgrade() else {
                            break;
                        };
                        if line.trim().is_empty() {
                            continue;
                        }
                        match serde_json::from_str(&line) {
                            Ok(value) => s.receive(value).await,
                            Err(_) => {
                                s.fail("protocol-error", "Claude emitted invalid stream-json.")
                                    .await;
                                break;
                            }
                        }
                    }
                    _ => {
                        // stderr can arrive after stdout closes. Bound the
                        // drain so a child that keeps a pipe open cannot leave
                        // an active conversation waiting indefinitely.
                        let _ = timeout(Duration::from_millis(500), &mut stderr_done).await;
                        if let Some(s) = weak.upgrade() {
                            let message = if s.events_enabled.load(Ordering::Acquire) {
                                "Claude output closed. Reconnect to resume."
                            } else {
                                "Claude Code output closed during startup."
                            };
                            s.fail("runtime-exited", message).await;
                        }
                        break;
                    }
                }
            }
        });
        let weak = Arc::downgrade(&stream);
        let stderr_task = tokio::spawn(async move {
            let mut lines = BufReader::new(stderr).lines();
            while let Ok(Some(line)) = lines.next_line().await {
                let Some(s) = weak.upgrade() else {
                    break;
                };
                let mut state = s.state.lock().await;
                state.stderr = sanitize_diagnostic(format!("{}\n{line}", state.stderr));
            }
            let _ = stderr_finished.send(());
        });
        let stdout_abort = stdout_task.abort_handle();
        let stderr_abort = stderr_task.abort_handle();
        let weak = Arc::downgrade(&stream);
        let wait_task = tokio::spawn(async move {
            let status = child.wait().await;
            let _ = stdout_task.await;
            let _ = stderr_task.await;
            if let Some(s) = weak.upgrade() {
                let code = status
                    .map(|status| status.to_string())
                    .unwrap_or_else(|error| error.to_string());
                let message = if s.events_enabled.load(Ordering::Acquire) {
                    format!("Claude exited ({code}). Reconnect to resume.")
                } else {
                    format!("Claude Code exited during startup ({code}).")
                };
                s.fail("runtime-exited", &message).await;
            }
        });
        stream
            .tasks
            .lock()
            .await
            .extend([stdout_abort, stderr_abort, wait_task.abort_handle()]);
        let info = match stream.control(json!({"subtype":"initialize"})).await {
            Ok(info) => info,
            Err(e) => {
                stream.stop(&e.code, &e.message).await;
                return Err(
                    if e.message
                        .lines()
                        .any(|line| line.contains("unknown option"))
                    {
                        error(
                            "runtime-update-required",
                            format!(
                                "This Claude Code CLI does not support a required launch option. Run `claude update` in the same runtime, then retry. {}",
                                e.message
                            ),
                        )
                    } else {
                        e
                    },
                );
            }
        };
        let mut state = stream.state.lock().await;
        state.models = info["models"].as_array().into_iter().flatten().filter_map(|m| {
            let id = m["value"].as_str()?;
            Some(json!({"id":id,"model":id,"displayName":m["displayName"].as_str().unwrap_or(id),"description":m["description"],"supportedReasoningEfforts":[]}))
        }).collect();
        let commands = info["commands"].as_array().cloned().unwrap_or_default();
        state.commands = crate::command_catalog::with_client_limits(
            crate::command_catalog::normalize(&commands),
        );
        for c in &mut state.commands {
            if matches!(
                c["name"].as_str(),
                Some(
                    "clear"
                        | "reset"
                        | "new"
                        | "resume"
                        | "fork"
                        | "exit"
                        | "quit"
                        | "login"
                        | "logout"
                        | "permissions"
                        | "config"
                )
            ) {
                c["disabledReason"] = json!(
                    "Use Focalet's session controls or configure Claude in its own terminal."
                );
            }
        }
        drop(state);
        Ok(stream)
    }
}

impl Stream {
    async fn write(&self, value: &Value) -> Result<(), CodexError> {
        let mut bytes = serde_json::to_vec(value).map_err(|e| error("protocol-error", e))?;
        bytes.push(b'\n');
        let mut stdin = self.stdin.lock().await;
        timeout(CONTROL_TIMEOUT, async {
            stdin.write_all(&bytes).await?;
            stdin.flush().await
        })
        .await
        .map_err(|_| error("runtime-timeout", "Claude input timed out."))?
        .map_err(|e| error("runtime-exited", format!("Claude input closed: {e}")))
    }
    async fn control(&self, request: Value) -> Result<Value, CodexError> {
        let id = Uuid::new_v4().to_string();
        let (tx, rx) = oneshot::channel();
        {
            // Register under the same lock that marks an exit, so a fast argv
            // rejection cannot lose the pending initialize or its diagnostic.
            let state = self.state.lock().await;
            if state.exited {
                return Err(state
                    .exit_error
                    .clone()
                    .unwrap_or_else(|| error("runtime-exited", "Claude is disconnected.")));
            }
            self.pending.lock().await.insert(id.clone(), tx);
        }
        let result = match self
            .write(&json!({"type":"control_request","request_id":id,"request":request}))
            .await
        {
            Err(e) if e.code == "runtime-exited" => {
                // A CLI can reject argv before the first write. Prefer the
                // bounded stderr-backed exit diagnostic over a broken pipe.
                match timeout(Duration::from_secs(1), rx).await {
                    Ok(Ok(Err(failure))) => Err(failure),
                    _ => Err(e),
                }
            }
            Err(e) => Err(e),
            Ok(()) => match timeout(CONTROL_TIMEOUT, rx).await {
                Ok(Ok(value)) => value,
                _ => Err(error(
                    "runtime-timeout",
                    "Claude control request timed out. Run claude in this host to finish setup, then reconnect.",
                )),
            },
        };
        self.pending.lock().await.remove(&id);
        if result
            .as_ref()
            .is_err_and(|e| matches!(e.code.as_str(), "runtime-timeout" | "runtime-exited"))
        {
            self.stop(
                "runtime-timeout",
                "Claude control connection failed. Reconnect before retrying.",
            )
            .await;
        }
        result
    }
    async fn set_model(&self, model: Option<&str>) -> Result<(), CodexError> {
        let Some(model) = model.filter(|m| !m.is_empty()) else {
            return Ok(());
        };
        let state = self.state.lock().await;
        if state.model.as_deref() == Some(model) {
            return Ok(());
        }
        if !state.models.iter().any(|m| m["id"] == model) {
            return Err(error(
                "invalid-request",
                "Claude no longer advertises that model. Refresh agents.",
            ));
        }
        drop(state);
        self.control(json!({"subtype":"set_model","model":model}))
            .await?;
        self.state.lock().await.model = Some(model.into());
        Ok(())
    }
    async fn receive(self: &Arc<Self>, value: Value) {
        if value["type"] == "control_response" {
            let response = &value["response"];
            if let Some(id) = response["request_id"].as_str()
                && let Some(tx) = self.pending.lock().await.remove(id)
            {
                let result = if response["subtype"] == "error" {
                    Err(runtime_error(
                        response["error"]
                            .as_str()
                            .unwrap_or("Claude control request failed."),
                    ))
                } else {
                    Ok(response["response"].clone())
                };
                let _ = tx.send(result);
            }
            return;
        }
        if self.state.lock().await.exited {
            return;
        }
        if let Some(id) = value["session_id"].as_str()
            && id != self.id
        {
            self.fail("identity-mismatch", "Claude returned a different conversation ID. Reconnect to the correct saved conversation.").await;
            return;
        }
        if value["type"] == "control_cancel_request" {
            if let Some(id) = value["request_id"].as_str() {
                self.state.lock().await.approvals.remove(id);
                self.emit(
                    "approval.resolved",
                    None,
                    None,
                    json!({"approvalId":id,"reason":"cancelled"}),
                );
            }
            return;
        }
        if value["type"] == "control_request" {
            let Some(id) = value["request_id"].as_str().map(str::to_owned) else {
                return;
            };
            let request = &value["request"];
            if request["subtype"] != "can_use_tool" || self.state.lock().await.turn.is_none() {
                let _ = self.write(&json!({"type":"control_response","response":{"subtype":"error","request_id":id,"error":"Unsupported or inactive Claude control request."}})).await;
                return;
            }
            self.state
                .lock()
                .await
                .approvals
                .insert(id.clone(), request.clone());
            let turn_id = self
                .state
                .lock()
                .await
                .turn
                .as_ref()
                .map(|turn| turn.id.clone());
            self.emit("approval.requested", turn_id.as_deref(), None, json!({"approvalId":id,"toolCall":{"title":request["tool_name"],"rawInput":request["input"]},"options":[{"optionId":"allow_once","kind":"allow_once","name":"Allow once"},{"optionId":"reject_once","kind":"reject_once","name":"Deny"}]}));
            let weak = Arc::downgrade(self);
            tokio::spawn(async move {
                tokio::time::sleep(Duration::from_secs(300)).await;
                if let Some(s) = weak.upgrade()
                    && s.state.lock().await.approvals.remove(&id).is_some()
                {
                    let _ = s.write(&json!({"type":"control_response","response":{"subtype":"success","request_id":id,"response":{"behavior":"deny","message":"Approval expired."}}})).await;
                    s.emit(
                        "approval.resolved",
                        None,
                        None,
                        json!({"approvalId":id,"reason":"expired"}),
                    );
                }
            });
            return;
        }
        if value["type"] == "system" && value["subtype"] == "init" {
            self.state.lock().await.model = value["model"].as_str().map(str::to_owned);
            return;
        }
        // Subagent messages have their own block indexes and must not overwrite
        // the top-level assistant response.
        if !value["parent_tool_use_id"].is_null() {
            return;
        }
        if value["type"] == "result" {
            let failed = value["is_error"] == true || value["subtype"] != "success";
            let diagnostic = value["errors"].as_array().map(|a| {
                a.iter()
                    .filter_map(Value::as_str)
                    .collect::<Vec<_>>()
                    .join("\n")
            });
            if !failed && let Some(text) = value["result"].as_str() {
                let empty = self.state.lock().await.blocks.is_empty();
                if empty {
                    self.block("result", "assistant", text, false).await;
                }
            }
            self.finish(
                if failed { "failed" } else { "completed" },
                diagnostic.as_deref(),
            )
            .await;
            return;
        }
        if value["type"] == "stream_event" {
            let e = &value["event"];
            if e["type"] == "message_start" {
                self.state.lock().await.message_id =
                    e["message"]["id"].as_str().unwrap_or("message").into();
            }
            let id = format!("{}:{}", self.state.lock().await.message_id, e["index"]);
            if e["type"] == "content_block_delta" {
                if let Some(text) = e["delta"]["text"].as_str() {
                    self.block(&id, "assistant", text, true).await;
                }
                if let Some(text) = e["delta"]["thinking"].as_str() {
                    self.block(&id, "reasoning", text, true).await;
                }
            }
        } else if value["type"] == "assistant" {
            let message = &value["message"];
            for (i, b) in message["content"]
                .as_array()
                .into_iter()
                .flatten()
                .enumerate()
            {
                let id = format!("{}:{i}", message["id"].as_str().unwrap_or("message"));
                match b["type"].as_str() {
                    Some("text") => {
                        self.block(&id, "assistant", b["text"].as_str().unwrap_or(""), false)
                            .await
                    }
                    Some("thinking") => {
                        self.block(
                            &id,
                            "reasoning",
                            b["thinking"].as_str().unwrap_or(""),
                            false,
                        )
                        .await
                    }
                    Some("tool_use") => {
                        self.block(&id, "tool", b["name"].as_str().unwrap_or("Tool"), false)
                            .await
                    }
                    _ => (),
                }
            }
        }
    }
    async fn block(&self, id: &str, kind: &str, text: &str, delta: bool) {
        let mut state = self.state.lock().await;
        let Some(turn) = state.turn.as_ref() else {
            return;
        };
        let (turn_id, operation) = (turn.id.clone(), turn.operation.clone());
        let entry = state.blocks.entry(id.into()).or_default();
        if delta {
            entry.push_str(text);
        } else {
            *entry = text.into();
        }
        let payload = json!({"itemId":format!("{turn_id}:{id}"),"kind":kind,"lifecycle":"updated","title":"Claude Code","text":entry});
        drop(state);
        self.emit("item.update", Some(&turn_id), Some(&operation), payload);
    }
    async fn finish(&self, status: &str, message: Option<&str>) {
        let mut state = self.state.lock().await;
        state.approvals.clear();
        let Some(turn) = state.turn.take() else {
            return;
        };
        let status = if turn.interrupted && status != "unknown" {
            "interrupted"
        } else {
            status
        };
        self.emit(
            "turn.completed",
            Some(&turn.id),
            Some(&turn.operation),
            json!({"status":status,"error":message.map(sanitize_diagnostic)}),
        );
    }
    async fn fail(&self, code: &str, message: &str) {
        let mut state = self.state.lock().await;
        if state.exited {
            return;
        }
        state.exited = true;
        let diagnostic = sanitize_diagnostic(format!("{message}\n{}", state.stderr));
        let failure = error(code, &diagnostic);
        state.exit_error = Some(failure.clone());
        drop(state);
        for (_, tx) in std::mem::take(&mut *self.pending.lock().await) {
            let _ = tx.send(Err(failure.clone()));
        }
        self.finish("unknown", Some(&diagnostic)).await;
        self.emit(
            "runtime.status",
            None,
            None,
            json!({"status":"unavailable","message":diagnostic}),
        );
    }
    async fn stop(&self, code: &str, message: &str) {
        self.fail(code, message).await;
        for task in self.tasks.lock().await.drain(..) {
            task.abort();
        }
        let _ = self.stdin.lock().await.shutdown().await;
    }
    fn emit(&self, name: &str, turn: Option<&str>, operation: Option<&str>, payload: Value) {
        if !self.events_enabled.load(Ordering::Acquire) {
            return;
        }
        if let Some(owner) = self.owner.upgrade() {
            let _ = owner.events.send(CoreEvent {
                name: name.into(),
                sequence: owner.sequence.fetch_add(1, Ordering::Relaxed) + 1,
                runtime_target_id: owner.target.id.clone(),
                session_id: Some(self.id.clone()),
                turn_id: turn.map(str::to_owned),
                client_operation_id: operation.map(str::to_owned),
                payload,
            });
        }
    }
}
fn error(code: &str, message: impl std::fmt::Display) -> CodexError {
    CodexError {
        code: code.into(),
        message: sanitize_diagnostic(message),
        retryable: matches!(
            code,
            "runtime-unavailable"
                | "runtime-timeout"
                | "runtime-exited"
                | "authentication-required"
        ),
    }
}
fn runtime_error(message: &str) -> CodexError {
    let lower = message.to_lowercase();
    if ["authentication", "api key", "not logged in", "login"]
        .iter()
        .any(|s| lower.contains(s))
    {
        error(
            "authentication-required",
            format!("Claude Code sign-in required. Run claude in this host, then retry. {message}"),
        )
    } else {
        error("runtime-error", message)
    }
}

impl Drop for Stream {
    fn drop(&mut self) {
        for task in self.tasks.get_mut().drain(..) {
            task.abort();
        }
    }
}
