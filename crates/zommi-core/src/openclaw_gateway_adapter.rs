use std::{
    collections::{HashMap, HashSet},
    env,
    sync::{
        Arc, Weak,
        atomic::{AtomicU64, Ordering},
    },
};

use base64::Engine as _;
use futures_util::{SinkExt, StreamExt, stream::SplitSink};
use serde_json::{Value, json};
use tokio::{
    net::TcpStream,
    sync::{Mutex, oneshot},
    task::JoinHandle,
    time::{Duration, timeout},
};
use tokio_tungstenite::{MaybeTlsStream, WebSocketStream, connect_async, tungstenite::Message};
use uuid::Uuid;

use crate::{
    RuntimeTarget, build_context_handoff,
    codex_adapter::{CodexError, CoreEvent, EventSender, TurnReceipt},
    openclaw_device_identity::DeviceIdentity,
    sanitize_diagnostic, validate_turn_input,
};

const PROTOCOL_VERSION: u64 = 4;
const REQUEST_TIMEOUT: Duration = Duration::from_secs(30);
const MAX_FRAME_BYTES: usize = 50 * 1024 * 1024;

type GatewaySocket = WebSocketStream<MaybeTlsStream<TcpStream>>;
type GatewayWriter = SplitSink<GatewaySocket, Message>;

#[derive(Debug, Clone)]
pub struct OpenClawGatewayConfig {
    pub target: RuntimeTarget,
    pub preferred_session_id: Option<String>,
    pub list_only: bool,
}

pub struct OpenClawGatewayTurnRequest<'a> {
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
pub struct OpenClawGatewayAdapter {
    inner: Arc<Inner>,
}

struct Inner {
    target: RuntimeTarget,
    agent_id: Option<String>,
    writer: Mutex<GatewayWriter>,
    event_gate: Mutex<()>,
    pending: Mutex<HashMap<String, PendingRequest>>,
    state: Mutex<State>,
    next_request_id: AtomicU64,
    next_event_sequence: AtomicU64,
    event_tx: EventSender,
    socket_task: Mutex<Option<JoinHandle<()>>>,
}

struct PendingRequest {
    method: String,
    completion: oneshot::Sender<Result<Value, CodexError>>,
}

#[derive(Default)]
struct State {
    command_catalogs: HashMap<String, Vec<Value>>,
    protocol_version: u64,
    runtime_version: Option<String>,
    capabilities: Vec<String>,
    methods: HashSet<String>,
    scopes: HashSet<String>,
    active_session_id: Option<String>,
    subscribed_session_id: Option<String>,
    sessions: Vec<Value>,
    histories: HashMap<String, Vec<Value>>,
    models: Vec<Value>,
    active_turns: HashMap<String, String>,
    pending_starts: HashMap<String, String>,
    deferred_events: HashMap<String, Vec<(String, Value)>>,
    turn_operations: HashMap<String, String>,
    streamed_text: HashMap<String, String>,
    run_sequences: HashMap<String, i64>,
    terminal_runs: HashSet<String>,
    approvals: HashMap<String, PendingApproval>,
    questions: HashMap<String, PendingQuestion>,
    stopping: bool,
    exited: bool,
}

#[derive(Clone)]
struct PendingApproval {
    session_id: String,
    kind: String,
}

#[derive(Clone)]
struct PendingQuestion {
    session_id: String,
    questions: Vec<Value>,
}

struct ConnectChallenge {
    nonce: String,
    signed_at: u64,
}

