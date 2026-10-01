use std::{
    collections::{HashMap, HashSet},
    path::PathBuf,
    process::Stdio,
    sync::{
        Arc, Weak,
        atomic::{AtomicU64, Ordering},
    },
};

use base64::Engine as _;
use futures_util::{SinkExt, StreamExt, stream::SplitSink};
use serde_json::{Value, json};
use tokio::{
    io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader, Lines},
    net::TcpStream,
    process::{ChildStdout, Command},
    sync::{Mutex, Notify, oneshot},
    task::JoinHandle,
    time::{Duration, Instant, timeout},
};
use tokio_tungstenite::{MaybeTlsStream, WebSocketStream, connect_async, tungstenite::Message};
use uuid::Uuid;

use crate::{
    RuntimeCommand, RuntimeTarget, build_context_handoff,
    codex_adapter::{CodexError, CoreEvent, EventSender, TurnReceipt},
    sanitize_diagnostic,
    session_permissions::{SessionPermissionStore, permission_error},
    validate_turn_input,
};

const REQUEST_TIMEOUT: Duration = Duration::from_secs(30);
const STARTUP_TIMEOUT: Duration = Duration::from_secs(45);
const MAX_FRAME_BYTES: usize = 16 * 1024 * 1024;

type GatewaySocket = WebSocketStream<MaybeTlsStream<TcpStream>>;
type GatewayWriter = SplitSink<GatewaySocket, Message>;

#[derive(Debug, Clone)]
pub struct HermesGatewayConfig {
    pub target: RuntimeTarget,
    pub command: RuntimeCommand,
    pub cwd: PathBuf,
    pub preferred_session_id: Option<String>,
    pub list_only: bool,
}

pub struct HermesGatewayTurnRequest<'a> {
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
pub struct HermesGatewayAdapter {
    inner: Arc<Inner>,
}

struct Inner {
    permissions: SessionPermissionStore,
    target: RuntimeTarget,
    port: u16,
    session_token: String,
    writer: Mutex<GatewayWriter>,
    pending: Mutex<HashMap<String, PendingRequest>>,
    state: Mutex<State>,
    stderr: Arc<Mutex<String>>,
    ready: Notify,
    next_request_id: AtomicU64,
    next_event_sequence: AtomicU64,
    event_tx: EventSender,
    wait_task: Mutex<Option<JoinHandle<()>>>,
    stdout_task: Mutex<Option<JoinHandle<()>>>,
    stderr_task: Mutex<Option<JoinHandle<()>>>,
    socket_task: Mutex<Option<JoinHandle<()>>>,
}

struct PendingRequest {
    method: String,
    requested_session_id: Option<String>,
    completion: oneshot::Sender<Result<Value, CodexError>>,
}

impl PendingRequest {
    async fn complete(self, result: Result<Value, CodexError>, state: &Mutex<State>) {
        // Bind on the socket reader before it can process the next event. A
        // woken request caller may otherwise run after an immediate stream frame.
        let result = match result {
            Ok(value) if self.method == "session.create" || self.method == "session.resume" => {
                let session_id = if self.method == "session.create" {
                    value_string(
                        value
                            .get("stored_session_id")
                            .or_else(|| value.get("session_key")),
                    )
                } else {
                    value
                        .get("session_key")
                        .or_else(|| value.get("resumed"))
                        .and_then(Value::as_str)
                        .or(self.requested_session_id.as_deref())
                        .unwrap_or_default()
                        .to_owned()
                };
                let binding = state.lock().await.bind_session(&value, &session_id);
                binding.map(|()| value)
            }
            result => result,
        };
        let _ = self.completion.send(result);
    }
}

#[derive(Default)]
struct State {
    command_catalogs: HashMap<String, Vec<Value>>,
    protocol_version: u64,
    runtime_version: Option<String>,
    capabilities: Vec<String>,
    gateway_ready: bool,
    active_session_id: Option<String>,
    runtime_session_id: Option<String>,
    runtime_session_ids: HashMap<String, String>,
    sessions: Vec<Value>,
    profiles: Vec<Value>,
    active_profile: String,
    histories: HashMap<String, Vec<Value>>,
    models: Vec<Value>,
    model_catalogs: HashMap<String, (Instant, Vec<Value>)>,
    session_info: Value,
    active_turns: HashMap<String, String>,
    turn_operations: HashMap<String, String>,
    streamed_assistant: HashMap<String, StreamedTurn>,
    terminal_turns: HashSet<String>,
    approvals: HashMap<String, PendingApproval>,
    questions: HashMap<String, PendingQuestion>,
    stopping: bool,
    exited: bool,
}

impl State {
    fn set_models(&mut self, models: Vec<Value>) {
        self.capabilities.retain(|capability| {
            capability != "model.select.v1" && capability != "reasoning.select.v1"
        });
        if !models.is_empty() {
            self.capabilities
                .extend(["model.select.v1".into(), "reasoning.select.v1".into()]);
        }
        self.models = models;
    }

    fn bind_session(&mut self, result: &Value, session_id: &str) -> Result<(), CodexError> {
        let runtime_session_id = result
            .get("session_id")
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
            .ok_or_else(|| {
                gateway_error(
                    "invalid-response",
                    "Hermes Gateway returned an invalid runtime session binding.",
                )
            })?;
        if session_id.is_empty() {
            return Err(gateway_error(
                "invalid-response",
                "Hermes Gateway returned an invalid stored session binding.",
            ));
        }
        self.active_session_id = Some(session_id.into());
        self.runtime_session_id = Some(runtime_session_id.into());
        self.runtime_session_ids
            .insert(runtime_session_id.into(), session_id.into());
        // A resume snapshot can lag events already received by this adapter.
        // Keep the local timeline and turn identity while its stream is live.
        if !self.streamed_assistant.contains_key(session_id) {
            self.histories.insert(
                session_id.into(),
                messages_to_turns(
                    &result
                        .get("messages")
                        .and_then(Value::as_array)
                        .cloned()
                        .unwrap_or_default(),
                ),
            );
        }
        self.session_info = result.get("info").cloned().unwrap_or_else(|| json!({}));
        if result.get("running").and_then(Value::as_bool) == Some(true) {
            self.active_turns
                .entry(session_id.into())
                .or_insert_with(|| format!("gateway-inflight-{session_id}"));
        }
        Ok(())
    }
}

#[derive(Default)]
struct StreamedTurn {
    assistant_segment: u64,
    assistant_text: String,
    reasoning_segment: u64,
    reasoning_id: Option<String>,
    reasoning_text: String,
    reasoning_open: bool,
}

impl StreamedTurn {
    fn assistant_id(&self, turn_id: &str) -> String {
        format!("{turn_id}-assistant-{}", self.assistant_segment)
    }

    fn seal_assistant(&mut self) {
        self.assistant_segment += 1;
        self.assistant_text.clear();
        self.reasoning_id = None;
        self.reasoning_text.clear();
        self.reasoning_open = false;
    }
}

#[derive(Clone)]
struct PendingApproval {
    session_id: String,
    request_id: String,
    choices: Vec<String>,
}

#[derive(Clone)]
struct PendingQuestion {
    session_id: String,
    request_id: String,
    kind: String,
}

