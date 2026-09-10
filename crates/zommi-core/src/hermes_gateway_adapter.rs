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
    time::{Duration, timeout},
};
use tokio_tungstenite::{MaybeTlsStream, WebSocketStream, connect_async, tungstenite::Message};
use uuid::Uuid;

use crate::{
    RuntimeCommand, RuntimeTarget, build_context_handoff,
    codex_adapter::{CodexError, CoreEvent, EventSender, TurnReceipt},
    sanitize_diagnostic, validate_turn_input,
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
    completion: oneshot::Sender<Result<Value, CodexError>>,
}

#[derive(Default)]
struct State {
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
    session_info: Value,
    active_turns: HashMap<String, String>,
    turn_operations: HashMap<String, String>,
    streamed_assistant: HashMap<String, String>,
    terminal_turns: HashSet<String>,
    approvals: HashMap<String, PendingApproval>,
    questions: HashMap<String, PendingQuestion>,
    stopping: bool,
    exited: bool,
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
        let sessions = self.load_sessions().await?;
        if let Some(session_id) = preferred_session_id
            && let Some(session) = sessions
                .iter()
                .find(|session| session.get("id").and_then(Value::as_str) == Some(&session_id))
        {
            self.resume_session(&session_id, session.get("profile").and_then(Value::as_str))
                .await?;
        } else {
            self.new_session(None, None, None, None).await?;
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

    pub async fn connection_value(&self) -> Result<Value, CodexError> {
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
        Ok(json!({
            "runtimeTargetId": self.inner.target.id,
            "sessionId": session_id,
            "protocolVersion": state.protocol_version,
            "runtimeVersion": state.runtime_version,
            "capabilities": state.capabilities,
            "models": state.models,
            "sessions": state.sessions,
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
    ) -> Result<Value, CodexError> {
        self.new_session(model, effort, cwd, profile).await?;
        self.load_sessions().await?;
        self.connection_value().await
    }

    pub async fn open_session(
        &self,
        session_id: &str,
        profile: Option<&str>,
    ) -> Result<Value, CodexError> {
        let sessions = self.load_sessions().await?;
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
            self.new_session(model, effort, cwd, profile).await?;
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
        let messages = state.histories.get(session_id).cloned().unwrap_or_default();
        Ok(json!({"thread": {"id": session_id, "turns": messages_to_turns(&messages)}}))
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
                .insert(request.session_id.into(), String::new());
            state
                .histories
                .entry(request.session_id.into())
                .or_default()
                .push(json!({"role": "user", "text": input.message}));
        }
        self.inner.emit(
            "turn.started",
            Some(request.session_id),
            Some(&turn_id),
            Some(request.client_operation_id),
            json!({"status": "inProgress"}),
        );
        let result = self
            .inner
            .request(
                "prompt.submit",
                json!({
                    "session_id": runtime_session_id,
                    "text": build_context_handoff(&input.message, &input.snapshots, input.images.len())
                }),
            )
            .await;
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
    ) -> Result<(), CodexError> {
        let selected = self.selected_model(model).await;
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
        let result = self.inner.request("session.create", params).await?;
        let session_id = value_string(
            result
                .get("stored_session_id")
                .or_else(|| result.get("session_key")),
        );
        self.bind_session(&result, &session_id).await
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
        let result = self.inner.request("session.resume", params).await?;
        let stored_id = result
            .get("session_key")
            .or_else(|| result.get("resumed"))
            .and_then(Value::as_str)
            .unwrap_or(session_id)
            .to_owned();
        self.bind_session(&result, &stored_id).await
    }

    async fn bind_session(&self, result: &Value, session_id: &str) -> Result<(), CodexError> {
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
        let mut state = self.inner.state.lock().await;
        state.active_session_id = Some(session_id.into());
        state.runtime_session_id = Some(runtime_session_id.into());
        state
            .runtime_session_ids
            .insert(runtime_session_id.into(), session_id.into());
        state.histories.insert(
            session_id.into(),
            result
                .get("messages")
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default(),
        );
        state.session_info = result.get("info").cloned().unwrap_or_else(|| json!({}));
        if result.get("running").and_then(Value::as_bool) == Some(true) {
            state
                .active_turns
                .insert(session_id.into(), format!("gateway-inflight-{session_id}"));
        }
        Ok(())
    }

    async fn refresh_models(&self) {
        let runtime_session_id = self
            .inner
            .state
            .lock()
            .await
            .runtime_session_id
            .clone()
            .unwrap_or_default();
        match self
            .inner
            .request("model.options", json!({"session_id": runtime_session_id}))
            .await
        {
            Ok(value) => self.inner.state.lock().await.models = models_for_ui(&value),
            Err(error) => {
                let mut state = self.inner.state.lock().await;
                state.models.clear();
                state.capabilities.retain(|capability| {
                    capability != "model.select.v1" && capability != "reasoning.select.v1"
                });
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

    async fn selected_model(&self, model: Option<&str>) -> Option<Value> {
        let model = model?;
        self.inner
            .state
            .lock()
            .await
            .models
            .iter()
            .find(|candidate| {
                candidate.get("id").and_then(Value::as_str) == Some(model)
                    || candidate.get("model").and_then(Value::as_str) == Some(model)
            })
            .cloned()
    }

    async fn apply_options(
        &self,
        model: Option<&str>,
        effort: Option<&str>,
    ) -> Result<(), CodexError> {
        let selected = self.selected_model(model).await;
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
        if let Some(selected) = selected
            && selected.get("id").and_then(Value::as_str) != Some(&current_model)
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
            let _ = pending.completion.send(result);
            return;
        }
        if frame.get("method").and_then(Value::as_str) == Some("event") {
            self.handle_event(frame.get("params").unwrap_or(&Value::Null))
                .await;
        }
    }

    async fn handle_event(&self, event: &Value) {
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
                    state.streamed_assistant.insert(session_id, String::new());
                }
            }
            "message.delta" | "message.interim" => {
                let Some(turn_id) = turn_id else { return };
                let text = payload
                    .get("text")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_owned();
                state
                    .streamed_assistant
                    .entry(session_id.clone())
                    .or_default()
                    .push_str(&text);
                drop(state);
                self.emit(
                    "item.update",
                    Some(&session_id),
                    Some(&turn_id),
                    operation.as_deref(),
                    json!({"kind": "assistant", "lifecycle": "delta", "title": "Hermes", "text": text, "itemId": format!("{turn_id}-assistant")}),
                );
            }
            "reasoning.delta" | "thinking.delta" | "reasoning.available" => {
                let Some(turn_id) = turn_id else { return };
                let text = payload
                    .get("text")
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                drop(state);
                self.emit(
                    "item.update",
                    Some(&session_id),
                    Some(&turn_id),
                    operation.as_deref(),
                    json!({"kind": "thinking", "lifecycle": "delta", "title": "Thinking", "text": text, "itemId": format!("{turn_id}-thinking")}),
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
                    .map(value_string_value)
                    .unwrap_or_else(|| payload.to_string());
                let item_id = payload
                    .get("tool_id")
                    .and_then(Value::as_str)
                    .map(str::to_owned)
                    .unwrap_or_else(|| format!("{turn_id}-tool"));
                drop(state);
                self.emit(
                    "item.update",
                    Some(&session_id),
                    Some(&turn_id),
                    operation.as_deref(),
                    json!({"kind": if lifecycle == "delta" { "toolOutput" } else { "tool" }, "lifecycle": lifecycle, "title": title, "text": text, "itemId": item_id}),
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
                self.emit(
                    "approval.requested",
                    Some(&session_id),
                    turn_id.as_deref(),
                    operation.as_deref(),
                    json!({
                        "approvalId": approval_id,
                        "options": choices.iter().map(|choice| json!({
                            "optionId": choice,
                            "name": approval_label(choice),
                            "kind": if choice == "deny" { "reject" } else { "allow_once" }
                        })).collect::<Vec<_>>(),
                        "toolCall": {"title": payload.get("description").or_else(|| payload.get("reason")).and_then(Value::as_str).unwrap_or("Hermes command"), "rawInput": payload}
                    }),
                );
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
                let streamed = state
                    .streamed_assistant
                    .remove(&session_id)
                    .unwrap_or_default();
                state.active_turns.remove(&session_id);
                state.turn_operations.remove(&session_id);
                state
                    .terminal_turns
                    .insert(format!("{session_id}:{turn_id}"));
                state
                    .histories
                    .entry(session_id.clone())
                    .or_default()
                    .push(json!({
                        "role": "assistant",
                        "text": final_text,
                        "reasoning": payload.get("reasoning")
                    }));
                prune_set(&mut state.terminal_turns);
                let suffix = if streamed.is_empty() {
                    final_text.clone()
                } else {
                    final_text
                        .strip_prefix(&streamed)
                        .unwrap_or_default()
                        .to_owned()
                };
                let status =
                    normalize_completion_status(payload.get("status").and_then(Value::as_str));
                let error = payload.get("error").cloned();
                drop(state);
                if !suffix.is_empty() {
                    self.emit(
                        "item.update",
                        Some(&session_id),
                        Some(&turn_id),
                        operation.as_deref(),
                        json!({"kind": "assistant", "lifecycle": "completed", "title": "Hermes", "text": suffix, "itemId": format!("{turn_id}-assistant")}),
                    );
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

fn messages_to_turns(messages: &[Value]) -> Vec<Value> {
    let mut turns: Vec<Value> = Vec::new();
    for (index, message) in messages.iter().enumerate() {
        let role = message
            .get("role")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_ascii_lowercase();
        let text = message_text(message);
        if role == "user" {
            turns.push(json!({
                "id": format!("hermes-turn-{index}"),
                "items": [{"id": format!("hermes-user-{index}"), "type": "userMessage", "content": [{"type": "text", "text": text}]}]
            }));
            continue;
        }
        if turns.is_empty() {
            turns.push(json!({"id": format!("hermes-turn-{index}"), "items": []}));
        }
        let items = turns
            .last_mut()
            .and_then(|turn| turn.get_mut("items"))
            .and_then(Value::as_array_mut)
            .expect("turn items");
        if role == "assistant" {
            if let Some(reasoning) = message.get("reasoning").and_then(Value::as_str)
                && !reasoning.is_empty()
            {
                items.push(json!({"id": format!("hermes-thinking-{index}"), "type": "reasoning", "status": "completed", "summary": [reasoning], "content": []}));
            }
            if !text.is_empty() {
                items.push(json!({"id": format!("hermes-agent-{index}"), "type": "agentMessage", "phase": "final", "status": "completed", "text": text}));
            }
        } else if !text.is_empty() {
            items.push(json!({"id": format!("hermes-tool-{index}"), "type": "commandExecution", "status": "completed", "title": message.get("name").and_then(Value::as_str).unwrap_or("Tool"), "text": text}));
        }
    }
    turns
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
    use super::hermes_gateway_arguments;

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