impl OpenClawGatewayAdapter {
    pub async fn connect(
        config: OpenClawGatewayConfig,
        event_tx: EventSender,
    ) -> Result<Self, CodexError> {
        let endpoint = config.target.endpoint.clone().ok_or_else(|| {
            gateway_error(
                "invalid-configuration",
                "OpenClaw Gateway endpoint is missing.",
            )
        })?;
        validate_endpoint(&endpoint)?;
        let (mut socket, _) = timeout(REQUEST_TIMEOUT, connect_async(&endpoint))
            .await
            .map_err(|_| {
                gateway_error(
                    "runtime-unavailable",
                    "OpenClaw Gateway connection timed out.",
                )
            })?
            .map_err(|error| {
                gateway_error(
                    "runtime-unavailable",
                    format!("OpenClaw Gateway connection failed: {error}"),
                )
            })?;
        let challenge = timeout(REQUEST_TIMEOUT, read_challenge(&mut socket))
            .await
            .map_err(|_| {
                gateway_error(
                    "runtime-unavailable",
                    "OpenClaw Gateway did not send a connect challenge.",
                )
            })??;
        let mut identity = DeviceIdentity::load_or_create().map_err(|error| {
            gateway_error(
                "persistence-failed",
                format!("Could not load OpenClaw device identity: {error}"),
            )
        })?;
        let request_id = "zommi-connect-1";
        let requested_scopes = vec![
            "operator.read".to_owned(),
            "operator.write".to_owned(),
            // Gateway classifies in-place history rewind as an admin mutation.
            "operator.admin".to_owned(),
            "operator.approvals".to_owned(),
            "operator.questions".to_owned(),
        ];
        let mut params = json!({
            "minProtocol": PROTOCOL_VERSION,
            "maxProtocol": PROTOCOL_VERSION,
            "client": {
                "id": "cli",
                "displayName": "Zommi",
                "version": env!("CARGO_PKG_VERSION"),
                "platform": env::consts::OS,
                "mode": "cli"
            },
            "caps": ["approvals", "tool-events", "session-scoped-events"],
            "role": "operator",
            "scopes": requested_scopes
        });
        let token = env::var("OPENCLAW_GATEWAY_TOKEN")
            .ok()
            .filter(|value| !value.trim().is_empty());
        let password = env::var("OPENCLAW_GATEWAY_PASSWORD")
            .ok()
            .filter(|value| !value.trim().is_empty());
        let stored_token = identity.stored_device_token().map(str::to_owned);
        let signature_token = token.as_deref().or(stored_token.as_deref());
        let connect_scopes = if token.is_none()
            && password.is_none()
            && stored_token.is_some()
            && !identity.stored_scopes().is_empty()
        {
            identity.stored_scopes().to_vec()
        } else {
            requested_scopes.clone()
        };
        params["scopes"] = json!(connect_scopes);
        if token.is_some() || password.is_some() || stored_token.is_some() {
            let mut auth = serde_json::Map::new();
            if let Some(token) = &token {
                auth.insert("token".into(), Value::String(token.clone()));
            } else if let Some(device_token) = &stored_token {
                auth.insert("token".into(), Value::String(device_token.clone()));
                auth.insert("deviceToken".into(), Value::String(device_token.clone()));
            }
            if let Some(password) = &password {
                auth.insert("password".into(), Value::String(password.clone()));
            }
            params["auth"] = Value::Object(auth);
        }
        params["device"] = identity.connect_device(
            &challenge.nonce,
            challenge.signed_at,
            &connect_scopes,
            signature_token,
            env::consts::OS,
        );
        let connect = json!({
            "type": "req",
            "id": request_id,
            "method": "connect",
            "params": params
        });
        socket
            .send(Message::Text(connect.to_string().into()))
            .await
            .map_err(|error| gateway_error("runtime-unavailable", error.to_string()))?;
        let hello = timeout(
            REQUEST_TIMEOUT,
            read_connect_response(&mut socket, request_id),
        )
        .await
        .map_err(|_| {
            gateway_error(
                "runtime-unavailable",
                "OpenClaw Gateway challenge handshake timed out.",
            )
        })??;
        let protocol_version = hello
            .get("protocol")
            .or_else(|| hello.get("protocolVersion"))
            .and_then(Value::as_u64)
            .unwrap_or_default();
        if protocol_version != PROTOCOL_VERSION {
            return Err(gateway_error(
                "unsupported-version",
                format!("Unsupported OpenClaw Gateway protocol version {protocol_version}."),
            ));
        }
        let methods = hello
            .pointer("/features/methods")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
            .map(str::to_owned)
            .collect::<HashSet<_>>();
        for required in [
            "sessions.list",
            "sessions.create",
            "sessions.messages.subscribe",
            "chat.history",
            "chat.send",
        ] {
            if !methods.is_empty() && !methods.contains(required) {
                return Err(gateway_error(
                    "capability-unavailable",
                    format!("OpenClaw Gateway does not advertise required method '{required}'."),
                ));
            }
        }
        let scopes = hello
            .pointer("/auth/scopes")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
            .map(str::to_owned)
            .collect::<HashSet<_>>();
        if let Some(device_token) = hello.pointer("/auth/deviceToken").and_then(Value::as_str) {
            let granted_scopes = scopes.iter().cloned().collect::<Vec<_>>();
            identity
                .store_device_token(device_token, &granted_scopes)
                .map_err(|error| {
                    gateway_error(
                        "persistence-failed",
                        format!("Could not persist OpenClaw device authorization: {error}"),
                    )
                })?;
        }
        let capabilities = negotiated_capabilities(&methods, &scopes);
        let runtime_version = hello
            .pointer("/server/version")
            .and_then(Value::as_str)
            .map(str::to_owned);
        let (writer, reader) = socket.split();
        let adapter = Self {
            inner: Arc::new(Inner {
                agent_id: config.target.profile_id.clone(),
                target: config.target,
                writer: Mutex::new(writer),
                event_gate: Mutex::new(()),
                pending: Mutex::new(HashMap::new()),
                state: Mutex::new(State {
                    protocol_version,
                    runtime_version,
                    capabilities,
                    methods,
                    scopes,
                    ..State::default()
                }),
                next_request_id: AtomicU64::new(1),
                next_event_sequence: AtomicU64::new(0),
                event_tx,
                socket_task: Mutex::new(None),
            }),
        };
        adapter
            .inner
            .emit_status("Connecting to OpenClaw Gateway…", "connecting", None, None);
        let weak = Arc::downgrade(&adapter.inner);
        *adapter.inner.socket_task.lock().await = Some(tokio::spawn(async move {
            read_socket(weak, reader).await;
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
        if list_only {
            return Ok(());
        }
        self.activate(preferred_session_id).await
    }

    pub async fn activate(&self, preferred_session_id: Option<String>) -> Result<(), CodexError> {
        self.load_sessions().await?;
        self.refresh_models().await;
        // A saved exact binding can be outside the current catalog page or
        // filter. Reopen it directly instead of creating a replacement chat.
        if let Some(session_id) = preferred_session_id {
            self.bind_session(&session_id).await?;
        } else {
            self.new_session(None, None).await?;
            self.load_sessions().await?;
        }
        let session_id = self.active_session_id().await?;
        self.inner.emit_status(
            &format!("OpenClaw Gateway ready · {}", short_id(&session_id)),
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
            .ok_or_else(|| {
                gateway_error("runtime-failed", "OpenClaw Gateway has no active session.")
            })
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
        let state = self.inner.state.lock().await;
        if !state.methods.contains("commands.list") {
            return Err(crate::command_catalog::error(
                "This OpenClaw version does not advertise command discovery.",
            ));
        }
        let agent_id = session_id
            .strip_prefix("agent:")
            .and_then(|s| s.split(':').next())
            .unwrap_or("main")
            .to_owned();
        drop(state);
        let response = self
            .inner
            .request(
                "commands.list",
                json!({"agentId":agent_id,"scope":"text", "includeArgs":true}),
            )
            .await?;
        let commands = crate::command_catalog::normalize(
            response
                .get("commands")
                .and_then(Value::as_array)
                .ok_or_else(|| {
                    crate::command_catalog::error("OpenClaw did not return a command catalog.")
                })?,
        );
        let commands = crate::command_catalog::with_client_limits(commands);
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
        let session_id = state.active_session_id.clone().ok_or_else(|| {
            gateway_error("runtime-failed", "OpenClaw Gateway has no active session.")
        })?;
        Ok(json!({
            "runtimeTargetId": self.inner.target.id,
            "sessionId": session_id,
            "protocolVersion": state.protocol_version,
            "runtimeVersion": state.runtime_version,
            "capabilities": state.capabilities,
            "models": state.models,
            "sessions": state.sessions,
            "history": {"thread": {"id": session_id, "turns": messages_to_turns(state.histories.get(&session_id).map(Vec::as_slice).unwrap_or_default())}},
            "sessionMetadata": {"sessionKey": session_id}
        }))
    }

    pub async fn list_sessions(&self) -> Result<Vec<Value>, CodexError> {
        self.load_sessions().await
    }

    pub async fn create_session(
        &self,
        model: Option<&str>,
        effort: Option<&str>,
    ) -> Result<Value, CodexError> {
        self.new_session(model, effort).await?;
        self.load_sessions().await?;
        self.connection_value().await
    }

    pub async fn open_session(&self, session_id: &str) -> Result<Value, CodexError> {
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
                format!("OpenClaw session '{session_id}' was not returned by this Gateway."),
            ));
        }
        self.bind_session(session_id).await?;
        self.connection_value().await
    }

    pub async fn read_session(&self, session_id: &str) -> Result<Value, CodexError> {
        let needs_refresh = !self
            .inner
            .state
            .lock()
            .await
            .histories
            .contains_key(session_id);
        if needs_refresh {
            self.load_history(session_id).await?;
        }
        let state = self.inner.state.lock().await;
        let messages = state.histories.get(session_id).cloned().unwrap_or_default();
        Ok(json!({"thread": {"id": session_id, "turns": messages_to_turns(&messages)}}))
    }

    pub async fn prepare_rewind(&self, session_id: &str) -> Result<Value, CodexError> {
        let state = self.inner.state.lock().await;
        if state.active_session_id.as_deref() != Some(session_id) {
            return Err(gateway_error(
                "identity-mismatch",
                "The requested OpenClaw chat is not active.",
            ));
        }
        if !state
            .capabilities
            .iter()
            .any(|capability| capability == "session.rewind.v1")
        {
            return Err(gateway_error(
                "capability-unavailable",
                "This Gateway connection does not advertise rewind.",
            ));
        }
        if state.active_turns.contains_key(session_id)
            || state.pending_starts.contains_key(session_id)
        {
            return Err(gateway_error(
                "session-busy",
                "Stop OpenClaw before editing an earlier message.",
            ));
        }
        drop(state);
        let mut messages = Vec::new();
        let mut offset = 0;
        for _ in 0..100 {
            let mut params =
                json!({"sessionKey":session_id,"limit":200,"maxChars":500_000,"offset":offset});
            if let Some(agent) = &self.inner.agent_id {
                params["agentId"] = json!(agent);
            }
            let page = self.inner.request("chat.history", params).await?;
            if page
                .pointer("/sessionInfo/hasActiveRun")
                .and_then(Value::as_bool)
                == Some(true)
            {
                return Err(gateway_error(
                    "session-busy",
                    "OpenClaw is still responding.",
                ));
            }
            let mut older = page["messages"].as_array().cloned().ok_or_else(|| {
                crate::session_rewind::error("OpenClaw did not return chat history.")
            })?;
            older.append(&mut messages);
            messages = older;
            if page["hasMore"] != true {
                if messages
                    .iter()
                    .filter(|message| message["role"] == "user")
                    .any(|message| native_entry_id(message).is_none())
                {
                    return Err(crate::session_rewind::error(
                        "OpenClaw did not expose durable message entry IDs.",
                    ));
                }
                return Ok(
                    json!({"thread":{"id":session_id,"turns":messages_to_turns(&messages)}}),
                );
            }
            let next = page["nextOffset"]
                .as_u64()
                .filter(|next| *next > offset)
                .ok_or_else(|| {
                    crate::session_rewind::error("OpenClaw returned incomplete history pagination.")
                })?;
            offset = next;
        }
        Err(crate::session_rewind::error(
            "OpenClaw history exceeded the rewind inspection limit.",
        ))
    }

    pub async fn rewind_session(
        &self,
        session_id: &str,
        turn_id: &str,
        last_id: &str,
    ) -> Result<Value, CodexError> {
        let before = self.prepare_rewind(session_id).await?;
        let index = crate::session_rewind::target(&before, turn_id, last_id)?;
        let entry_id = turn_id.strip_prefix("openclaw-turn-").ok_or_else(|| {
            crate::session_rewind::error("The message has no OpenClaw entry identity.")
        })?;
        let mut params = json!({"sessionKey":session_id,"entryId":entry_id});
        if let Some(agent) = &self.inner.agent_id {
            params["agentId"] = json!(agent);
        }
        self.inner
            .request("sessions.rewind", params)
            .await
            .map_err(|mut error| {
                error.retryable = false;
                error
            })?;
        let after = self.prepare_rewind(session_id).await?;
        crate::session_rewind::verify_prefix(&before, &after, index)?;
        // Invalidate the pre-rewind display projection as well as native history.
        self.inner.state.lock().await.histories.remove(session_id);
        Ok(after)
    }

    pub async fn start_turn(
        &self,
        request: OpenClawGatewayTurnRequest<'_>,
    ) -> Result<TurnReceipt, CodexError> {
        let input = validate_turn_input(request.message, request.snapshots, request.images)?;
        if self.active_session_id().await? != request.session_id {
            return Err(gateway_error(
                "identity-mismatch",
                "The requested session is not the exact active OpenClaw Gateway session.",
            ));
        }
        let selected_model = self.selected_model(request.model).await;
        if let Some(selected) = &selected_model {
            let active_model = self.active_model_id().await;
            if selected.get("id").and_then(Value::as_str) != Some(active_model.as_str()) {
                return Err(gateway_error(
                    "conflict",
                    "OpenClaw changes models when a session is created. Start a new chat with the selected model.",
                ));
            }
        }
        let attachments = input
            .images
            .iter()
            .enumerate()
            .map(|(index, image)| openclaw_attachment(image, index))
            .collect::<Result<Vec<_>, _>>()?;
        {
            let mut state = self.inner.state.lock().await;
            if state.active_turns.contains_key(request.session_id)
                || state.pending_starts.contains_key(request.session_id)
            {
                return Err(gateway_error(
                    "session-busy",
                    "This OpenClaw Gateway session already has an active turn.",
                ));
            }
            state.pending_starts.insert(
                request.session_id.into(),
                request.client_operation_id.into(),
            );
            state
                .histories
                .entry(request.session_id.into())
                .or_default()
                .push(
                    json!({"role": "user", "content": [{"type": "text", "text": input.message}]}),
                );
        }
        let mut params = json!({
            "sessionKey": request.session_id,
            "message": if request.slash_command { input.message.clone() } else { build_context_handoff(&input.message, &input.snapshots, input.images.len()) },
            "idempotencyKey": request.client_operation_id
        });
        if !attachments.is_empty() {
            params["attachments"] = Value::Array(attachments);
        }
        if let Some(effort) = request.effort {
            params["thinking"] = Value::String(effort.into());
        }
        let result = self.inner.request("chat.send", params).await;
        let result = match result {
            Ok(result) => result,
            Err(error) => {
                self.inner
                    .clear_pending_start(request.session_id, error.code != "unknown-outcome")
                    .await;
                return Err(error);
            }
        };
        // Some Gateway controls (for example /stop) acknowledge synchronously
        // without creating a run. Do not leave a pending start or claim failure.
        if request.slash_command && result.get("runId").is_none() && result["ok"] == true {
            let turn_id = Uuid::new_v4().to_string();
            let output = result
                .get("output")
                .or_else(|| result.get("message"))
                .and_then(Value::as_str)
                .unwrap_or("Command completed.");
            let mut state = self.inner.state.lock().await;
            state.pending_starts.remove(request.session_id);
            state
                .histories
                .entry(request.session_id.into())
                .or_default()
                .push(json!({"role":"assistant", "content":[{"type":"text", "text":output}]}));
            drop(state);
            self.inner.emit(
                "turn.started",
                Some(request.session_id),
                Some(&turn_id),
                Some(request.client_operation_id),
                json!({"status":"inProgress"}),
            );
            self.inner.emit("item.update", Some(request.session_id), Some(&turn_id), Some(request.client_operation_id), json!({"kind":"assistant", "lifecycle":"completed", "text":output, "itemId":format!("{turn_id}-command")}));
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
        let run_id = result
            .get("runId")
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
            .map(str::to_owned);
        let Some(run_id) = run_id else {
            self.inner
                .clear_pending_start(request.session_id, true)
                .await;
            return Err(gateway_error(
                "invalid-response",
                "OpenClaw did not return a run id.",
            ));
        };
        let status = result
            .get("status")
            .and_then(Value::as_str)
            .unwrap_or("started");
        if !matches!(status, "started" | "queued" | "steered" | "accepted") {
            self.inner
                .clear_pending_start(request.session_id, true)
                .await;
            return Err(gateway_error(
                "invalid-response",
                format!("OpenClaw did not acknowledge the run ({status})."),
            ));
        }
        {
            let _event_gate = self.inner.event_gate.lock().await;
            let mut state = self.inner.state.lock().await;
            state.pending_starts.remove(request.session_id);
            let key = format!("{}:{run_id}", request.session_id);
            if !state.terminal_runs.contains(&key) {
                state
                    .active_turns
                    .insert(request.session_id.into(), run_id.clone());
                state.turn_operations.insert(
                    request.session_id.into(),
                    request.client_operation_id.into(),
                );
                state.streamed_text.entry(run_id.clone()).or_default();
            }
            let deferred = state
                .deferred_events
                .remove(request.session_id)
                .unwrap_or_default();
            drop(state);
            self.inner.emit(
                "turn.started",
                Some(request.session_id),
                Some(&run_id),
                Some(request.client_operation_id),
                json!({"status": "inProgress"}),
            );
            for (name, payload) in deferred {
                self.inner.dispatch_event(&name, &payload).await;
            }
        }
        Ok(TurnReceipt {
            accepted: true,
            runtime_target_id: self.inner.target.id.clone(),
            session_id: request.session_id.into(),
            turn_id: run_id,
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
                "The requested run is not the exact active OpenClaw Gateway run.",
            ));
        }
        if !state.methods.is_empty() && !state.methods.contains("chat.abort") {
            return Err(gateway_error(
                "capability-unavailable",
                "OpenClaw Gateway does not advertise chat.abort.",
            ));
        }
        let operation = state.turn_operations.get(session_id).cloned();
        drop(state);
        self.inner
            .request(
                "chat.abort",
                json!({"sessionKey": session_id, "runId": turn_id}),
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
                    format!("Unknown OpenClaw approval '{approval_id}'."),
                )
            })?;
        if pending.session_id != session_id {
            return Err(gateway_error(
                "identity-mismatch",
                "The approval does not belong to the requested OpenClaw session.",
            ));
        }
        let decision = match option_id {
            Some("allow-always") => "allow-always",
            Some("allow-once") => "allow-once",
            _ => "deny",
        };
        let result = self
            .inner
            .request(
                "approval.resolve",
                json!({"id": approval_id, "kind": pending.kind, "decision": decision}),
            )
            .await?;
        self.inner.state.lock().await.approvals.remove(approval_id);
        Ok(json!({"resolved": true, "approvalId": approval_id, "result": result}))
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
                    format!("Unknown OpenClaw question '{question_id}'."),
                )
            })?;
        if pending.session_id != session_id {
            return Err(gateway_error(
                "identity-mismatch",
                "The question does not belong to the requested OpenClaw session.",
            ));
        }
        let params = if answer.as_object().is_some_and(|object| !object.is_empty()) {
            let answers = answer.get("answers").cloned().unwrap_or_else(|| {
                let first = pending
                    .questions
                    .first()
                    .and_then(|question| question.get("questionId"))
                    .and_then(Value::as_str)
                    .unwrap_or("answer");
                json!({first: [answer.get("value").and_then(Value::as_str).unwrap_or_default()]})
            });
            json!({"id": question_id, "answers": {"answers": answers}, "resolvedBy": "zommi"})
        } else {
            json!({"id": question_id, "cancel": true, "resolvedBy": "zommi"})
        };
        let result = self.inner.request("question.resolve", params).await?;
        self.inner.state.lock().await.questions.remove(question_id);
        Ok(json!({"resolved": true, "questionId": question_id, "result": result}))
    }

    pub async fn shutdown(&self) {
        self.inner.state.lock().await.stopping = true;
        let _ = self.inner.writer.lock().await.close().await;
        if let Some(task) = self.inner.socket_task.lock().await.take() {
            task.abort();
        }
        self.inner
            .reject_pending(gateway_error(
                "runtime-stopped",
                "OpenClaw Gateway stopped.",
            ))
            .await;
    }

    async fn load_sessions(&self) -> Result<Vec<Value>, CodexError> {
        let result = self
            .inner
            .request(
                "sessions.list",
                json!({
                    "limit": 200,
                    "includeDerivedTitles": true,
                    "includeLastMessage": true,
                    "boardFace": "chat"
                }),
            )
            .await?;
        let mut sessions = result
            .get("sessions")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(|session| {
                let id = session.get("key")?.as_str()?;
                if id.is_empty() {
                    return None;
                }
                Some(json!({
                    "id": id,
                    "name": session.get("displayName").or_else(|| session.get("derivedTitle")).or_else(|| session.get("label")),
                    "preview": session.get("lastMessagePreview").or_else(|| session.get("derivedTitle")).or_else(|| session.get("label")).and_then(Value::as_str).unwrap_or("OpenClaw session"),
                    "updatedAt": session.get("updatedAt").or_else(|| session.get("lastActivityAt")).and_then(Value::as_i64).unwrap_or_default(),
                    "model": session.get("model"),
                    "modelProvider": session.get("modelProvider"),
                    "status": session.get("status"),
                    "lastRunId": session.get("lastRunId")
                }))
            })
            .collect::<Vec<_>>();
        let current = self.inner.state.lock().await.active_session_id.clone();
        if let Some(current) = current
            && !sessions
                .iter()
                .any(|session| session.get("id").and_then(Value::as_str) == Some(&current))
        {
            sessions.insert(0, json!({"id": current, "preview": "New OpenClaw chat"}));
        }
        self.inner.state.lock().await.sessions = sessions.clone();
        Ok(sessions)
    }

    pub async fn reload_models(&self) -> Result<Vec<Value>, CodexError> {
        let result = self
            .inner
            .request(
                "models.list",
                json!({"view": "configured", "includeProviderCapabilities": true}),
            )
            .await?;
        let models = models_for_ui(result.get("models").unwrap_or(&Value::Null));
        self.inner.state.lock().await.models = models.clone();
        Ok(models)
    }

    async fn refresh_models(&self) {
        match self
            .inner
            .request(
                "models.list",
                json!({"view": "configured", "includeProviderCapabilities": true}),
            )
            .await
        {
            Ok(result) => {
                self.inner.state.lock().await.models =
                    models_for_ui(result.get("models").unwrap_or(&Value::Null));
            }
            Err(error) => {
                let mut state = self.inner.state.lock().await;
                state.models.clear();
                state
                    .capabilities
                    .retain(|capability| capability != "model.select.v1");
                drop(state);
                self.inner.emit_status(
                    &format!("OpenClaw model inventory unavailable: {}", error.message),
                    "degraded",
                    None,
                    None,
                );
            }
        }
    }

    async fn new_session(
        &self,
        model: Option<&str>,
        effort: Option<&str>,
    ) -> Result<(), CodexError> {
        let selected = self.selected_model(model).await;
        let mut params = json!({
            "label": format!("Zommi chat {}", &Uuid::new_v4().to_string()[..8])
        });
        if let Some(agent_id) = &self.inner.agent_id {
            params["agentId"] = Value::String(agent_id.clone());
        }
        if let Some(selected) = selected
            && let Some(model) = selected.get("rawModelId")
        {
            params["model"] = model.clone();
        }
        if let Some(effort) = effort {
            params["thinkingLevel"] = Value::String(effort.into());
        }
        let result = self.inner.request("sessions.create", params).await?;
        let session_id = result
            .get("key")
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
            .ok_or_else(|| {
                gateway_error(
                    "invalid-response",
                    "OpenClaw Gateway returned an invalid session creation result.",
                )
            })?
            .to_owned();
        self.bind_session(&session_id).await
    }

    async fn bind_session(&self, session_id: &str) -> Result<(), CodexError> {
        self.load_history(session_id).await?;
        let previous = self.inner.state.lock().await.subscribed_session_id.clone();
        if let Some(previous) = previous
            && previous != session_id
            && self
                .inner
                .state
                .lock()
                .await
                .methods
                .contains("sessions.messages.unsubscribe")
        {
            let _ = self
                .inner
                .request("sessions.messages.unsubscribe", json!({"key": previous}))
                .await;
        }
        let include_approvals = self
            .inner
            .state
            .lock()
            .await
            .scopes
            .contains("operator.approvals");
        self.inner
            .request(
                "sessions.messages.subscribe",
                json!({"key": session_id, "includeApprovals": include_approvals}),
            )
            .await?;
        let mut state = self.inner.state.lock().await;
        state.active_session_id = Some(session_id.into());
        state.subscribed_session_id = Some(session_id.into());
        let running_run_id = state
            .sessions
            .iter()
            .find(|session| session.get("id").and_then(Value::as_str) == Some(session_id))
            .filter(|session| session.get("status").and_then(Value::as_str) == Some("running"))
            .and_then(|session| session.get("lastRunId").and_then(Value::as_str))
            .map(str::to_owned);
        if let Some(run_id) = running_run_id {
            state.active_turns.insert(session_id.into(), run_id);
        }
        Ok(())
    }

    async fn load_history(&self, session_id: &str) -> Result<(), CodexError> {
        let result = self
            .inner
            .request(
                "chat.history",
                json!({"sessionKey": session_id, "limit": 200, "maxChars": 500_000}),
            )
            .await?;
        let messages = result
            .get("messages")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        self.inner
            .state
            .lock()
            .await
            .histories
            .insert(session_id.into(), messages);
        Ok(())
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

    async fn active_model_id(&self) -> String {
        let state = self.inner.state.lock().await;
        state
            .sessions
            .iter()
            .find(|session| {
                session.get("id").and_then(Value::as_str) == state.active_session_id.as_deref()
            })
            .and_then(|session| {
                let model = session.get("model").and_then(Value::as_str)?;
                let provider = session.get("modelProvider").and_then(Value::as_str);
                Some(encode_model_id(provider, Some(model)))
            })
            .unwrap_or_default()
    }
}