impl HermesGatewayAdapter {
    pub async fn connect(
        config: HermesGatewayConfig,
        event_tx: EventSender,
    ) -> Result<Self, CodexError> {
        let session_token = Uuid::new_v4().to_string();
        let mut command = Command::new(&config.command.command);
        config.target.apply_launch_environment(&mut command);
        let is_wsl = config.target.execution_host.kind == "wsl";
        let arguments = hermes_gateway_arguments(&config.command.args, is_wsl, &session_token)?;
        if !is_wsl {
            command.env("HERMES_DASHBOARD_SESSION_TOKEN", &session_token);
        }
        command
            .args(&arguments)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true);
        if config.target.execution_host.kind != "wsl" && config.cwd.is_dir() {
            command.current_dir(&config.cwd);
        }
        let mut child = command.spawn().map_err(|error| {
            gateway_error(
                "runtime-unavailable",
                format!("Could not start Hermes Gateway: {error}"),
            )
        })?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| gateway_error("runtime-unavailable", "Hermes Gateway has no stdout."))?;
        let stderr = child
            .stderr
            .take()
            .ok_or_else(|| gateway_error("runtime-unavailable", "Hermes Gateway has no stderr."))?;
        let stderr_buffer = Arc::new(Mutex::new(String::new()));
        let stderr_task = tokio::spawn(read_stderr(Arc::clone(&stderr_buffer), stderr));
        let mut stdout_lines = BufReader::new(stdout).lines();
        let port = timeout(STARTUP_TIMEOUT, wait_for_ready_port(&mut stdout_lines))
            .await
            .map_err(|_| {
                gateway_error(
                    "runtime-unavailable",
                    "Hermes Gateway did not announce readiness within 45 seconds.",
                )
            })??;
        let health = read_health(port).await?;
        if health.get("ok").and_then(Value::as_bool) != Some(true) {
            return Err(gateway_error(
                "runtime-unavailable",
                "Hermes Gateway health check did not report ready.",
            ));
        }
        if health.get("auth_required").and_then(Value::as_bool) == Some(true) {
            return Err(gateway_error(
                "authentication-required",
                "Hermes Gateway unexpectedly required public-bind authentication.",
            ));
        }
        let profile_payload = read_http_json(port, "/api/profiles", Some(&session_token))
            .await
            .unwrap_or_else(|_| json!({"profiles": [{"name": "default", "is_default": true}]}));
        let profiles = profile_payload
            .get("profiles")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_else(|| vec![json!({"name": "default", "is_default": true})]);
        let active_profile = read_http_json(port, "/api/profiles/active", Some(&session_token))
            .await
            .ok()
            .and_then(|value| {
                value
                    .get("current")
                    .and_then(Value::as_str)
                    .map(str::to_owned)
            })
            .unwrap_or_else(|| "default".into());
        let endpoint = format!("ws://127.0.0.1:{port}/api/ws?token={session_token}");
        let (socket, _) = timeout(REQUEST_TIMEOUT, connect_async(&endpoint))
            .await
            .map_err(|_| {
                gateway_error(
                    "runtime-unavailable",
                    "Hermes Gateway WebSocket connection timed out.",
                )
            })?
            .map_err(|error| {
                gateway_error(
                    "runtime-unavailable",
                    format!("Hermes Gateway WebSocket connection failed: {error}"),
                )
            })?;
        let (writer, reader) = socket.split();
        let adapter = Self {
            inner: Arc::new(Inner {
                permissions: SessionPermissionStore::for_target(&config.target.id),
                target: config.target,
                port,
                session_token,
                writer: Mutex::new(writer),
                pending: Mutex::new(HashMap::new()),
                state: Mutex::new(State {
                    protocol_version: 1,
                    runtime_version: health
                        .get("version")
                        .and_then(Value::as_str)
                        .map(str::to_owned),
                    capabilities: gateway_capabilities(),
                    session_info: json!({}),
                    profiles,
                    active_profile,
                    ..State::default()
                }),
                stderr: stderr_buffer,
                ready: Notify::new(),
                next_request_id: AtomicU64::new(0),
                next_event_sequence: AtomicU64::new(0),
                event_tx,
                wait_task: Mutex::new(None),
                stdout_task: Mutex::new(None),
                stderr_task: Mutex::new(Some(stderr_task)),
                socket_task: Mutex::new(None),
            }),
        };
        adapter
            .inner
            .emit_status("Connecting to Hermes Gateway…", "connecting", None, None);
        let weak = Arc::downgrade(&adapter.inner);
        *adapter.inner.socket_task.lock().await = Some(tokio::spawn(async move {
            read_socket(weak, reader).await;
        }));
        let weak = Arc::downgrade(&adapter.inner);
        *adapter.inner.stdout_task.lock().await = Some(tokio::spawn(async move {
            drain_stdout(weak, stdout_lines).await;
        }));
        let weak = Arc::downgrade(&adapter.inner);
        *adapter.inner.wait_task.lock().await = Some(tokio::spawn(async move {
            let status = child.wait().await;
            if let Some(inner) = weak.upgrade() {
                inner.handle_process_exit(status).await;
            }
        }));
        if let Err(error) = adapter
            .initialize(
                config.preferred_session_id,
                config.list_only,
                config.command.full_access,
            )
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
        full_access: bool,
    ) -> Result<(), CodexError> {
        if !self.inner.state.lock().await.gateway_ready {
            timeout(REQUEST_TIMEOUT, self.inner.ready.notified())
                .await
                .map_err(|_| {
                    gateway_error(
                        "runtime-unavailable",
                        "Hermes Gateway did not emit gateway.ready.",
                    )
                })?;
        }
        if list_only {
            return Ok(());
        }
        self.activate(preferred_session_id, None, full_access).await
    }

    pub async fn activate(
        &self,
        preferred_session_id: Option<String>,
        cwd: Option<&str>,
        full_access: bool,
    ) -> Result<(), CodexError> {
        let sessions = self.load_sessions().await?;
        if let Some(session_id) = preferred_session_id
            && let Some(session) = sessions
                .iter()
                .find(|session| session.get("id").and_then(Value::as_str) == Some(&session_id))
        {
            self.resume_session(&session_id, session.get("profile").and_then(Value::as_str))
                .await?;
        } else {
            self.new_session(None, None, cwd, None, full_access).await?;
        }
        self.refresh_models().await;
        let session_id = self.active_session_id().await?;
        self.inner.emit_status(
            &format!("Hermes Gateway ready · {}", short_id(&session_id)),
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
        self.inner
            .state
            .lock()
            .await
            .active_session_id
            .clone()
            .ok_or_else(|| gateway_error("runtime-failed", "Hermes Gateway has no active session."))
    }

    pub async fn binding_metadata(&self) -> Option<Value> {
        let state = self.inner.state.lock().await;
        let session_id = state.active_session_id.clone()?;
        Some(json!({
            "sessionKey": session_id,
            "profile": state
                .session_info
                .get("profile_name")
                .and_then(Value::as_str)
                .unwrap_or(&state.active_profile),
            "cwd": state.session_info.get("cwd")
        }))
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
        let runtime_session_id = self
            .inner
            .state
            .lock()
            .await
            .runtime_session_id
            .clone()
            .ok_or_else(|| crate::command_catalog::error("Hermes session is not ready."))?;
        let response = self
            .inner
            .request("commands.catalog", json!({"session_id":runtime_session_id}))
            .await?;
        let commands = crate::command_catalog::hermes_catalog(&response);
        self.inner
            .state
            .lock()
            .await
            .command_catalogs
            .insert(session_id.into(), commands.clone());
        Ok(commands)
    }

    pub async fn connection_value(&self) -> Result<Value, CodexError> {
        let session_id = self.active_session_id().await?;
        let rewind_supported = self
            .list_commands(&session_id, false)
            .await
            .ok()
            .is_some_and(|commands| {
                crate::command_catalog::require_command(&commands, "/undo").is_ok()
            });
        let state = self.inner.state.lock().await;
        let session_id = state.active_session_id.clone().ok_or_else(|| {
            gateway_error("runtime-failed", "Hermes Gateway has no active session.")
        })?;
        let profile = state
            .session_info
            .get("profile_name")
            .and_then(Value::as_str)
            .unwrap_or(&state.active_profile);
        let model = encode_model_id(
            state.session_info.get("provider").and_then(Value::as_str),
            state.session_info.get("model").and_then(Value::as_str),
        );
        let mut capabilities = state.capabilities.clone();
        if rewind_supported {
            capabilities.extend([
                "session.rewind.v1".into(),
                "session.rewind.prepare.v1".into(),
            ]);
        }
        Ok(json!({
            "runtimeTargetId": self.inner.target.id,
            "sessionId": session_id,
            "protocolVersion": state.protocol_version,
            "runtimeVersion": state.runtime_version,
            "capabilities": capabilities,
            "models": state.models,
            "sessions": state.sessions,
            "history": {"thread": {"id": session_id, "turns": state.histories.get(&session_id).cloned().unwrap_or_default()}},
            "sessionMetadata": {
                "sessionKey": session_id,
                "activeModel": model,
                "activeEffort": state.session_info.get("reasoning_effort"),
                "cwd": state.session_info.get("cwd"),
                "profile": profile,
                "profiles": state.profiles
            }
        }))
    }

    pub async fn list_sessions(&self) -> Result<Vec<Value>, CodexError> {
        self.load_sessions().await
    }

    pub async fn create_session(
        &self,
        model: Option<&str>,
        effort: Option<&str>,
        cwd: Option<&str>,
        profile: Option<&str>,
        full_access: bool,
    ) -> Result<Value, CodexError> {
        self.new_session(model, effort, cwd, profile, full_access)
            .await?;
        self.load_sessions().await?;
        self.connection_value().await
    }

    pub async fn open_session(
        &self,
        session_id: &str,
        profile: Option<&str>,
    ) -> Result<Value, CodexError> {
        // The sidebar already knows this identity. Only refresh the complete
        // inventory when this adapter has not seen it yet.
        let mut sessions = self.inner.state.lock().await.sessions.clone();
        if !sessions.iter().any(|session| session["id"] == session_id) {
            sessions = self.load_sessions().await?;
        }
        if !sessions
            .iter()
            .any(|session| session.get("id").and_then(Value::as_str) == Some(session_id))
        {
            return Err(gateway_error(
                "identity-mismatch",
                format!("Hermes session '{session_id}' was not returned by this Gateway."),
            ));
        }
        let profile = profile.or_else(|| {
            sessions
                .iter()
                .find(|session| session.get("id").and_then(Value::as_str) == Some(session_id))
                .and_then(|session| session.get("profile"))
                .and_then(Value::as_str)
        });
        self.resume_session(session_id, profile).await?;
        self.refresh_models().await;
        self.connection_value().await
    }

    pub async fn configure_session(
        &self,
        session_id: &str,
        cwd: Option<&str>,
        profile: Option<&str>,
        model: Option<&str>,
        effort: Option<&str>,
    ) -> Result<Value, CodexError> {
        if self.active_session_id().await? != session_id {
            return Err(gateway_error(
                "identity-mismatch",
                "The requested session is not the exact active Hermes Gateway session.",
            ));
        }
        let current_profile = {
            let state = self.inner.state.lock().await;
            state
                .session_info
                .get("profile_name")
                .and_then(Value::as_str)
                .unwrap_or(&state.active_profile)
                .to_owned()
        };
        if profile.is_some_and(|value| !value.is_empty() && value != current_profile) {
            let full_access = self
                .inner
                .permissions
                .full_access(session_id)
                .map_err(permission_error)?;
            self.new_session(model, effort, cwd, profile, full_access)
                .await?;
            self.load_sessions().await?;
            self.refresh_models().await;
            return self.connection_value().await;
        }
        if let Some(cwd) = cwd.filter(|value| !value.trim().is_empty()) {
            let runtime_session_id = self
                .inner
                .state
                .lock()
                .await
                .runtime_session_id
                .clone()
                .ok_or_else(|| {
                    gateway_error("runtime-failed", "Hermes runtime session is missing.")
                })?;
            let info = self
                .inner
                .request(
                    "session.cwd.set",
                    json!({"session_id": runtime_session_id, "cwd": cwd}),
                )
                .await?;
            let mut state = self.inner.state.lock().await;
            if let Some(object) = info.as_object() {
                for (key, value) in object {
                    state.session_info[key] = value.clone();
                }
            } else {
                state.session_info["cwd"] = Value::String(cwd.into());
            }
        }
        self.connection_value().await
    }

    pub async fn read_session(&self, session_id: &str) -> Result<Value, CodexError> {
        let state = self.inner.state.lock().await;
        let turns = state.histories.get(session_id).cloned().unwrap_or_default();
        Ok(json!({"thread": {"id": session_id, "turns": turns}}))
    }

    pub async fn prepare_rewind(&self, session_id: &str) -> Result<Value, CodexError> {
        let state = self.inner.state.lock().await;
        if state.active_session_id.as_deref() != Some(session_id) {
            return Err(gateway_error(
                "identity-mismatch",
                "The requested Hermes chat is not active.",
            ));
        }
        if state.active_turns.contains_key(session_id) {
            return Err(gateway_error(
                "session-busy",
                "Stop Hermes before editing an earlier message.",
            ));
        }
        let profile = state.session_info["profile_name"]
            .as_str()
            .unwrap_or(&state.active_profile)
            .to_owned();
        drop(state);
        // session.history omits row IDs on current Hermes. Resuming the exact
        // idle session returns its durable display projection including row_id.
        let response = self.inner.request("session.resume", json!({"session_id":session_id,"source":"zommi","close_on_disconnect":false,"profile":profile})).await?;
        if self.active_session_id().await? != session_id || response["running"] == true {
            return Err(crate::session_rewind::error(
                "The Hermes session changed during rewind preparation.",
            ));
        }
        let messages = response["messages"].as_array().ok_or_else(|| {
            crate::session_rewind::error("Hermes did not return authoritative history.")
        })?;
        if messages
            .iter()
            .filter(|message| message["role"] == "user")
            .any(|message| {
                message.get("row_id").is_none()
                    || message
                        .get("display_kind")
                        .and_then(Value::as_str)
                        .is_some_and(|kind| kind != "skill_invocation")
            })
        {
            return Err(crate::session_rewind::error(
                "Hermes did not expose durable user message IDs for this conversation.",
            ));
        }
        Ok(json!({"thread":{"id":session_id,"turns":messages_to_turns(messages)}}))
    }

    pub async fn rewind_session(
        &self,
        session_id: &str,
        turn_id: &str,
        last_id: &str,
    ) -> Result<Value, CodexError> {
        let commands = self.list_commands(session_id, false).await?;
        crate::command_catalog::require_command(&commands, "/undo")?;
        let before = self.prepare_rewind(session_id).await?;
        let index = crate::session_rewind::target(&before, turn_id, last_id)?;
        let count = crate::session_rewind::turns(&before)?[index..]
            .iter()
            .filter(|turn| {
                turn["items"]
                    .as_array()
                    .is_some_and(|items| items.iter().any(|item| item["type"] == "userMessage"))
            })
            .count();
        let native = self
            .inner
            .state
            .lock()
            .await
            .runtime_session_id
            .clone()
            .ok_or_else(|| crate::session_rewind::error("Hermes session binding is missing."))?;
        // session.undo changes only memory. /undo N is the runtime's durable
        // operation: it archives rows and invalidates the agent's cached context.
        let response = self
            .inner
            .request(
                "slash.exec",
                json!({"session_id":native,"command":format!("/undo {count}")}),
            )
            .await
            .map_err(|mut error| {
                error.retryable = false;
                error
            })?;
        if response["type"] != "prefill" {
            return Err(crate::session_rewind::error(
                "Hermes did not confirm a durable undo.",
            ));
        }
        let after = self.prepare_rewind(session_id).await?;
        crate::session_rewind::verify_prefix(&before, &after, index)?;
        self.inner.state.lock().await.histories.insert(
            session_id.into(),
            crate::session_rewind::turns(&after)?.clone(),
        );
        Ok(after)
    }

    async fn submit_command(
        &self,
        runtime_session_id: &str,
        session_id: &str,
        text: &str,
    ) -> Result<Value, CodexError> {
        let commands = self.list_commands(session_id, false).await?;
        let mut text = text.to_owned();
        for _ in 0..5 {
            let command = crate::command_catalog::require_command(&commands, &text)?;
            let name = crate::command_catalog::command_name(&text).unwrap();
            let args = text
                .split_once(char::is_whitespace)
                .map(|(_, args)| args)
                .unwrap_or("");
            let value = if matches!(command["source"].as_str(), Some("skill" | "quick")) {
                self.inner
                    .request(
                        "command.dispatch",
                        json!({"session_id":runtime_session_id,"name":name,"arg":args}),
                    )
                    .await?
            } else {
                self.inner
                    .request(
                        "slash.exec",
                        json!({"session_id":runtime_session_id,"command":text}),
                    )
                    .await?
            };
            match value.get("type").and_then(Value::as_str) {
                Some("alias") => {
                    let target = value["target"].as_str().ok_or_else(|| {
                        crate::command_catalog::error("Hermes returned an invalid alias.")
                    })?;
                    text = format!("/{} {}", target.trim_start_matches('/'), args);
                }
                Some("send" | "skill") => {
                    let message = value["message"].as_str().ok_or_else(|| {
                        crate::command_catalog::error(
                            "Hermes returned an invalid command expansion.",
                        )
                    })?;
                    return self
                        .inner
                        .request(
                            "prompt.submit",
                            json!({"session_id":runtime_session_id,"text":message}),
                        )
                        .await;
                }
                _ if value.get("output").and_then(Value::as_str).is_some() => return Ok(value),
                _ => {
                    return Err(crate::command_catalog::error(
                        "This Hermes command requires a terminal interaction that Zommi does not support.",
                    ));
                }
            }
        }
        Err(crate::command_catalog::error(
            "Hermes command aliases form a loop.",
        ))
    }

    pub async fn start_turn(
        &self,
        request: HermesGatewayTurnRequest<'_>,
    ) -> Result<TurnReceipt, CodexError> {
        let input = validate_turn_input(request.message, request.snapshots, request.images)?;
        if self.active_session_id().await? != request.session_id {
            return Err(gateway_error(
                "identity-mismatch",
                "The requested session is not the exact active Hermes Gateway session.",
            ));
        }
        self.apply_options(request.model, request.effort).await?;
        let runtime_session_id = self
            .inner
            .state
            .lock()
            .await
            .runtime_session_id
            .clone()
            .ok_or_else(|| gateway_error("runtime-failed", "Hermes runtime session is missing."))?;
        for (index, image) in input.images.iter().enumerate() {
            let (mime, content) = parse_image(image)?;
            self.inner
                .request(
                    "image.attach_bytes",
                    json!({
                        "session_id": runtime_session_id,
                        "content_base64": content,
                        "filename": format!("zommi-{}.{}", index + 1, mime_extension(&mime))
                    }),
                )
                .await?;
        }
        let turn_id = Uuid::new_v4().to_string();
        {
            let mut state = self.inner.state.lock().await;
            if state.active_turns.contains_key(request.session_id) {
                return Err(gateway_error(
                    "session-busy",
                    "This Hermes Gateway session already has an active turn.",
                ));
            }
            state
                .active_turns
                .insert(request.session_id.into(), turn_id.clone());
            state.turn_operations.insert(
                request.session_id.into(),
                request.client_operation_id.into(),
            );
            state
                .streamed_assistant
                .insert(request.session_id.into(), StreamedTurn::default());
            state
                .histories
                .entry(request.session_id.into())
                .or_default()
                .push(
                    json!({"id": turn_id, "items": [{"id": format!("{turn_id}-user"),
                    "type": "userMessage", "content": [{"type":"text", "text":input.message}]}]}),
                );
        }
        self.inner.emit(
            "turn.started",
            Some(request.session_id),
            Some(&turn_id),
            Some(request.client_operation_id),
            json!({"status": "inProgress"}),
        );
        let result = if request.slash_command {
            self.submit_command(&runtime_session_id, request.session_id, &input.message)
                .await
        } else {
            self.inner.request("prompt.submit", json!({"session_id":runtime_session_id,
                "text":build_context_handoff(&input.message, &input.snapshots, input.images.len())})).await
        };
        if let Ok(value) = &result
            && let Some(output) = value.get("output").and_then(Value::as_str)
        {
            let mut state = self.inner.state.lock().await;
            state.active_turns.remove(request.session_id);
            state.turn_operations.remove(request.session_id);
            state.streamed_assistant.remove(request.session_id);
            remember_history_item(
                &mut state.histories,
                request.session_id,
                &turn_id,
                json!({"id":format!("{turn_id}-command"), "type":"agentMessage", "text":output, "status":"completed"}),
                None,
            );
            drop(state);
            self.inner.emit("item.update", Some(request.session_id), Some(&turn_id), Some(request.client_operation_id),
                json!({"kind":"assistant", "lifecycle":"completed", "text":output, "itemId":format!("{turn_id}-command")}));
            self.inner.emit(
                "turn.completed",
                Some(request.session_id),
                Some(&turn_id),
                Some(request.client_operation_id),
                json!({"status":"completed"}),
            );
            return Ok(TurnReceipt {
                accepted: true,
                runtime_target_id: self.target_id().into(),
                session_id: request.session_id.into(),
                turn_id,
                client_operation_id: request.client_operation_id.into(),
            });
        }
        match result {
            Ok(value)
                if matches!(
                    value.get("status").and_then(Value::as_str),
                    Some("streaming" | "queued" | "steered")
                ) => {}
            Ok(value) => {
                self.inner
                    .finish_start_error(
                        request.session_id,
                        &turn_id,
                        request.client_operation_id,
                        "failed",
                        "Hermes returned an invalid turn acknowledgement.",
                    )
                    .await;
                return Err(gateway_error(
                    "invalid-response",
                    format!(
                        "Hermes did not acknowledge the turn ({}).",
                        value
                            .get("status")
                            .and_then(Value::as_str)
                            .unwrap_or("unknown status")
                    ),
                ));
            }
            Err(error) => {
                self.inner
                    .finish_start_error(
                        request.session_id,
                        &turn_id,
                        request.client_operation_id,
                        if error.code == "unknown-outcome" {
                            "unknown"
                        } else {
                            "failed"
                        },
                        &error.message,
                    )
                    .await;
                return Err(error);
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

    pub async fn interrupt_turn(
        &self,
        session_id: &str,
        turn_id: &str,
    ) -> Result<Value, CodexError> {
        let state = self.inner.state.lock().await;
        if state.active_turns.get(session_id).map(String::as_str) != Some(turn_id) {
            return Err(gateway_error(
                "identity-mismatch",
                "The requested turn is not the exact active Hermes Gateway turn.",
            ));
        }
        let runtime_session_id = state
            .runtime_session_id
            .clone()
            .ok_or_else(|| gateway_error("runtime-failed", "Hermes runtime session is missing."))?;
        let operation = state.turn_operations.get(session_id).cloned();
        drop(state);
        self.inner
            .request(
                "session.interrupt",
                json!({"session_id": runtime_session_id}),
            )
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
        let pending = self
            .inner
            .state
            .lock()
            .await
            .approvals
            .get(approval_id)
            .cloned()
            .ok_or_else(|| {
                gateway_error(
                    "invalid-request",
                    format!("Unknown Hermes approval '{approval_id}'."),
                )
            })?;
        if pending.session_id != session_id {
            return Err(gateway_error(
                "identity-mismatch",
                "The approval does not belong to the requested Hermes session.",
            ));
        }
        let decision = option_id
            .filter(|option| pending.choices.iter().any(|choice| choice == option))
            .unwrap_or("deny");
        self.inner
            .request(
                "approval.respond",
                json!({"request_id": pending.request_id, "decision": decision}),
            )
            .await?;
        self.inner.state.lock().await.approvals.remove(approval_id);
        Ok(json!({"resolved": true, "approvalId": approval_id, "decision": decision}))
    }

    pub async fn resolve_question(
        &self,
        session_id: &str,
        question_id: &str,
        answer: &Value,
    ) -> Result<Value, CodexError> {
        let pending = self
            .inner
            .state
            .lock()
            .await
            .questions
            .get(question_id)
            .cloned()
            .ok_or_else(|| {
                gateway_error(
                    "invalid-request",
                    format!("Unknown Hermes question '{question_id}'."),
                )
            })?;
        if pending.session_id != session_id {
            return Err(gateway_error(
                "identity-mismatch",
                "The question does not belong to the requested Hermes session.",
            ));
        }
        let value = answer
            .get("value")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let mut params = json!({"request_id": pending.request_id});
        let field = match pending.kind.as_str() {
            "sudo" => "password",
            "secret" => "value",
            _ => "answer",
        };
        params[field] = Value::String(value.into());
        self.inner
            .request(&format!("{}.respond", pending.kind), params)
            .await?;
        self.inner.state.lock().await.questions.remove(question_id);
        Ok(json!({"resolved": true, "questionId": question_id}))
    }

    pub async fn shutdown(&self) {
        self.inner.state.lock().await.stopping = true;
        let _ = self.inner.writer.lock().await.close().await;
        for task in [
            self.inner.wait_task.lock().await.take(),
            self.inner.stdout_task.lock().await.take(),
            self.inner.stderr_task.lock().await.take(),
            self.inner.socket_task.lock().await.take(),
        ]
        .into_iter()
        .flatten()
        {
            task.abort();
        }
        self.inner
            .reject_pending(gateway_error("runtime-stopped", "Hermes Gateway stopped."))
            .await;
    }

    async fn load_recent_sessions(&self, profile: &str) -> Result<Value, CodexError> {
        let mut sessions = Vec::new();
        for offset in [0, 100] {
            let query = url::form_urlencoded::Serializer::new(String::new())
                .append_pair("profile", profile)
                .append_pair("limit", "100")
                .append_pair("offset", &offset.to_string())
                .append_pair("order", "recent")
                .append_pair("exclude_sources", "kanban,tool")
                .finish();
            let response = read_http_json(
                self.inner.port,
                &format!("/api/sessions?{query}"),
                Some(&self.inner.session_token),
            )
            .await?;
            let page = response
                .get("sessions")
                .and_then(Value::as_array)
                .ok_or_else(|| {
                    gateway_error("invalid-response", "Hermes session list is unavailable.")
                })?;
            sessions.extend(page.iter().cloned());
            if page.len() < 100 {
                break;
            }
        }
        Ok(json!({"sessions": sessions}))
    }

    async fn load_sessions(&self) -> Result<Vec<Value>, CodexError> {
        let profile_names = {
            let state = self.inner.state.lock().await;
            let mut names = state
                .profiles
                .iter()
                .filter_map(|profile| profile.get("name").and_then(Value::as_str))
                .filter(|name| !name.is_empty())
                .map(str::to_owned)
                .collect::<Vec<_>>();
            if names.is_empty() {
                names.push(state.active_profile.clone());
            }
            names
        };
        let mut sessions = Vec::new();
        for profile in profile_names {
            // The WebSocket list omits last_active on older Hermes versions.
            // The authenticated REST list retains recency for resumed chats.
            let result = match self.load_recent_sessions(&profile).await {
                Ok(result) => result,
                Err(_) => {
                    self.inner
                        .request("session.list", json!({"limit": 200, "profile": profile}))
                        .await?
                }
            };
            sessions.extend(
                result
                    .get("sessions")
                    .and_then(Value::as_array)
                    .into_iter()
                    .flatten()
                    .filter_map(|session| {
                        let id = session.get("id")?.as_str()?;
                        Some(json!({
                            "id": id,
                            "name": session.get("title"),
                            "preview": session.get("preview").or_else(|| session.get("title")).and_then(Value::as_str).unwrap_or("Hermes session"),
                            "updatedAt": session.get("last_active").and_then(Value::as_f64)
                                .or_else(|| session.get("started_at").and_then(Value::as_f64))
                                .unwrap_or_default(),
                            "messageCount": session.get("message_count").and_then(Value::as_u64).unwrap_or_default(),
                            "profile": profile
                        }))
                    }),
            );
        }
        sessions.sort_by(|a, b| {
            let timestamp = |session: &Value| {
                session
                    .get("updatedAt")
                    .and_then(Value::as_f64)
                    .unwrap_or_default()
            };
            timestamp(b).total_cmp(&timestamp(a))
        });
        let (current, current_profile, current_cwd) = {
            let state = self.inner.state.lock().await;
            (
                state.active_session_id.clone(),
                state
                    .session_info
                    .get("profile_name")
                    .and_then(Value::as_str)
                    .unwrap_or(&state.active_profile)
                    .to_owned(),
                state
                    .session_info
                    .get("cwd")
                    .and_then(Value::as_str)
                    .map(str::to_owned),
            )
        };
        if let Some(current) = current
            && !sessions
                .iter()
                .any(|session| session.get("id").and_then(Value::as_str) == Some(&current))
        {
            sessions.insert(
                0,
                json!({
                    "id": current,
                    "preview": "New Hermes chat",
                    "profile": current_profile,
                    "cwd": current_cwd
                }),
            );
        }
        self.inner.state.lock().await.sessions = sessions.clone();
        Ok(sessions)
    }

    async fn new_session(
        &self,
        model: Option<&str>,
        effort: Option<&str>,
        cwd: Option<&str>,
        profile: Option<&str>,
        full_access: bool,
    ) -> Result<(), CodexError> {
        let selected = self.selected_model(model).await?;
        let mut params = json!({"source": "zommi", "close_on_disconnect": false});
        if let Some(selected) = selected {
            if let Some(raw) = selected.get("rawModelId") {
                params["model"] = raw.clone();
            }
            if let Some(provider) = selected.get("provider") {
                params["provider"] = provider.clone();
            }
        }
        if let Some(effort) = effort {
            params["reasoning_effort"] = Value::String(effort.into());
        }
        if let Some(cwd) = cwd.filter(|value| !value.trim().is_empty()) {
            params["cwd"] = Value::String(cwd.into());
        }
        if let Some(profile) = profile.filter(|value| !value.trim().is_empty()) {
            params["profile"] = Value::String(profile.into());
        }
        self.inner.request("session.create", params).await?;
        if full_access {
            self.inner
                .permissions
                .remember_full_access(&self.active_session_id().await?)
                .map_err(permission_error)?;
        }
        Ok(())
    }

    async fn resume_session(
        &self,
        session_id: &str,
        profile: Option<&str>,
    ) -> Result<(), CodexError> {
        let mut params = json!({
            "session_id": session_id,
            "source": "zommi",
            "close_on_disconnect": false
        });
        if let Some(profile) = profile.filter(|value| !value.trim().is_empty()) {
            params["profile"] = Value::String(profile.into());
        }
        self.inner.request("session.resume", params).await?;
        Ok(())
    }

    pub async fn reload_models(&self) -> Result<Vec<Value>, CodexError> {
        let (session_id, profile) = {
            let state = self.inner.state.lock().await;
            (
                state.runtime_session_id.clone().unwrap_or_default(),
                state.session_info["profile_name"]
                    .as_str()
                    .unwrap_or(&state.active_profile)
                    .to_owned(),
            )
        };
        let value = self
            .inner
            .request(
                "model.options",
                json!({"session_id": session_id, "refresh": true}),
            )
            .await?;
        let models = models_for_ui(&value);
        let mut state = self.inner.state.lock().await;
        state
            .model_catalogs
            .insert(profile, (Instant::now(), models.clone()));
        state.set_models(models.clone());
        Ok(models)
    }

    async fn refresh_models(&self) {
        let (runtime_session_id, profile) = {
            let mut state = self.inner.state.lock().await;
            let profile = state.session_info["profile_name"]
                .as_str()
                .unwrap_or(&state.active_profile)
                .to_owned();
            if let Some((updated, models)) = state.model_catalogs.get(&profile)
                && updated.elapsed() < Duration::from_secs(300)
            {
                let models = models.clone();
                state.set_models(models);
                return;
            }
            (
                state.runtime_session_id.clone().unwrap_or_default(),
                profile,
            )
        };
        match self
            .inner
            .request("model.options", json!({"session_id": runtime_session_id}))
            .await
        {
            Ok(value) => {
                let models = models_for_ui(&value);
                let mut state = self.inner.state.lock().await;
                state
                    .model_catalogs
                    .insert(profile, (Instant::now(), models.clone()));
                state.set_models(models);
            }
            Err(error) => {
                let mut state = self.inner.state.lock().await;
                state.set_models(Vec::new());
                drop(state);
                self.inner.emit_status(
                    &format!("Hermes model inventory unavailable: {}", error.message),
                    "degraded",
                    None,
                    None,
                );
            }
        }
    }

    async fn selected_model(&self, model: Option<&str>) -> Result<Option<Value>, CodexError> {
        let Some(model) = model.filter(|model| !model.is_empty()) else {
            return Ok(None);
        };
        let state = self.inner.state.lock().await;
        // Lazy session.create replies can omit provider, and a configured
        // current model need not be listed in the picker. Preserve that exact
        // session choice when creating another chat in the same profile.
        let current_model = encode_model_id(
            state.session_info["provider"].as_str(),
            state.session_info["model"].as_str(),
        );
        if model == current_model || state.session_info["model"].as_str() == Some(model) {
            return Ok(Some(json!({
                "id": current_model,
                "rawModelId": state.session_info["model"],
                "provider": state.session_info["provider"],
            })));
        }
        let selected = state
            .models
            .iter()
            .find(|candidate| {
                candidate.get("id").and_then(Value::as_str) == Some(model)
                    || candidate.get("model").and_then(Value::as_str) == Some(model)
            })
            .cloned();
        selected.map(Some).ok_or_else(|| gateway_error(
            "invalid-request",
            "Hermes no longer advertises that model. Refresh agents and select an available model.",
        ))
    }

    async fn apply_options(
        &self,
        model: Option<&str>,
        effort: Option<&str>,
    ) -> Result<(), CodexError> {
        let (runtime_session_id, current_model, current_effort) = {
            let state = self.inner.state.lock().await;
            (
                state.runtime_session_id.clone().unwrap_or_default(),
                encode_model_id(
                    state.session_info.get("provider").and_then(Value::as_str),
                    state.session_info.get("model").and_then(Value::as_str),
                ),
                state
                    .session_info
                    .get("reasoning_effort")
                    .and_then(Value::as_str)
                    .map(str::to_owned),
            )
        };
        // The runtime can use a configured model that is absent from its picker.
        // Leave that active model alone; validate explicit changes against inventory.
        if let Some(selected) = self
            .selected_model(model.filter(|model| *model != current_model))
            .await?
            && selected["id"] != current_model
        {
            let raw = selected
                .get("rawModelId")
                .and_then(Value::as_str)
                .unwrap_or_default();
            let provider = selected
                .get("provider")
                .and_then(Value::as_str)
                .unwrap_or_default();
            let result = self
                .inner
                .request(
                    "config.set",
                    json!({
                        "session_id": runtime_session_id,
                        "key": "model",
                        "value": format!("{raw} --provider {provider} --session")
                    }),
                )
                .await?;
            if result.get("confirm_required").and_then(Value::as_bool) == Some(true) {
                return Err(gateway_error(
                    "conflict",
                    result
                        .get("confirm_message")
                        .and_then(Value::as_str)
                        .unwrap_or("Hermes requires confirmation for this model switch."),
                ));
            }
            let mut state = self.inner.state.lock().await;
            state.session_info["model"] = Value::String(raw.into());
            state.session_info["provider"] = Value::String(provider.into());
        }
        if let Some(effort) = effort
            && current_effort.as_deref() != Some(effort)
        {
            self.inner
                .request(
                    "config.set",
                    json!({
                        "session_id": runtime_session_id,
                        "key": "reasoning",
                        "value": effort
                    }),
                )
                .await?;
            self.inner.state.lock().await.session_info["reasoning_effort"] =
                Value::String(effort.into());
        }
        Ok(())
    }
}

impl Inner {
    async fn request(&self, method: &str, params: Value) -> Result<Value, CodexError> {
        let state = self.state.lock().await;
        if state.exited || !state.gateway_ready {
            return Err(gateway_error(
                "runtime-exited",
                "Hermes Gateway is not connected.",
            ));
        }
        drop(state);
        let id = format!(
            "zommi-{}",
            self.next_request_id
                .fetch_add(1, Ordering::Relaxed)
                .saturating_add(1)
        );
        let (completion, receiver) = oneshot::channel();
        self.pending.lock().await.insert(
            id.clone(),
            PendingRequest {
                method: method.into(),
                requested_session_id: params
                    .get("session_id")
                    .and_then(Value::as_str)
                    .map(str::to_owned),
                completion,
            },
        );
        let frame = json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params});
        let send = self
            .writer
            .lock()
            .await
            .send(Message::Text(frame.to_string().into()))
            .await;
        if let Err(error) = send {
            self.pending.lock().await.remove(&id);
            return Err(gateway_error("runtime-exited", error.to_string()));
        }
        match timeout(REQUEST_TIMEOUT, receiver).await {
            Ok(Ok(result)) => result,
            Ok(Err(_)) => Err(gateway_error(
                "runtime-exited",
                "Hermes Gateway response channel closed.",
            )),
            Err(_) => {
                self.pending.lock().await.remove(&id);
                Err(CodexError {
                    code: "unknown-outcome".into(),
                    message: format!("Hermes Gateway did not respond to '{method}' in time."),
                    retryable: true,
                })
            }
        }
    }

    async fn handle_frame(self: &Arc<Self>, frame: Value) {
        if let Some(id) = frame.get("id") {
            let id = value_string(Some(id));
            let Some(pending) = self.pending.lock().await.remove(&id) else {
                return;
            };
            let result = if let Some(error) = frame.get("error") {
                Err(gateway_error(
                    "runtime-request-failed",
                    format!(
                        "Hermes {} failed: {}",
                        pending.method,
                        error
                            .get("message")
                            .and_then(Value::as_str)
                            .unwrap_or("Gateway request failed")
                    ),
                ))
            } else {
                Ok(frame.get("result").cloned().unwrap_or_else(|| json!({})))
            };
            pending.complete(result, &self.state).await;
            return;
        }
        if frame.get("method").and_then(Value::as_str) == Some("event") {
            self.handle_event(frame.get("params").unwrap_or(&Value::Null))
                .await;
        }
    }

    async fn handle_event(self: &Arc<Self>, event: &Value) {
        let event_type = event
            .get("type")
            .and_then(Value::as_str)
            .unwrap_or_default();
        if event_type == "gateway.ready" {
            self.state.lock().await.gateway_ready = true;
            self.ready.notify_one();
            return;
        }
        let runtime_session_id = event
            .get("session_id")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let payload = event.get("payload").cloned().unwrap_or_else(|| json!({}));
        let mut state = self.state.lock().await;
        let Some(session_id) = state.runtime_session_ids.get(runtime_session_id).cloned() else {
            drop(state);
            self.emit(
                "runtime.diagnostic",
                None,
                None,
                None,
                json!({"method": event_type}),
            );
            return;
        };
        let turn_id = state.active_turns.get(&session_id).cloned();
        let operation = state.turn_operations.get(&session_id).cloned();
        let terminal_key = turn_id.as_ref().map(|turn| format!("{session_id}:{turn}"));
        if terminal_key
            .as_ref()
            .is_some_and(|key| state.terminal_turns.contains(key))
        {
            return;
        }
        match event_type {
            "session.info" => {
                if state.active_session_id.as_deref() == Some(&session_id)
                    && let Some(object) = payload.as_object()
                {
                    if !state.session_info.is_object() {
                        state.session_info = json!({});
                    }
                    for (key, value) in object {
                        state.session_info[key] = value.clone();
                    }
                }
            }
            "message.start" => {
                if turn_id.is_some() {
                    state.streamed_assistant.entry(session_id).or_default();
                }
            }
            "message.delta" => {
                let Some(turn_id) = turn_id else { return };
                let text = payload
                    .get("text")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_owned();
                let stream = state
                    .streamed_assistant
                    .entry(session_id.clone())
                    .or_default();
                stream.assistant_text.push_str(&text);
                stream.reasoning_open = false;
                let item_id = stream.assistant_id(&turn_id);
                let item = json!({"id":item_id, "type":"agentMessage", "text":stream.assistant_text, "status":"inProgress"});
                remember_history_item(&mut state.histories, &session_id, &turn_id, item, None);
                drop(state);
                self.emit(
                    "item.update",
                    Some(&session_id),
                    Some(&turn_id),
                    operation.as_deref(),
                    json!({"kind": "assistant", "lifecycle": "delta", "title": "Hermes", "text": text, "textMode":"append", "itemId": item_id}),
                );
            }
            "message.interim" => {
                let Some(turn_id) = turn_id else { return };
                let text = payload
                    .get("text")
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                if text.is_empty() {
                    return;
                }
                let stream = state
                    .streamed_assistant
                    .entry(session_id.clone())
                    .or_default();
                let item_id = stream.assistant_id(&turn_id);
                // Interim text is a complete snapshot, including when its
                // deltas have already streamed. Seal it before the next step.
                stream.seal_assistant();
                remember_history_item(
                    &mut state.histories,
                    &session_id,
                    &turn_id,
                    json!({"id":item_id, "type":"agentMessage", "text":text, "status":"completed"}),
                    None,
                );
                drop(state);
                self.emit("item.update", Some(&session_id), Some(&turn_id), operation.as_deref(),
                    json!({"kind":"assistant", "lifecycle":"completed", "title":"Hermes", "text":text, "replace":true, "itemId":item_id}));
            }
            "reasoning.available" => {
                // Hermes emits this from assistant_message.content (a 500-char
                // reply preview), not the provider's reasoning channel. The
                // message events carry that same prose authoritatively.
            }
            "reasoning.delta" | "thinking.delta" => {
                let Some(turn_id) = turn_id else { return };
                let text = payload
                    .get("text")
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                let stream = state
                    .streamed_assistant
                    .entry(session_id.clone())
                    .or_default();
                if !stream.reasoning_open {
                    stream.reasoning_segment += 1;
                    stream.reasoning_id =
                        Some(format!("{turn_id}-thinking-{}", stream.reasoning_segment));
                    stream.reasoning_text.clear();
                    stream.reasoning_open = true;
                }
                stream.reasoning_text.push_str(text);
                let item_id = stream.reasoning_id.clone().expect("reasoning segment");
                let item = json!({"id":item_id, "type":"reasoning", "summary":[stream.reasoning_text], "status":"inProgress"});
                remember_history_item(&mut state.histories, &session_id, &turn_id, item, None);
                drop(state);
                self.emit(
                    "item.update",
                    Some(&session_id),
                    Some(&turn_id),
                    operation.as_deref(),
                    json!({"kind": "thinking", "lifecycle": "delta", "title": "Thinking", "text": text, "textMode":"append", "itemId": item_id}),
                );
            }
            "tool.start" | "tool.progress" | "tool.complete" => {
                let Some(turn_id) = turn_id else { return };
                let lifecycle = if event_type == "tool.start" {
                    "started"
                } else if event_type == "tool.complete" {
                    "completed"
                } else {
                    "delta"
                };
                let title = payload
                    .get("name")
                    .and_then(Value::as_str)
                    .unwrap_or("Tool");
                let text = payload
                    .get("text")
                    .or_else(|| payload.get("output"))
                    .or_else(|| payload.get("result"))
                    .or_else(|| payload.get("context"))
                    .map(value_string_value)
                    .unwrap_or_else(|| payload.to_string());
                let item_id = payload
                    .get("tool_id")
                    .and_then(Value::as_str)
                    .map(str::to_owned)
                    .unwrap_or_else(|| format!("{turn_id}-tool"));
                let preview = payload
                    .get("context")
                    .map(value_string_value)
                    .unwrap_or_default();
                let existing = state
                    .histories
                    .get(&session_id)
                    .and_then(|turns| turns.last())
                    .and_then(|turn| turn["items"].as_array())
                    .and_then(|items| items.iter().find(|item| item["id"] == item_id));
                let preview = if preview.is_empty() {
                    existing
                        .and_then(|item| item["command"].as_str())
                        .unwrap_or_default()
                        .to_owned()
                } else {
                    preview
                };
                remember_history_item(
                    &mut state.histories,
                    &session_id,
                    &turn_id,
                    json!({"id":item_id, "type":"commandExecution", "title":title, "command":preview, "aggregatedOutput":text,
                        "status":if lifecycle == "completed" {"completed"} else {"inProgress"}}),
                    None,
                );
                drop(state);
                self.emit(
                    "item.update",
                    Some(&session_id),
                    Some(&turn_id),
                    operation.as_deref(),
                    json!({"kind": if lifecycle == "delta" { "toolOutput" } else { "tool" }, "lifecycle": lifecycle, "title": title, "text": text, "itemId": item_id, "preview":preview}),
                );
            }
            "status.update" => {
                let text = payload
                    .get("text")
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                drop(state);
                if !text.is_empty() {
                    self.emit_status(text, "ready", Some(&session_id), turn_id.as_deref());
                }
            }
            "approval.request" => {
                let approval_id = payload
                    .get("request_id")
                    .and_then(Value::as_str)
                    .map(str::to_owned)
                    .unwrap_or_else(|| Uuid::new_v4().to_string());
                let choices = payload
                    .get("choices")
                    .and_then(Value::as_array)
                    .map(|values| values.iter().map(value_string_value).collect())
                    .unwrap_or_else(|| vec!["once".into(), "session".into(), "deny".into()]);
                state.approvals.insert(
                    approval_id.clone(),
                    PendingApproval {
                        session_id: session_id.clone(),
                        request_id: payload
                            .get("request_id")
                            .and_then(Value::as_str)
                            .unwrap_or(&approval_id)
                            .into(),
                        choices: choices.clone(),
                    },
                );
                drop(state);
                let approval = json!({
                    "approvalId": approval_id,
                    "options": choices.iter().map(|choice| json!({
                        "optionId": choice,
                        "name": approval_label(choice),
                        "kind": if choice == "deny" { "reject" } else { "allow_once" }
                    })).collect::<Vec<_>>(),
                    "toolCall": {"title": payload.get("description").or_else(|| payload.get("reason")).and_then(Value::as_str).unwrap_or("Hermes command"), "rawInput": payload}
                });
                // Only grant permissions offered for this exact saved chat.
                // Run the RPC outside the socket reader so it can receive the reply.
                let automatic = payload
                    .get("choices")
                    .and_then(Value::as_array)
                    .and_then(|offered| {
                        ["once", "session"]
                            .into_iter()
                            .find(|choice| offered.iter().any(|v| v.as_str() == Some(choice)))
                    })
                    .filter(|_| self.permissions.full_access(&session_id).unwrap_or(false));
                if let Some(choice) = automatic {
                    let adapter = HermesGatewayAdapter {
                        inner: self.clone(),
                    };
                    tokio::spawn(async move {
                        if adapter
                            .resolve_approval(&session_id, &approval_id, Some(choice))
                            .await
                            .is_err()
                        {
                            adapter.inner.emit(
                                "approval.requested",
                                Some(&session_id),
                                turn_id.as_deref(),
                                operation.as_deref(),
                                approval,
                            );
                        }
                    });
                } else {
                    self.emit(
                        "approval.requested",
                        Some(&session_id),
                        turn_id.as_deref(),
                        operation.as_deref(),
                        approval,
                    );
                }
            }
            "clarify.request" | "secret.request" | "sudo.request" => {
                let kind = event_type.split('.').next().unwrap_or("clarify");
                let question_id = payload
                    .get("request_id")
                    .and_then(Value::as_str)
                    .map(str::to_owned)
                    .unwrap_or_else(|| Uuid::new_v4().to_string());
                state.questions.insert(
                    question_id.clone(),
                    PendingQuestion {
                        session_id: session_id.clone(),
                        request_id: payload
                            .get("request_id")
                            .and_then(Value::as_str)
                            .unwrap_or(&question_id)
                            .into(),
                        kind: kind.into(),
                    },
                );
                let choices = payload
                    .get("choices")
                    .and_then(Value::as_array)
                    .cloned()
                    .unwrap_or_default();
                drop(state);
                self.emit(
                    "question.requested",
                    Some(&session_id),
                    turn_id.as_deref(),
                    operation.as_deref(),
                    json!({
                        "questionId": question_id,
                        "method": if choices.is_empty() { "input" } else { "select" },
                        "title": if kind == "clarify" { "Hermes needs clarification" } else if kind == "sudo" { "Hermes requests sudo authentication" } else { "Hermes requests a secret" },
                        "message": payload.get("question").or_else(|| payload.get("prompt")).or_else(|| payload.get("message")).and_then(Value::as_str).unwrap_or(""),
                        "options": choices,
                        "sensitive": kind == "sudo" || kind == "secret"
                    }),
                );
            }
            value if value.ends_with(".expire") => {
                let request_id = payload
                    .get("request_id")
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                state
                    .questions
                    .retain(|_, question| question.request_id != request_id);
            }
            "message.complete" => {
                let Some(turn_id) = turn_id else { return };
                let final_text = payload
                    .get("text")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_owned();
                let stream = state
                    .streamed_assistant
                    .remove(&session_id)
                    .unwrap_or_default();
                let item_id = stream.assistant_id(&turn_id);
                let status =
                    normalize_completion_status(payload.get("status").and_then(Value::as_str));
                let error = payload.get("error").cloned();
                let reasoning = reasoning_text(&payload);
                let reasoning_id = stream.reasoning_id.clone().unwrap_or_else(|| {
                    format!("{turn_id}-thinking-{}", stream.reasoning_segment + 1)
                });
                if !reasoning.is_empty() {
                    remember_history_item(
                        &mut state.histories,
                        &session_id,
                        &turn_id,
                        json!({"id":reasoning_id, "type":"reasoning", "summary":[reasoning], "status":"completed"}),
                        Some(&item_id),
                    );
                }
                // A final frame is authoritative even if it differs from the
                // streamed candidate, or an interim message already sealed it.
                let final_text = if final_text.is_empty() {
                    stream.assistant_text
                } else {
                    final_text
                };
                if !final_text.is_empty() {
                    remember_history_item(
                        &mut state.histories,
                        &session_id,
                        &turn_id,
                        json!({"id":item_id, "type":"agentMessage", "text":final_text, "status":"completed"}),
                        None,
                    );
                }
                state.active_turns.remove(&session_id);
                state.turn_operations.remove(&session_id);
                state
                    .terminal_turns
                    .insert(format!("{session_id}:{turn_id}"));
                if let Some(items) = state
                    .histories
                    .get_mut(&session_id)
                    .and_then(|turns| turns.last_mut())
                    .and_then(|turn| turn["items"].as_array_mut())
                {
                    for item in items {
                        item["status"] = json!("completed");
                    }
                }
                prune_set(&mut state.terminal_turns);
                drop(state);
                if !reasoning.is_empty() {
                    self.emit("item.update", Some(&session_id), Some(&turn_id), operation.as_deref(),
                        json!({"kind":"thinking", "lifecycle":"completed", "title":"Thinking", "text":reasoning,
                            "replace":true, "itemId":reasoning_id, "beforeItemId":item_id}));
                }
                if !final_text.is_empty() {
                    self.emit("item.update", Some(&session_id), Some(&turn_id), operation.as_deref(),
                        json!({"kind":"assistant", "lifecycle":"completed", "title":"Hermes", "text":final_text,
                            "replace":true, "itemId":item_id}));
                }
                let mut completion = json!({"status": status});
                if let Some(error) = error {
                    completion["error"] = error;
                }
                self.emit(
                    "turn.completed",
                    Some(&session_id),
                    Some(&turn_id),
                    operation.as_deref(),
                    completion,
                );
            }
            "error" => {
                let message = payload
                    .get("message")
                    .and_then(Value::as_str)
                    .unwrap_or("Hermes Gateway error");
                drop(state);
                self.emit_status(message, "degraded", Some(&session_id), turn_id.as_deref());
            }
            _ => {
                drop(state);
                self.emit(
                    "runtime.diagnostic",
                    Some(&session_id),
                    turn_id.as_deref(),
                    operation.as_deref(),
                    json!({"method": event_type}),
                );
            }
        }
    }

    async fn finish_start_error(
        &self,
        session_id: &str,
        turn_id: &str,
        operation_id: &str,
        status: &str,
        message: &str,
    ) {
        let mut state = self.state.lock().await;
        let matches = state.active_turns.get(session_id).map(String::as_str) == Some(turn_id);
        if matches {
            state.active_turns.remove(session_id);
            state.turn_operations.remove(session_id);
            state.streamed_assistant.remove(session_id);
            state
                .terminal_turns
                .insert(format!("{session_id}:{turn_id}"));
            prune_set(&mut state.terminal_turns);
        }
        drop(state);
        if matches {
            self.emit(
                "turn.completed",
                Some(session_id),
                Some(turn_id),
                Some(operation_id),
                json!({"status": status, "error": sanitize_diagnostic(message)}),
            );
        }
    }

    async fn handle_disconnect(&self, message: String) {
        let mut state = self.state.lock().await;
        if state.exited || state.stopping {
            return;
        }
        state.exited = true;
        state.gateway_ready = false;
        let active = std::mem::take(&mut state.active_turns);
        let operations = std::mem::take(&mut state.turn_operations);
        state.streamed_assistant.clear();
        state.approvals.clear();
        state.questions.clear();
        drop(state);
        self.reject_pending(gateway_error("runtime-exited", message.clone()))
            .await;
        for (session_id, turn_id) in active {
            self.emit(
                "turn.completed",
                Some(&session_id),
                Some(&turn_id),
                operations.get(&session_id).map(String::as_str),
                json!({"status": "unknown", "error": sanitize_diagnostic(&message)}),
            );
        }
        self.emit_status(&message, "unavailable", None, None);
    }

    async fn handle_process_exit(&self, status: std::io::Result<std::process::ExitStatus>) {
        let code = status
            .map(|status| {
                status
                    .code()
                    .map_or_else(|| "signal".into(), |value| value.to_string())
            })
            .unwrap_or_else(|error| error.to_string());
        let stderr = self.stderr.lock().await.clone();
        self.handle_disconnect(sanitize_diagnostic(format!(
            "Hermes Gateway exited with code {code}. {stderr}"
        )))
        .await;
    }

    async fn reject_pending(&self, error: CodexError) {
        let pending = std::mem::take(&mut *self.pending.lock().await);
        for (_, pending) in pending {
            let _ = pending.completion.send(Err(error.clone()));
        }
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

async fn wait_for_ready_port(lines: &mut Lines<BufReader<ChildStdout>>) -> Result<u16, CodexError> {
    while let Some(line) = lines
        .next_line()
        .await
        .map_err(|error| gateway_error("runtime-unavailable", error.to_string()))?
    {
        if let Some(port) = line
            .trim()
            .strip_prefix("HERMES_BACKEND_READY port=")
            .and_then(|value| value.parse::<u16>().ok())
        {
            return Ok(port);
        }
    }
    Err(gateway_error(
        "runtime-unavailable",
        "Hermes Gateway exited before announcing readiness.",
    ))
}

async fn drain_stdout(_inner: Weak<Inner>, mut lines: Lines<BufReader<ChildStdout>>) {
    while let Ok(Some(_)) = lines.next_line().await {}
}

async fn read_stderr(buffer: Arc<Mutex<String>>, stderr: tokio::process::ChildStderr) {
    let mut lines = BufReader::new(stderr).lines();
    while let Ok(Some(line)) = lines.next_line().await {
        let mut value = buffer.lock().await;
        value.push_str(&line);
        value.push('\n');
        if value.len() > 12_000 {
            let keep_from = value.len() - 12_000;
            *value = value[keep_from..].to_owned();
        }
    }
}

async fn read_socket(
    inner: Weak<Inner>,
    mut reader: futures_util::stream::SplitStream<GatewaySocket>,
) {
    while let Some(message) = reader.next().await {
        let Some(inner) = inner.upgrade() else { return };
        match message {
            Ok(Message::Text(text)) if text.len() <= MAX_FRAME_BYTES => {
                match serde_json::from_str::<Value>(text.as_str()) {
                    Ok(frame) => inner.handle_frame(frame).await,
                    Err(_) => inner.emit_status(
                        "Hermes Gateway emitted invalid JSON.",
                        "degraded",
                        None,
                        None,
                    ),
                }
            }
            Ok(Message::Binary(bytes)) if bytes.len() <= MAX_FRAME_BYTES => {
                match serde_json::from_slice::<Value>(&bytes) {
                    Ok(frame) => inner.handle_frame(frame).await,
                    Err(_) => inner.emit_status(
                        "Hermes Gateway emitted invalid JSON.",
                        "degraded",
                        None,
                        None,
                    ),
                }
            }
            Ok(Message::Ping(bytes)) => {
                let _ = inner.writer.lock().await.send(Message::Pong(bytes)).await;
            }
            Ok(Message::Close(_)) => {
                inner
                    .handle_disconnect(
                        "Hermes Gateway WebSocket closed. Accepted turns were not retried automatically."
                            .into(),
                    )
                    .await;
                return;
            }
            Err(error) => {
                inner
                    .handle_disconnect(format!("Hermes Gateway WebSocket failed: {error}"))
                    .await;
                return;
            }
            Ok(Message::Text(_) | Message::Binary(_)) => inner.emit_status(
                "Hermes Gateway emitted an oversized frame.",
                "degraded",
                None,
                None,
            ),
            _ => {}
        }
    }
    if let Some(inner) = inner.upgrade() {
        inner
            .handle_disconnect("Hermes Gateway WebSocket ended unexpectedly.".into())
            .await;
    }
}

async fn read_health(port: u16) -> Result<Value, CodexError> {
    read_http_json(port, "/api/health", None).await
}

async fn read_http_json(
    port: u16,
    path: &str,
    session_token: Option<&str>,
) -> Result<Value, CodexError> {
    let mut stream = timeout(REQUEST_TIMEOUT, TcpStream::connect(("127.0.0.1", port)))
        .await
        .map_err(|_| gateway_error("runtime-unavailable", "Hermes HTTP connection timed out."))?
        .map_err(|error| gateway_error("runtime-unavailable", error.to_string()))?;
    let authentication = session_token
        .map(|token| format!("X-Hermes-Session-Token: {token}\r\n"))
        .unwrap_or_default();
    stream
        .write_all(
            format!(
                "GET {path} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nConnection: close\r\nAccept: application/json\r\n{authentication}\r\n"
            )
            .as_bytes(),
        )
        .await
        .map_err(|error| gateway_error("runtime-unavailable", error.to_string()))?;
    let mut response = Vec::new();
    timeout(REQUEST_TIMEOUT, stream.read_to_end(&mut response))
        .await
        .map_err(|_| gateway_error("runtime-unavailable", "Hermes HTTP response timed out."))?
        .map_err(|error| gateway_error("runtime-unavailable", error.to_string()))?;
    let split = response
        .windows(4)
        .position(|window| window == b"\r\n\r\n")
        .ok_or_else(|| gateway_error("invalid-response", "Hermes HTTP response was malformed."))?;
    let headers = String::from_utf8_lossy(&response[..split]);
    if !headers
        .lines()
        .next()
        .is_some_and(|line| line.contains(" 200 "))
    {
        return Err(gateway_error(
            "runtime-unavailable",
            format!("Hermes Gateway returned a non-success response for {path}."),
        ));
    }
    serde_json::from_slice(&response[split + 4..])
        .map_err(|error| gateway_error("invalid-response", error.to_string()))
}

fn gateway_capabilities() -> Vec<String> {
    [
        "session.list.v1",
        "session.create.v1",
        "session.resume.v1",
        "history.read.v1",
        "turn.stream.v1",
        "turn.interrupt.v1",
        "input.image.v1",
        "model.select.v1",
        "reasoning.select.v1",
        "approval.resolve.v1",
        "question.resolve.v1",
    ]
    .into_iter()
    .map(str::to_owned)
    .collect()
}

fn models_for_ui(payload: &Value) -> Vec<Value> {
    payload
        .get("providers")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .flat_map(|provider| {
            let provider_id = provider
                .get("slug")
                .or_else(|| provider.get("id"))
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_owned();
            provider
                .get("models")
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default()
                .into_iter()
                .filter_map(move |model| {
                    let raw = model
                        .as_str()
                        .map(str::to_owned)
                        .or_else(|| {
                            model
                                .get("id")
                                .or_else(|| model.get("model"))
                                .or_else(|| model.get("slug"))
                                .and_then(Value::as_str)
                                .map(str::to_owned)
                        })?;
                    if provider_id.is_empty() || raw.is_empty() {
                        return None;
                    }
                    let id = format!("{provider_id}::{raw}");
                    Some(json!({
                        "id": id,
                        "model": id,
                        "rawModelId": raw,
                        "provider": provider_id,
                        "displayName": model.get("name").or_else(|| model.get("display_name")).and_then(Value::as_str).unwrap_or(&raw),
                        "hidden": false,
                        "supportedReasoningEfforts": [
                            {"reasoningEffort": "none"},
                            {"reasoningEffort": "low"},
                            {"reasoningEffort": "medium"},
                            {"reasoningEffort": "high"},
                            {"reasoningEffort": "max"}
                        ],
                        "defaultReasoningEffort": "medium"
                    }))
                })
        })
        .collect()
}

fn remember_history_item(
    histories: &mut HashMap<String, Vec<Value>>,
    session_id: &str,
    turn_id: &str,
    item: Value,
    before_id: Option<&str>,
) {
    let turns = histories.entry(session_id.into()).or_default();
    if !turns.iter().any(|turn| turn["id"] == turn_id) {
        turns.push(json!({"id":turn_id, "items":[]}));
    }
    let items = turns
        .iter_mut()
        .find(|turn| turn["id"] == turn_id)
        .and_then(|turn| turn["items"].as_array_mut())
        .expect("turn items");
    if let Some(existing) = items
        .iter_mut()
        .find(|existing| existing["id"] == item["id"] && existing["type"] == item["type"])
    {
        *existing = item;
    } else if let Some(index) =
        before_id.and_then(|id| items.iter().position(|existing| existing["id"] == id))
    {
        items.insert(index, item);
    } else {
        items.push(item);
    }
}

fn messages_to_turns(messages: &[Value]) -> Vec<Value> {
    let mut turns: Vec<Value> = Vec::new();
    for (index, message) in messages.iter().enumerate() {
        let role = message
            .get("role")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_ascii_lowercase();
        let text = message_text(message);
        let identity = message
            .get("row_id")
            .map(value_string_value)
            .unwrap_or_else(|| index.to_string());
        if role == "user" {
            turns.push(json!({
                "id": format!("hermes-turn-{identity}"),
                "items": [{"id": format!("hermes-user-{identity}"), "type": "userMessage", "content": [{"type": "text", "text": text}]}]
            }));
            continue;
        }
        if turns.is_empty() {
            turns.push(json!({"id": format!("hermes-turn-{identity}"), "items": []}));
        }
        let items = turns
            .last_mut()
            .and_then(|turn| turn.get_mut("items"))
            .and_then(Value::as_array_mut)
            .expect("turn items");
        if role == "assistant" {
            let reasoning = reasoning_text(message);
            if !reasoning.is_empty() {
                items.push(json!({"id":format!("hermes-thinking-{identity}"), "type":"reasoning", "status":"completed", "summary":[reasoning]}));
            }
            if !text.is_empty() {
                items.push(json!({"id":format!("hermes-agent-{identity}"), "type":"agentMessage", "phase":"final", "status":"completed", "text":text}));
            }
        } else if role == "tool" {
            // Gateway history includes the tool's name/context even when it
            // omits the potentially large result body.
            items.push(json!({"id":format!("hermes-tool-{identity}"), "type":"commandExecution", "status":"completed",
                "title":message.get("name").and_then(Value::as_str).unwrap_or("Tool"),
                "command":message.get("context").map(value_string_value).unwrap_or_default(), "aggregatedOutput":text}));
        } else if !text.is_empty() {
            items.push(json!({"id":format!("hermes-system-{identity}"), "type":"commandExecution", "title":"System", "status":"completed", "aggregatedOutput":text}));
        }
    }
    turns
}

fn reasoning_text(message: &Value) -> String {
    fn text(value: &Value) -> String {
        match value {
            Value::String(value) => value.clone(),
            Value::Array(parts) => parts
                .iter()
                .map(text)
                .filter(|value| !value.is_empty())
                .collect::<Vec<_>>()
                .join("\n"),
            Value::Object(parts) => ["text", "summary", "content"]
                .into_iter()
                .filter_map(|key| parts.get(key))
                .map(text)
                .find(|value| !value.is_empty())
                .unwrap_or_default(),
            _ => String::new(),
        }
    }
    [
        "reasoning_content",
        "reasoning",
        "reasoning_details",
        "codex_reasoning_items",
    ]
    .into_iter()
    .filter_map(|key| message.get(key))
    .map(text)
    .find(|value| !value.trim().is_empty())
    .unwrap_or_default()
}

fn message_text(message: &Value) -> String {
    if let Some(text) = message
        .get("text")
        .or_else(|| message.get("content"))
        .and_then(Value::as_str)
    {
        return text.into();
    }
    message
        .get("content")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|part| {
            part.as_str()
                .or_else(|| part.get("text").and_then(Value::as_str))
        })
        .collect::<Vec<_>>()
        .join("\n")
}

fn parse_image(value: &str) -> Result<(String, String), CodexError> {
    let value = value.strip_prefix("data:").ok_or_else(|| {
        gateway_error(
            "invalid-request",
            "Hermes accepts only base64 data URL images.",
        )
    })?;
    let (metadata, content) = value
        .split_once(',')
        .ok_or_else(|| gateway_error("invalid-request", "Hermes image data URL is malformed."))?;
    let mime = metadata.strip_suffix(";base64").ok_or_else(|| {
        gateway_error(
            "invalid-request",
            "Hermes accepts only base64 data URL images.",
        )
    })?;
    base64::engine::general_purpose::STANDARD
        .decode(
            content
                .bytes()
                .filter(|byte| !byte.is_ascii_whitespace())
                .collect::<Vec<_>>(),
        )
        .map_err(|_| gateway_error("invalid-request", "Hermes image base64 is invalid."))?;
    Ok((
        mime.into(),
        content
            .chars()
            .filter(|char| !char.is_whitespace())
            .collect(),
    ))
}

fn mime_extension(mime: &str) -> String {
    let subtype = mime.split('/').nth(1).unwrap_or("bin").to_ascii_lowercase();
    if subtype == "jpeg" {
        "jpg".into()
    } else {
        let filtered = subtype
            .chars()
            .filter(|character| character.is_ascii_alphanumeric())
            .collect::<String>();
        if filtered.is_empty() {
            "bin".into()
        } else {
            filtered
        }
    }
}

fn encode_model_id(provider: Option<&str>, model: Option<&str>) -> String {
    match (provider, model) {
        (Some(provider), Some(model)) if !provider.is_empty() && !model.is_empty() => {
            format!("{provider}::{model}")
        }
        (_, Some(model)) => model.into(),
        _ => String::new(),
    }
}

fn normalize_completion_status(status: Option<&str>) -> &'static str {
    match status.unwrap_or_default() {
        "complete" | "completed" | "success" | "done" => "completed",
        "cancelled" | "canceled" | "interrupted" => "interrupted",
        _ => "failed",
    }
}

fn approval_label(choice: &str) -> String {
    choice
        .split(['-', '_'])
        .map(|part| {
            let mut characters = part.chars();
            characters
                .next()
                .map(|first| first.to_ascii_uppercase().to_string() + characters.as_str())
                .unwrap_or_default()
        })
        .collect::<Vec<_>>()
        .join(" ")
}

fn prune_set(values: &mut HashSet<String>) {
    if values.len() > 1_024
        && let Some(value) = values.iter().next().cloned()
    {
        values.remove(&value);
    }
}

fn short_id(value: &str) -> &str {
    value.get(..value.len().min(12)).unwrap_or(value)
}

fn value_string(value: Option<&Value>) -> String {
    value.map(value_string_value).unwrap_or_default()
}

fn value_string_value(value: &Value) -> String {
    value
        .as_str()
        .map(str::to_owned)
        .unwrap_or_else(|| value.to_string())
}

fn gateway_error(code: impl Into<String>, message: impl Into<String>) -> CodexError {
    CodexError {
        code: code.into(),
        message: sanitize_diagnostic(message.into()),
        retryable: false,
    }
}

fn hermes_gateway_arguments(
    base: &[String],
    is_wsl: bool,
    session_token: &str,
) -> Result<Vec<String>, CodexError> {
    let mut arguments = base.to_vec();
    if !is_wsl {
        return Ok(arguments);
    }
    let direct_separator = arguments
        .iter()
        .position(|value| value == "-e")
        .filter(|index| index + 1 < arguments.len());
    let relay_separator = arguments
        .first()
        .is_some_and(|value| value == "--wsl-proxy")
        .then(|| arguments.iter().position(|value| value == "--"))
        .flatten()
        .filter(|index| index + 1 < arguments.len());
    let (separator, relay_wrapped) = direct_separator
        .map(|index| (index, false))
        .or_else(|| relay_separator.map(|index| (index, true)))
        .ok_or_else(|| {
            gateway_error(
                "invalid-configuration",
                "Invalid WSL Hermes Gateway launch vector.",
            )
        })?;
    let command_index = separator + 1;
    let token = format!("HERMES_DASHBOARD_SESSION_TOKEN={session_token}");
    if arguments
        .get(command_index)
        .is_some_and(|value| value.rsplit('/').next() == Some("env"))
    {
        let mut assignment_index = command_index + 1;
        while arguments
            .get(assignment_index)
            .is_some_and(|value| value == "-u" || value == "--unset")
            && arguments.get(assignment_index + 1).is_some()
        {
            assignment_index += 2;
        }
        arguments.insert(assignment_index, token);
    } else {
        arguments.splice(
            command_index..command_index,
            [
                if relay_wrapped {
                    "/usr/bin/env".to_owned()
                } else {
                    "env".to_owned()
                },
                token,
            ],
        );
    }
    Ok(arguments)
}

#[cfg(test)]
mod tests {
    use super::{PendingRequest, State, StreamedTurn, hermes_gateway_arguments};
    use serde_json::json;
    use tokio::sync::{Mutex, oneshot};

    #[tokio::test]
    async fn resume_binds_before_the_request_caller_wakes_and_preserves_live_history() {
        let mut initial = State::default();
        initial
            .runtime_session_ids
            .insert("runtime".into(), "away".into());
        initial
            .active_turns
            .insert("chat".into(), "live-turn".into());
        initial
            .streamed_assistant
            .insert("chat".into(), StreamedTurn::default());
        let live = vec![json!({"id":"live-turn", "items":[{"text":"First reasoning"}]})];
        initial.histories.insert("chat".into(), live.clone());
        let state = Mutex::new(initial);
        let (completion, receiver) = oneshot::channel();
        PendingRequest {
            method: "session.resume".into(),
            requested_session_id: Some("chat".into()),
            completion,
        }
        .complete(
            Ok(json!({"session_id":"runtime", "running":true, "messages":[]})),
            &state,
        )
        .await;

        // The socket reader can receive thinking.delta now, while the request
        // caller has not yet polled its result. Routing must already be ready.
        let bound = state.lock().await;
        let session = &bound.runtime_session_ids["runtime"];
        assert_eq!(session, "chat");
        assert_eq!(bound.active_turns[session], "live-turn");
        assert_eq!(bound.histories[session], live);
        drop(bound);
        assert!(receiver.await.expect("response delivered").is_ok());
    }

    #[tokio::test]
    async fn create_binds_before_completion_and_invalid_binding_returns_an_error() {
        let state = Mutex::new(State::default());
        for (response, expected_ok) in [
            (
                json!({"session_id":"runtime", "stored_session_id":"chat"}),
                true,
            ),
            (json!({"stored_session_id":"other"}), false),
        ] {
            let (completion, receiver) = oneshot::channel();
            PendingRequest {
                method: "session.create".into(),
                requested_session_id: None,
                completion,
            }
            .complete(Ok(response), &state)
            .await;
            assert_eq!(
                state.lock().await.active_session_id.as_deref(),
                Some("chat")
            );
            assert_eq!(
                receiver.await.expect("response delivered").is_ok(),
                expected_ok
            );
        }
    }

    #[test]
    fn wsl_launch_injects_dashboard_token_inside_the_distribution() {
        let base = [
            "-d",
            "Ubuntu",
            "--cd",
            "/home/u",
            "-e",
            "/home/u/bin/hermes",
            "serve",
            "--port",
            "0",
        ]
        .map(str::to_owned);
        assert_eq!(
            hermes_gateway_arguments(&base, true, "fixture-token").expect("WSL launch"),
            [
                "-d",
                "Ubuntu",
                "--cd",
                "/home/u",
                "-e",
                "env",
                "HERMES_DASHBOARD_SESSION_TOKEN=fixture-token",
                "/home/u/bin/hermes",
                "serve",
                "--port",
                "0",
            ]
        );
    }

    #[test]
    fn malformed_wsl_launch_is_rejected_before_spawn() {
        let error = hermes_gateway_arguments(&["-d".into(), "Ubuntu".into()], true, "token")
            .expect_err("missing WSL exec separator must fail");
        assert_eq!(error.code, "invalid-configuration");
    }

    #[test]
    fn wsl_launch_preserves_the_zommi_runtime_marker() {
        let base = [
            "-d",
            "Ubuntu",
            "-e",
            "env",
            "ZOMMI_RUNTIME_CHILD=1",
            "/home/u/bin/hermes",
            "serve",
        ]
        .map(str::to_owned);
        assert_eq!(
            hermes_gateway_arguments(&base, true, "fixture-token").expect("WSL launch"),
            [
                "-d",
                "Ubuntu",
                "-e",
                "env",
                "HERMES_DASHBOARD_SESSION_TOKEN=fixture-token",
                "ZOMMI_RUNTIME_CHILD=1",
                "/home/u/bin/hermes",
                "serve",
            ]
        );
    }

    #[test]
    fn persistent_relay_launch_injects_the_dashboard_token_after_env() {
        let base = [
            "--wsl-proxy",
            "--distribution",
            "Ubuntu",
            "--cwd",
            "/home/u",
            "--",
            "/usr/bin/env",
            "-u",
            "PARENT_APP_SESSION_ID",
            "ZOMMI_RUNTIME_CHILD=1",
            "/home/u/bin/hermes",
            "serve",
        ]
        .map(str::to_owned);
        assert_eq!(
            hermes_gateway_arguments(&base, true, "fixture-token").expect("relay launch"),
            [
                "--wsl-proxy",
                "--distribution",
                "Ubuntu",
                "--cwd",
                "/home/u",
                "--",
                "/usr/bin/env",
                "-u",
                "PARENT_APP_SESSION_ID",
                "HERMES_DASHBOARD_SESSION_TOKEN=fixture-token",
                "ZOMMI_RUNTIME_CHILD=1",
                "/home/u/bin/hermes",
                "serve",
            ]
        );
    }
}