impl Inner {
    async fn clear_pending_start(&self, session_id: &str, remove_user: bool) {
        let mut state = self.state.lock().await;
        state.pending_starts.remove(session_id);
        state.deferred_events.remove(session_id);
        if remove_user
            && let Some(history) = state.histories.get_mut(session_id)
            && history
                .last()
                .and_then(|message| message.get("role"))
                .and_then(Value::as_str)
                == Some("user")
        {
            history.pop();
        }
    }

    async fn request(&self, method: &str, params: Value) -> Result<Value, CodexError> {
        if self.state.lock().await.exited {
            return Err(gateway_error(
                "runtime-exited",
                "OpenClaw Gateway is not connected.",
            ));
        }
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
        let frame = json!({"type": "req", "id": id, "method": method, "params": params});
        if let Err(error) = self
            .writer
            .lock()
            .await
            .send(Message::Text(frame.to_string().into()))
            .await
        {
            self.pending.lock().await.remove(&id);
            return Err(gateway_error("runtime-exited", error.to_string()));
        }
        match timeout(REQUEST_TIMEOUT, receiver).await {
            Ok(Ok(result)) => result,
            Ok(Err(_)) => Err(gateway_error(
                "runtime-exited",
                "OpenClaw Gateway response channel closed.",
            )),
            Err(_) => {
                self.pending.lock().await.remove(&id);
                Err(CodexError {
                    code: "unknown-outcome".into(),
                    message: format!("OpenClaw Gateway did not respond to '{method}' in time."),
                    retryable: true,
                })
            }
        }
    }

    async fn handle_frame(self: &Arc<Self>, frame: Value) {
        if frame.get("type").and_then(Value::as_str) == Some("res") {
            let id = frame.get("id").map(value_string).unwrap_or_default();
            let Some(pending) = self.pending.lock().await.remove(&id) else {
                return;
            };
            let result = if frame.get("ok").and_then(Value::as_bool) == Some(true) {
                Ok(frame.get("payload").cloned().unwrap_or_else(|| json!({})))
            } else {
                Err(gateway_error(
                    "runtime-request-failed",
                    format!(
                        "OpenClaw {} failed: {}",
                        pending.method,
                        frame
                            .pointer("/error/message")
                            .or_else(|| frame.get("error"))
                            .map(value_string)
                            .unwrap_or_else(|| "Gateway request failed".into())
                    ),
                ))
            };
            let _ = pending.completion.send(result);
            return;
        }
        if frame.get("type").and_then(Value::as_str) == Some("event") {
            let name = frame
                .get("event")
                .and_then(Value::as_str)
                .unwrap_or_default();
            let payload = frame.get("payload").cloned().unwrap_or_else(|| json!({}));
            self.handle_event(name, &payload).await;
        }
    }

    async fn handle_event(&self, name: &str, payload: &Value) {
        let _event_gate = self.event_gate.lock().await;
        self.dispatch_event(name, payload).await;
    }

    async fn dispatch_event(&self, name: &str, payload: &Value) {
        if let Some(session_id) = payload.get("sessionKey").and_then(Value::as_str) {
            let mut state = self.state.lock().await;
            if state.pending_starts.contains_key(session_id)
                && !state.active_turns.contains_key(session_id)
            {
                state
                    .deferred_events
                    .entry(session_id.into())
                    .or_default()
                    .push((name.into(), payload.clone()));
                return;
            }
        }
        match name {
            "chat" => self.handle_chat_event(payload).await,
            "agent" => self.handle_agent_event(payload).await,
            "session.message" => self.handle_session_message(payload).await,
            "question.requested" => self.handle_question(payload).await,
            "exec.approval.requested"
            | "plugin.approval.requested"
            | "openclaw.approval.requested" => self.handle_approval(name, payload).await,
            "session.tool" => self.handle_tool(payload).await,
            "tick" | "health" => {}
            _ => self.emit(
                "runtime.diagnostic",
                payload.get("sessionKey").and_then(Value::as_str),
                None,
                None,
                json!({"method": name}),
            ),
        }
    }

    async fn handle_agent_event(&self, payload: &Value) {
        let run_id = payload
            .get("runId")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned();
        if run_id.is_empty() {
            return;
        }
        let stream = payload
            .get("stream")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let data = payload.get("data").cloned().unwrap_or_else(|| json!({}));
        let mut state = self.state.lock().await;
        let session_id = payload
            .get("sessionKey")
            .and_then(Value::as_str)
            .map(str::to_owned)
            .or_else(|| {
                state.active_turns.iter().find_map(|(session_id, active)| {
                    (active == &run_id).then(|| session_id.clone())
                })
            });
        let Some(session_id) = session_id else {
            return;
        };
        if state
            .terminal_runs
            .contains(&format!("{session_id}:{run_id}"))
        {
            return;
        }
        let operation = state.turn_operations.get(&session_id).cloned();
        if stream == "tool" {
            let lifecycle = match data.get("phase").and_then(Value::as_str) {
                Some("start") => "started",
                Some("result") => "completed",
                _ => "delta",
            };
            let item_id = data
                .get("toolCallId")
                .map(value_string)
                .unwrap_or_else(|| format!("{run_id}-tool"));
            let title = data.get("name").and_then(Value::as_str).unwrap_or("Tool");
            let text = message_text(
                data.get("result")
                    .or_else(|| data.get("partialResult"))
                    .or_else(|| data.get("args"))
                    .unwrap_or(&Value::Null),
            );
            drop(state);
            self.emit(
                "item.update",
                Some(&session_id),
                Some(&run_id),
                operation.as_deref(),
                json!({
                    "kind": if lifecycle == "delta" { "toolOutput" } else { "tool" },
                    "lifecycle": lifecycle,
                    "title": title,
                    "text": text,
                    "itemId": item_id,
                    "status": if data.get("isError").and_then(Value::as_bool) == Some(true) { "failed" } else if lifecycle == "completed" { "completed" } else { "" }
                }),
            );
            return;
        }
        if stream != "lifecycle" {
            return;
        }
        let phase = data
            .get("phase")
            .and_then(Value::as_str)
            .unwrap_or_default();
        if !matches!(phase, "end" | "error") {
            return;
        }
        if state.active_turns.get(&session_id).map(String::as_str) != Some(&run_id) {
            return;
        }
        state.active_turns.remove(&session_id);
        state.turn_operations.remove(&session_id);
        state.streamed_text.remove(&run_id);
        state.terminal_runs.insert(format!("{session_id}:{run_id}"));
        prune_set(&mut state.terminal_runs);
        let error = data
            .get("error")
            .or_else(|| data.get("errorMessage"))
            .and_then(Value::as_str)
            .map(str::to_owned);
        drop(state);
        let mut completion = json!({
            "status": if phase == "end" { "completed" } else { "failed" },
            "evidence": "agent-lifecycle"
        });
        if let Some(error) = error {
            completion["error"] = Value::String(error);
        }
        self.emit(
            "turn.completed",
            Some(&session_id),
            Some(&run_id),
            operation.as_deref(),
            completion,
        );
    }

    async fn handle_session_message(&self, payload: &Value) {
        let session_id = payload
            .get("sessionKey")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let Some(message) = payload.get("message") else {
            return;
        };
        if session_id.is_empty() || message.is_null() {
            return;
        }
        let message_id = payload
            .get("messageId")
            .and_then(Value::as_str)
            .or_else(|| message.pointer("/__openclaw/id").and_then(Value::as_str));
        let mut state = self.state.lock().await;
        let history = state.histories.entry(session_id.into()).or_default();
        if message_id.is_some_and(|id| {
            history.iter().any(|existing| {
                existing
                    .get("id")
                    .or_else(|| existing.pointer("/__openclaw/id"))
                    .and_then(Value::as_str)
                    == Some(id)
            })
        }) {
            return;
        }
        history.push(message.clone());
    }

    async fn handle_chat_event(&self, event: &Value) {
        let session_id = event
            .get("sessionKey")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned();
        let run_id = event
            .get("runId")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned();
        let event_state = event
            .get("state")
            .and_then(Value::as_str)
            .unwrap_or_default();
        if session_id.is_empty() || run_id.is_empty() || event_state.is_empty() {
            self.emit(
                "runtime.diagnostic",
                None,
                None,
                None,
                json!({"method": "invalid chat"}),
            );
            return;
        }
        let key = format!("{session_id}:{run_id}");
        let mut state = self.state.lock().await;
        if let Some(sequence) = event.get("seq").and_then(Value::as_i64) {
            if state
                .run_sequences
                .get(&key)
                .is_some_and(|previous| sequence <= *previous)
            {
                return;
            }
            state.run_sequences.insert(key.clone(), sequence);
            prune_map(&mut state.run_sequences);
        }
        if state.terminal_runs.contains(&key) {
            return;
        }
        if let Some(active) = state.active_turns.get(&session_id)
            && active != &run_id
        {
            return;
        }
        if event_state == "status" {
            let phase = event
                .get("phase")
                .and_then(Value::as_str)
                .unwrap_or_default();
            drop(state);
            self.emit_status(
                phase_label(phase),
                "ready",
                Some(&session_id),
                Some(&run_id),
            );
            return;
        }
        let pending_operation = state.pending_starts.get(&session_id).cloned();
        if !state.active_turns.contains_key(&session_id) && pending_operation.is_some() {
            state
                .active_turns
                .insert(session_id.clone(), run_id.clone());
            state.turn_operations.insert(
                session_id.clone(),
                pending_operation.clone().unwrap_or_default(),
            );
        }
        let operation = state.turn_operations.get(&session_id).cloned();
        if event_state == "delta" {
            if !state.active_turns.contains_key(&session_id) {
                return;
            }
            let text = event
                .get("deltaText")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_owned();
            let replace = event.get("replace").and_then(Value::as_bool) == Some(true);
            if replace {
                state.streamed_text.insert(run_id.clone(), text.clone());
            } else {
                state
                    .streamed_text
                    .entry(run_id.clone())
                    .or_default()
                    .push_str(&text);
            }
            drop(state);
            self.emit(
                "item.update",
                Some(&session_id),
                Some(&run_id),
                operation.as_deref(),
                json!({"kind": "assistant", "lifecycle": "delta", "title": "OpenClaw", "text": text, "replace": replace, "itemId": format!("{run_id}-assistant")}),
            );
            return;
        }
        if !state.active_turns.contains_key(&session_id) {
            return;
        }
        let final_text = message_text(event.get("message").unwrap_or(&Value::Null));
        let streamed = state.streamed_text.remove(&run_id).unwrap_or_default();
        state.active_turns.remove(&session_id);
        state.pending_starts.remove(&session_id);
        state.turn_operations.remove(&session_id);
        state.terminal_runs.insert(key);
        prune_set(&mut state.terminal_runs);
        if !final_text.is_empty() {
            state.histories.entry(session_id.clone()).or_default().push(
                event
                    .get("message")
                    .cloned()
                    .unwrap_or_else(|| json!({"role": "assistant", "text": final_text})),
            );
        }
        let suffix = if streamed.is_empty() {
            final_text.clone()
        } else {
            final_text
                .strip_prefix(&streamed)
                .unwrap_or_default()
                .to_owned()
        };
        let status = match event_state {
            "final" => "completed",
            "aborted" => "interrupted",
            _ => "failed",
        };
        let error = event.get("errorMessage").cloned();
        drop(state);
        if !suffix.is_empty() {
            self.emit(
                "item.update",
                Some(&session_id),
                Some(&run_id),
                operation.as_deref(),
                json!({"kind": "assistant", "lifecycle": "completed", "title": "OpenClaw", "text": suffix, "itemId": format!("{run_id}-assistant")}),
            );
        }
        let mut completion = json!({"status": status});
        if let Some(error) = error {
            completion["error"] = error;
        }
        self.emit(
            "turn.completed",
            Some(&session_id),
            Some(&run_id),
            operation.as_deref(),
            completion,
        );
    }

    async fn handle_tool(&self, payload: &Value) {
        let session_id = payload
            .get("sessionKey")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned();
        if session_id.is_empty() {
            return;
        }
        let state = self.state.lock().await;
        let turn_id = state.active_turns.get(&session_id).cloned();
        let operation = state.turn_operations.get(&session_id).cloned();
        drop(state);
        let lifecycle = match payload.get("state").and_then(Value::as_str) {
            Some("started") => "started",
            Some("completed" | "error") => "completed",
            _ => "delta",
        };
        self.emit(
            "item.update",
            Some(&session_id),
            turn_id.as_deref(),
            operation.as_deref(),
            json!({
                "kind": if lifecycle == "delta" { "toolOutput" } else { "tool" },
                "lifecycle": lifecycle,
                "title": payload.get("name").and_then(Value::as_str).unwrap_or("Tool"),
                "text": message_text(payload.get("result").or_else(|| payload.get("message")).unwrap_or(payload)),
                "itemId": payload.get("toolCallId").or_else(|| payload.get("id")).or_else(|| payload.get("name")).map(value_string).unwrap_or_else(|| "tool".into())
            }),
        );
    }

    async fn handle_approval(&self, event_name: &str, payload: &Value) {
        let Some(id) = payload
            .get("id")
            .map(value_string)
            .filter(|id| !id.is_empty())
        else {
            return;
        };
        let kind = if event_name.starts_with("exec.") {
            "exec"
        } else if event_name.starts_with("plugin.") {
            "plugin"
        } else {
            "system-agent"
        };
        let session_id = {
            let mut state = self.state.lock().await;
            let session_id = payload
                .get("sessionKey")
                .and_then(Value::as_str)
                .map(str::to_owned)
                .or_else(|| state.active_session_id.clone())
                .unwrap_or_default();
            state.approvals.insert(
                id.clone(),
                PendingApproval {
                    session_id: session_id.clone(),
                    kind: kind.into(),
                },
            );
            session_id
        };
        self.emit(
            "approval.requested",
            Some(&session_id),
            None,
            None,
            json!({
                "approvalId": id,
                "options": [
                    {"optionId": "allow-once", "name": "Allow once", "kind": "allow_once"},
                    {"optionId": "allow-always", "name": "Always allow", "kind": "allow_always"},
                    {"optionId": "deny", "name": "Deny", "kind": "reject"}
                ],
                "toolCall": {"title": approval_title(payload), "rawInput": payload.get("presentation").unwrap_or(payload)}
            }),
        );
    }

    async fn handle_question(&self, payload: &Value) {
        let Some(id) = payload
            .get("id")
            .map(value_string)
            .filter(|id| !id.is_empty())
        else {
            return;
        };
        let questions = payload
            .get("questions")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        if questions.is_empty() {
            return;
        }
        let session_id = {
            let mut state = self.state.lock().await;
            let session_id = payload
                .get("sessionKey")
                .and_then(Value::as_str)
                .map(str::to_owned)
                .or_else(|| state.active_session_id.clone())
                .unwrap_or_default();
            state.questions.insert(
                id.clone(),
                PendingQuestion {
                    session_id: session_id.clone(),
                    questions: questions.clone(),
                },
            );
            session_id
        };
        self.emit(
            "question.requested",
            Some(&session_id),
            None,
            None,
            json!({
                "questionId": id,
                "title": "OpenClaw needs your input",
                "questions": questions.iter().map(|question| json!({
                    "questionId": question.get("questionId"),
                    "header": question.get("header"),
                    "question": question.get("question"),
                    "options": question.get("options").cloned().unwrap_or_else(|| json!([])),
                    "multiSelect": question.get("multiSelect").and_then(Value::as_bool).unwrap_or(false),
                    "isOther": question.get("isOther").and_then(Value::as_bool).unwrap_or(false),
                    "isSecret": question.get("isSecret").and_then(Value::as_bool).unwrap_or(false)
                })).collect::<Vec<_>>()
            }),
        );
    }

    async fn handle_disconnect(&self, message: String) {
        let mut state = self.state.lock().await;
        if state.exited || state.stopping {
            return;
        }
        state.exited = true;
        let active = std::mem::take(&mut state.active_turns);
        let operations = std::mem::take(&mut state.turn_operations);
        state.pending_starts.clear();
        state.deferred_events.clear();
        state.streamed_text.clear();
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

async fn read_challenge(socket: &mut GatewaySocket) -> Result<ConnectChallenge, CodexError> {
    while let Some(message) = socket.next().await {
        let frame = parse_message(message)?;
        if frame.get("type").and_then(Value::as_str) == Some("event")
            && frame.get("event").and_then(Value::as_str) == Some("connect.challenge")
        {
            let nonce = frame
                .pointer("/payload/nonce")
                .and_then(Value::as_str)
                .filter(|value| !value.trim().is_empty())
                .map(str::to_owned)
                .ok_or_else(|| {
                    gateway_error(
                        "invalid-response",
                        "OpenClaw Gateway connect challenge is missing a nonce.",
                    )
                })?;
            let signed_at = frame
                .pointer("/payload/ts")
                .and_then(Value::as_u64)
                .ok_or_else(|| {
                    gateway_error(
                        "invalid-response",
                        "OpenClaw Gateway connect challenge timestamp is invalid.",
                    )
                })?;
            return Ok(ConnectChallenge { nonce, signed_at });
        }
    }
    Err(gateway_error(
        "runtime-unavailable",
        "OpenClaw Gateway closed before its connect challenge.",
    ))
}

async fn read_connect_response(
    socket: &mut GatewaySocket,
    request_id: &str,
) -> Result<Value, CodexError> {
    while let Some(message) = socket.next().await {
        let frame = parse_message(message)?;
        if frame.get("type").and_then(Value::as_str) != Some("res")
            || frame.get("id").map(value_string).as_deref() != Some(request_id)
        {
            continue;
        }
        if frame.get("ok").and_then(Value::as_bool) == Some(true) {
            return Ok(frame.get("payload").cloned().unwrap_or_else(|| json!({})));
        }
        let message = frame
            .pointer("/error/message")
            .or_else(|| frame.get("error"))
            .map(value_string)
            .unwrap_or_else(|| "OpenClaw Gateway rejected the connection.".into());
        let code = if message.to_ascii_lowercase().contains("auth")
            || message.to_ascii_lowercase().contains("token")
            || message.to_ascii_lowercase().contains("password")
        {
            "authentication-required"
        } else {
            "runtime-unavailable"
        };
        return Err(gateway_error(code, message));
    }
    Err(gateway_error(
        "runtime-unavailable",
        "OpenClaw Gateway closed during challenge handshake.",
    ))
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
                        "OpenClaw Gateway emitted invalid JSON.",
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
                        "OpenClaw Gateway emitted invalid JSON.",
                        "degraded",
                        None,
                        None,
                    ),
                }
            }
            Ok(Message::Ping(bytes)) => {
                let _ = inner.writer.lock().await.send(Message::Pong(bytes)).await;
            }
            Ok(Message::Close(frame)) => {
                let reason = frame
                    .map(|frame| sanitize_diagnostic(frame.reason.to_string()))
                    .filter(|reason| !reason.is_empty());
                inner
                    .handle_disconnect(format!(
                        "OpenClaw Gateway disconnected{}; active run outcome is unknown.",
                        reason
                            .map(|reason| format!(": {reason}"))
                            .unwrap_or_default()
                    ))
                    .await;
                return;
            }
            Err(error) => {
                inner
                    .handle_disconnect(format!(
                        "OpenClaw Gateway disconnected: {error}; active run outcome is unknown."
                    ))
                    .await;
                return;
            }
            Ok(Message::Text(_) | Message::Binary(_)) => inner.emit_status(
                "OpenClaw Gateway emitted an oversized frame.",
                "degraded",
                None,
                None,
            ),
            _ => {}
        }
    }
    if let Some(inner) = inner.upgrade() {
        inner
            .handle_disconnect(
                "OpenClaw Gateway disconnected; active run outcome is unknown.".into(),
            )
            .await;
    }
}

fn parse_message(
    message: Result<Message, tokio_tungstenite::tungstenite::Error>,
) -> Result<Value, CodexError> {
    match message.map_err(|error| gateway_error("runtime-unavailable", error.to_string()))? {
        Message::Text(text) if text.len() <= MAX_FRAME_BYTES => serde_json::from_str(text.as_str())
            .map_err(|error| gateway_error("invalid-response", error.to_string())),
        Message::Binary(bytes) if bytes.len() <= MAX_FRAME_BYTES => serde_json::from_slice(&bytes)
            .map_err(|error| gateway_error("invalid-response", error.to_string())),
        Message::Close(_) => Err(gateway_error(
            "runtime-unavailable",
            "OpenClaw Gateway closed during handshake.",
        )),
        _ => Err(gateway_error(
            "invalid-response",
            "OpenClaw Gateway emitted an unsupported handshake frame.",
        )),
    }
}

fn negotiated_capabilities(methods: &HashSet<String>, scopes: &HashSet<String>) -> Vec<String> {
    let mapping = [
        ("session.list.v1", "sessions.list"),
        ("session.create.v1", "sessions.create"),
        ("session.resume.v1", "chat.history"),
        ("session.rewind.v1", "sessions.rewind"),
        ("session.rewind.prepare.v1", "sessions.rewind"),
        ("history.read.v1", "chat.history"),
        ("turn.stream.v1", "chat.send"),
        ("turn.interrupt.v1", "chat.abort"),
        ("input.image.v1", "chat.send"),
        ("model.select.v1", "models.list"),
        ("approval.resolve.v1", "approval.resolve"),
        ("question.resolve.v1", "question.resolve"),
        ("operation.idempotency.v1", "chat.send"),
    ];
    mapping
        .into_iter()
        .filter(|(capability, method)| {
            (methods.is_empty() || methods.contains(*method))
                && match *capability {
                    "session.rewind.v1" | "session.rewind.prepare.v1" => {
                        methods.contains("sessions.rewind") && scopes.contains("operator.admin")
                    }
                    "approval.resolve.v1" => scopes.contains("operator.approvals"),
                    "question.resolve.v1" => scopes.contains("operator.questions"),
                    _ => true,
                }
        })
        .map(|(capability, _)| capability.into())
        .collect()
}

fn models_for_ui(models: &Value) -> Vec<Value> {
    models
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|model| {
            let raw = model
                .get("id")
                .or_else(|| model.get("model"))
                .and_then(Value::as_str)?;
            let provider = model
                .get("provider")
                .and_then(Value::as_str)
                .unwrap_or_default();
            let id = encode_model_id(Some(provider), Some(raw));
            Some(json!({
                "id": id,
                "model": id,
                "provider": provider,
                "rawModelId": raw,
                "displayName": model.get("name").and_then(Value::as_str).unwrap_or(raw),
                "hidden": false,
                "supportedReasoningEfforts": [
                    {"reasoningEffort": "off"},
                    {"reasoningEffort": "low"},
                    {"reasoningEffort": "medium"},
                    {"reasoningEffort": "high"}
                ],
                "defaultReasoningEffort": "medium"
            }))
        })
        .collect()
}

fn native_entry_id(message: &Value) -> Option<&str> {
    message
        .pointer("/__openclaw/id")
        .or_else(|| message.get("entryId"))
        .and_then(Value::as_str)
        .filter(|id| !id.is_empty())
}

fn messages_to_turns(messages: &[Value]) -> Vec<Value> {
    let mut turns = Vec::new();
    for (index, message) in messages.iter().enumerate() {
        let role = message
            .get("role")
            .or_else(|| message.pointer("/identity/role"))
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_ascii_lowercase();
        let text = message_text(message);
        if role == "user" {
            let identity = native_entry_id(message)
                .map(str::to_owned)
                .unwrap_or_else(|| index.to_string());
            turns.push(json!({
                "id": format!("openclaw-turn-{identity}"),
                "items": [{"id": format!("openclaw-user-{index}"), "type": "userMessage", "content": [{"type": "text", "text": text}]}]
            }));
            continue;
        }
        if turns.is_empty() {
            turns.push(json!({"id": format!("openclaw-turn-{index}"), "items": []}));
        }
        let items = turns
            .last_mut()
            .and_then(|turn: &mut Value| turn.get_mut("items"))
            .and_then(Value::as_array_mut)
            .expect("turn items");
        if role == "assistant" {
            if let Some(reasoning) = message.get("reasoning").and_then(Value::as_str)
                && !reasoning.is_empty()
            {
                items.push(json!({"id": format!("openclaw-thinking-{index}"), "type": "reasoning", "status": "completed", "summary": [reasoning], "content": []}));
            }
            if !text.is_empty() {
                items.push(json!({"id": format!("openclaw-agent-{index}"), "type": "agentMessage", "phase": "final", "status": "completed", "text": text}));
            }
        } else if !text.is_empty() {
            items.push(json!({"id": format!("openclaw-tool-{index}"), "type": "commandExecution", "status": "completed", "title": message.get("name").and_then(Value::as_str).unwrap_or("Tool"), "text": text}));
        }
    }
    turns
}

fn openclaw_attachment(value: &str, index: usize) -> Result<Value, CodexError> {
    let value = value.strip_prefix("data:").ok_or_else(|| {
        gateway_error(
            "invalid-request",
            "OpenClaw Gateway accepts only base64 data URL attachments.",
        )
    })?;
    let (metadata, content) = value
        .split_once(',')
        .ok_or_else(|| gateway_error("invalid-request", "OpenClaw image data URL is malformed."))?;
    let mime = metadata.strip_suffix(";base64").ok_or_else(|| {
        gateway_error(
            "invalid-request",
            "OpenClaw Gateway accepts only base64 data URL attachments.",
        )
    })?;
    let compact = content
        .chars()
        .filter(|character| !character.is_whitespace())
        .collect::<String>();
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(&compact)
        .map_err(|_| gateway_error("invalid-request", "OpenClaw image base64 is invalid."))?;
    Ok(json!({
        "type": "image",
        "mimeType": mime,
        "fileName": format!("zommi-{}.{}", index + 1, mime_extension(mime)),
        "content": compact,
        "sizeBytes": bytes.len()
    }))
}

fn message_text(value: &Value) -> String {
    if let Some(text) = value.as_str() {
        return text.into();
    }
    if let Some(text) = value
        .get("text")
        .or_else(|| value.get("content"))
        .and_then(Value::as_str)
    {
        return text.into();
    }
    value
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

fn approval_title(payload: &Value) -> String {
    payload
        .pointer("/presentation/title")
        .or_else(|| payload.pointer("/presentation/command"))
        .or_else(|| payload.get("title"))
        .or_else(|| payload.get("description"))
        .and_then(Value::as_str)
        .unwrap_or("OpenClaw requests approval")
        .into()
}

fn phase_label(phase: &str) -> &'static str {
    match phase {
        "preparing_workspace" => "Preparing workspace…",
        "provisioning_environment" => "Provisioning environment…",
        "preparing_context" => "Preparing context…",
        "starting_model" => "Starting model…",
        _ => "OpenClaw is working…",
    }
}

fn validate_endpoint(value: &str) -> Result<(), CodexError> {
    let endpoint = url::Url::parse(value).map_err(|_| {
        gateway_error(
            "invalid-configuration",
            "Gateway endpoint must be a valid ws:// or wss:// URL.",
        )
    })?;
    if !matches!(endpoint.scheme(), "ws" | "wss")
        || !endpoint.username().is_empty()
        || endpoint.password().is_some()
        || endpoint.host_str().is_none()
        || endpoint.query_pairs().any(|(key, _)| {
            let key = key.to_ascii_lowercase();
            ["token", "password", "secret", "key", "auth"]
                .iter()
                .any(|fragment| key.contains(fragment))
        })
    {
        return Err(gateway_error(
            "invalid-configuration",
            "Gateway endpoint cannot embed credentials and must use ws:// or wss://.",
        ));
    }
    Ok(())
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

fn short_id(value: &str) -> &str {
    value.get(..value.len().min(16)).unwrap_or(value)
}

fn value_string(value: &Value) -> String {
    value
        .as_str()
        .map(str::to_owned)
        .unwrap_or_else(|| value.to_string())
}

fn prune_set(values: &mut HashSet<String>) {
    if values.len() > 1_024
        && let Some(value) = values.iter().next().cloned()
    {
        values.remove(&value);
    }
}

fn prune_map(values: &mut HashMap<String, i64>) {
    if values.len() > 1_024
        && let Some(value) = values.keys().next().cloned()
    {
        values.remove(&value);
    }
}

fn gateway_error(code: impl Into<String>, message: impl Into<String>) -> CodexError {
    CodexError {
        code: code.into(),
        message: sanitize_diagnostic(message.into()),
        retryable: false,
    }
}

#[cfg(test)]
mod rewind_tests {
    use super::*;

    #[test]
    fn rewind_requires_the_advertised_method_and_granted_admin_scope() {
        let mut methods = HashSet::from(["sessions.rewind".to_owned()]);
        let mut scopes = HashSet::from(["operator.write".to_owned()]);
        assert!(!negotiated_capabilities(&methods, &scopes).contains(&"session.rewind.v1".into()));
        scopes.insert("operator.admin".into());
        assert!(negotiated_capabilities(&methods, &scopes).contains(&"session.rewind.v1".into()));
        methods.clear();
        assert!(!negotiated_capabilities(&methods, &scopes).contains(&"session.rewind.v1".into()));
    }
}
