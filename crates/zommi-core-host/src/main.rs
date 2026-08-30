use std::{env, io, path::PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader, BufWriter},
    sync::mpsc,
};
use uuid::Uuid;
use zommi_core::{
    SessionBinding, SessionBindingStore, build_context_handoff,
    codex_adapter::{
        CodexAdapter, CodexConfig, CodexError, CodexTurnRequest, CoreEvent, EventSender,
    },
    command_for_target, discover_codex_targets, select_default_target, validate_broker_request,
};

const CORE_PROTOCOL_VERSION: u64 = 1;
const MAX_REQUEST_BYTES: usize = 64 * 1024 * 1024;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CoreRequest {
    id: Option<String>,
    protocol_version: Option<u64>,
    operation: Option<String>,
    #[serde(default = "empty_object")]
    payload: Value,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct CoreResponse {
    id: Option<String>,
    protocol_version: u64,
    ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<CoreProtocolError>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct CoreProtocolError {
    code: String,
    message: String,
    retryable: bool,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct CoreEventEnvelope {
    protocol_version: u64,
    event: CoreEvent,
}

struct HostAction {
    response: CoreResponse,
    shutdown: bool,
}

struct HostState {
    targets: Vec<zommi_core::RuntimeTarget>,
    adapter: Option<CodexAdapter>,
    binding_store: SessionBindingStore,
    event_tx: EventSender,
}

impl HostState {
    fn new(event_tx: EventSender) -> Self {
        Self {
            targets: Vec::new(),
            adapter: None,
            binding_store: SessionBindingStore::platform_default(),
            event_tx,
        }
    }

    async fn handle(&mut self, request: CoreRequest) -> HostAction {
        let id = request.id.clone();
        if id.as_deref().is_none_or(str::is_empty) {
            return failure(id, "invalid-request", "Core request requires id.", false);
        }
        if request.protocol_version != Some(CORE_PROTOCOL_VERSION) {
            return failure(
                id,
                "unsupported-version",
                format!(
                    "Unsupported core protocol version {}.",
                    request
                        .protocol_version
                        .map_or_else(|| "<missing>".into(), |version| version.to_string())
                ),
                false,
            );
        }
        let Some(operation) = request.operation.as_deref() else {
            return failure(
                id,
                "invalid-request",
                "Core request requires operation.",
                false,
            );
        };
        if !request.payload.is_object() {
            return failure(
                id,
                "invalid-request",
                "Core request payload must be an object.",
                false,
            );
        }

        let result = self.execute(operation, &request.payload).await;
        match result {
            Ok(result) => HostAction {
                response: success_response(id, result),
                shutdown: operation == "core.shutdown",
            },
            Err(error) => failure(id, error.code, error.message, error.retryable),
        }
    }

    async fn execute(&mut self, operation: &str, payload: &Value) -> Result<Value, HostError> {
        match operation {
            "core.initialize" => Ok(json!({
                "coreVersion": env!("CARGO_PKG_VERSION"),
                "protocolVersion": CORE_PROTOCOL_VERSION,
                "capabilities": [
                    "context.handoff.v1",
                    "protocol.validation.v1",
                    "runtime.discovery.v1",
                    "session.binding.v1",
                    "codex.appServer.v1",
                    "turn.stream.v1",
                    "turn.interrupt.v1"
                ]
            })),
            "context.buildHandoff" => {
                let message = payload
                    .get("message")
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                let snapshots = payload
                    .get("snapshots")
                    .and_then(Value::as_array)
                    .map(Vec::as_slice)
                    .unwrap_or_default();
                let image_count = payload
                    .get("imageCount")
                    .and_then(Value::as_u64)
                    .and_then(|count| usize::try_from(count).ok())
                    .unwrap_or_default();
                Ok(json!({"text": build_context_handoff(message, snapshots, image_count)}))
            }
            "runtime.discover" => {
                self.targets = tokio::task::spawn_blocking(discover_codex_targets)
                    .await
                    .map_err(|error| HostError::new("discovery-failed", error.to_string()))?;
                let binding = self.binding_store.load();
                let selected = select_default_target(
                    &self.targets,
                    binding
                        .as_ref()
                        .map(|value| value.runtime_target_id.as_str()),
                    payload.get("lastSelectedTargetId").and_then(Value::as_str),
                );
                Ok(json!({
                    "targets": self.targets,
                    "selectedTargetId": selected.map(|target| target.id.clone()),
                    "binding": binding
                }))
            }
            "runtime.connect" => self.connect_runtime(payload).await,
            "session.list" => {
                let adapter = self.exact_adapter(payload)?;
                Ok(json!({"data": adapter.list_sessions().await?}))
            }
            "session.create" => {
                let adapter = self.exact_adapter(payload)?;
                let connection = adapter
                    .create_session(
                        payload.get("model").and_then(Value::as_str),
                        payload.get("effort").and_then(Value::as_str),
                    )
                    .await?;
                self.save_binding(
                    &connection.runtime_target_id,
                    &connection.session_id,
                    payload,
                )?;
                Ok(serde_json::to_value(connection)?)
            }
            "session.open" => {
                let adapter = self.exact_adapter(payload)?;
                let session_id = required_string(payload, "sessionId")?;
                let connection = adapter.open_session(session_id).await?;
                self.save_binding(
                    &connection.runtime_target_id,
                    &connection.session_id,
                    payload,
                )?;
                Ok(serde_json::to_value(connection)?)
            }
            "session.read" => {
                let adapter = self.exact_adapter(payload)?;
                let session_id = required_string(payload, "sessionId")?;
                Ok(adapter.read_session(session_id).await?)
            }
            "turn.start" => {
                let adapter = self.exact_adapter(payload)?;
                let session_id = required_string(payload, "sessionId")?;
                let message = required_string(payload, "message")?;
                let snapshots = payload
                    .get("snapshots")
                    .and_then(Value::as_array)
                    .map(Vec::as_slice)
                    .unwrap_or_default();
                let images = payload
                    .get("images")
                    .and_then(Value::as_array)
                    .into_iter()
                    .flatten()
                    .map(|value| value.as_str().unwrap_or_default().to_owned())
                    .collect::<Vec<_>>();
                let proposed_operation_id = payload
                    .get("clientOperationId")
                    .and_then(Value::as_str)
                    .filter(|value| !value.is_empty())
                    .map(str::to_owned)
                    .unwrap_or_else(|| format!("zommi:{}", Uuid::new_v4()));
                let identity = validate_broker_request(&json!({
                    "protocolVersion": 1,
                    "operation": "turn.start",
                    "clientOperationId": proposed_operation_id,
                    "runtimeTargetId": adapter.target_id(),
                    "sessionId": session_id,
                    "payload": {}
                }))
                .map_err(|error| HostError {
                    code: error.code,
                    message: error.message,
                    retryable: error.retryable,
                })?;
                let client_operation_id = identity.client_operation_id;
                let receipt = adapter
                    .start_turn(CodexTurnRequest {
                        session_id,
                        message,
                        snapshots,
                        images: &images,
                        client_operation_id: &client_operation_id,
                        model: payload.get("model").and_then(Value::as_str),
                        effort: payload.get("effort").and_then(Value::as_str),
                    })
                    .await?;
                Ok(serde_json::to_value(receipt)?)
            }
            "turn.interrupt" => {
                let adapter = self.exact_adapter(payload)?;
                Ok(adapter
                    .interrupt_turn(
                        required_string(payload, "sessionId")?,
                        required_string(payload, "turnId")?,
                    )
                    .await?)
            }
            "core.shutdown" => {
                if let Some(adapter) = self.adapter.take() {
                    adapter.shutdown().await;
                }
                Ok(json!({"stopped": true}))
            }
            _ => Err(HostError::new(
                "unsupported-operation",
                format!("Unsupported core operation '{operation}'."),
            )),
        }
    }

    async fn connect_runtime(&mut self, payload: &Value) -> Result<Value, HostError> {
        if self.targets.is_empty() {
            self.targets = tokio::task::spawn_blocking(discover_codex_targets)
                .await
                .map_err(|error| HostError::new("discovery-failed", error.to_string()))?;
        }
        let binding = self.binding_store.load();
        let requested_target_id = payload
            .get("runtimeTargetId")
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty());
        let target = if let Some(target_id) = requested_target_id {
            self.targets.iter().find(|target| target.id == target_id)
        } else {
            select_default_target(
                &self.targets,
                binding
                    .as_ref()
                    .map(|value| value.runtime_target_id.as_str()),
                None,
            )
        }
        .cloned()
        .ok_or_else(|| {
            HostError::new(
                "runtime-unavailable",
                requested_target_id.map_or_else(
                    || "No Codex runtime was found. Install Codex, then refresh.".into(),
                    |target_id| format!("The exact runtime target '{target_id}' was not found."),
                ),
            )
        })?;

        if let Some(adapter) = self.adapter.take() {
            adapter.shutdown().await;
        }
        let requested_cwd = payload
            .get("cwd")
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
            .map(PathBuf::from)
            .or_else(|| {
                binding
                    .as_ref()
                    .filter(|binding| binding.runtime_target_id == target.id)
                    .map(|binding| PathBuf::from(&binding.cwd))
            })
            .or_else(|| env::current_dir().ok())
            .unwrap_or_else(env::temp_dir);
        let cwd = if target.execution_host.kind == "wsl" {
            target
                .runtime_home
                .as_deref()
                .map(PathBuf::from)
                .unwrap_or_else(|| PathBuf::from("/"))
        } else {
            requested_cwd
        };
        let preferred_session_id = payload
            .get("preferredSessionId")
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
            .map(str::to_owned)
            .or_else(|| {
                binding
                    .as_ref()
                    .filter(|binding| binding.runtime_target_id == target.id)
                    .map(|binding| binding.session_id.clone())
            });
        let mut runtime_command = command_for_target(&target);
        if let Some(arguments) = env::var_os("ZOMMI_CODEX_ARGS_JSON") {
            let parsed = serde_json::from_str::<Vec<String>>(&arguments.to_string_lossy())
                .map_err(|error| {
                    HostError::new(
                        "invalid-configuration",
                        format!("ZOMMI_CODEX_ARGS_JSON is invalid: {error}"),
                    )
                })?;
            runtime_command.args = parsed;
        }
        let adapter = CodexAdapter::connect(
            CodexConfig::new(target, runtime_command, cwd.clone(), preferred_session_id),
            self.event_tx.clone(),
        )
        .await?;
        let connection = adapter.connection().await?;
        self.binding_store
            .save(&SessionBinding {
                runtime_target_id: connection.runtime_target_id.clone(),
                session_id: connection.session_id.clone(),
                cwd: cwd.to_string_lossy().into_owned(),
            })
            .map_err(|error| HostError::new("persistence-failed", error.to_string()))?;
        self.adapter = Some(adapter);
        Ok(serde_json::to_value(connection)?)
    }

    fn exact_adapter(&self, payload: &Value) -> Result<CodexAdapter, HostError> {
        let adapter = self.adapter.as_ref().ok_or_else(|| {
            HostError::new(
                "runtime-unavailable",
                "Connect an exact runtime target before using sessions or turns.",
            )
        })?;
        let requested = required_string(payload, "runtimeTargetId")?;
        if requested != adapter.target_id() {
            return Err(HostError::new(
                "identity-mismatch",
                "The request runtimeTargetId does not match the connected target.",
            ));
        }
        Ok(adapter.clone())
    }

    fn save_binding(
        &self,
        runtime_target_id: &str,
        session_id: &str,
        payload: &Value,
    ) -> Result<(), HostError> {
        let cwd = payload
            .get("cwd")
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
            .map(str::to_owned)
            .or_else(|| self.binding_store.load().map(|binding| binding.cwd))
            .or_else(|| {
                env::current_dir()
                    .ok()
                    .map(|path| path.to_string_lossy().into_owned())
            })
            .unwrap_or_default();
        self.binding_store
            .save(&SessionBinding {
                runtime_target_id: runtime_target_id.into(),
                session_id: session_id.into(),
                cwd,
            })
            .map_err(|error| HostError::new("persistence-failed", error.to_string()))
    }
}

#[derive(Debug)]
struct HostError {
    code: String,
    message: String,
    retryable: bool,
}

impl HostError {
    fn new(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
            retryable: false,
        }
    }
}

impl From<CodexError> for HostError {
    fn from(error: CodexError) -> Self {
        Self {
            code: error.code,
            message: error.message,
            retryable: error.retryable,
        }
    }
}

impl From<serde_json::Error> for HostError {
    fn from(error: serde_json::Error) -> Self {
        Self::new("protocol-error", error.to_string())
    }
}

#[tokio::main]
async fn main() -> io::Result<()> {
    let (output_tx, mut output_rx) = mpsc::unbounded_channel::<Value>();
    let writer = tokio::spawn(async move {
        let mut stdout = BufWriter::new(tokio::io::stdout());
        while let Some(value) = output_rx.recv().await {
            let bytes = serde_json::to_vec(&value).map_err(io::Error::other)?;
            stdout.write_all(&bytes).await?;
            stdout.write_all(b"\n").await?;
            stdout.flush().await?;
        }
        Ok::<(), io::Error>(())
    });
    let (event_tx, mut event_rx) = mpsc::unbounded_channel::<CoreEvent>();
    let event_output = output_tx.clone();
    let event_forwarder = tokio::spawn(async move {
        while let Some(event) = event_rx.recv().await {
            let envelope = CoreEventEnvelope {
                protocol_version: CORE_PROTOCOL_VERSION,
                event,
            };
            if let Ok(value) = serde_json::to_value(envelope) {
                let _ = event_output.send(value);
            }
        }
    });
    let mut state = HostState::new(event_tx);
    let mut lines = BufReader::new(tokio::io::stdin()).lines();
    while let Some(line) = lines.next_line().await? {
        let action = if line.len() > MAX_REQUEST_BYTES {
            failure(
                None,
                "input-too-large",
                "Core request exceeds 64 MiB.",
                false,
            )
        } else {
            match serde_json::from_str::<CoreRequest>(&line) {
                Ok(request) => state.handle(request).await,
                Err(error) => failure(
                    None,
                    "invalid-request",
                    format!("Core request is not valid JSON: {error}"),
                    false,
                ),
            }
        };
        let value = serde_json::to_value(&action.response).map_err(io::Error::other)?;
        output_tx
            .send(value)
            .map_err(|_| io::Error::new(io::ErrorKind::BrokenPipe, "core output closed"))?;
        if action.shutdown {
            break;
        }
    }
    if let Some(adapter) = state.adapter.take() {
        adapter.shutdown().await;
    }
    drop(state);
    event_forwarder.abort();
    drop(output_tx);
    writer.await.map_err(io::Error::other)??;
    Ok(())
}

fn success_response(id: Option<String>, result: Value) -> CoreResponse {
    CoreResponse {
        id,
        protocol_version: CORE_PROTOCOL_VERSION,
        ok: true,
        result: Some(result),
        error: None,
    }
}

fn failure(
    id: Option<String>,
    code: impl Into<String>,
    message: impl Into<String>,
    retryable: bool,
) -> HostAction {
    HostAction {
        response: CoreResponse {
            id,
            protocol_version: CORE_PROTOCOL_VERSION,
            ok: false,
            result: None,
            error: Some(CoreProtocolError {
                code: code.into(),
                message: message.into(),
                retryable,
            }),
        },
        shutdown: false,
    }
}

fn required_string<'a>(value: &'a Value, name: &str) -> Result<&'a str, HostError> {
    value
        .get(name)
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| HostError::new("invalid-request", format!("{name} is required.")))
}

fn empty_object() -> Value {
    Value::Object(serde_json::Map::new())
}

#[cfg(test)]
mod tests {
    use serde_json::{Value, json};
    use tokio::sync::mpsc;

    use super::{CORE_PROTOCOL_VERSION, CoreRequest, HostState};

    #[tokio::test]
    async fn initializes_a_versioned_event_capable_core() {
        let (event_tx, _events) = mpsc::unbounded_channel();
        let mut host = HostState::new(event_tx);
        let action = host
            .handle(CoreRequest {
                id: Some("1".into()),
                protocol_version: Some(CORE_PROTOCOL_VERSION),
                operation: Some("core.initialize".into()),
                payload: json!({}),
            })
            .await;
        let result = serde_json::to_value(action.response).expect("serialize response");
        assert_eq!(result["ok"], true);
        assert_eq!(result["protocolVersion"], CORE_PROTOCOL_VERSION);
        assert_eq!(result["result"]["coreVersion"], env!("CARGO_PKG_VERSION"));
        assert!(
            result["result"]["capabilities"]
                .as_array()
                .expect("capabilities")
                .contains(&Value::String("turn.stream.v1".into()))
        );
    }

    #[tokio::test]
    async fn builds_context_handoffs_over_the_host_protocol() {
        let (event_tx, _events) = mpsc::unbounded_channel();
        let mut host = HostState::new(event_tx);
        let action = host
            .handle(CoreRequest {
                id: Some("2".into()),
                protocol_version: Some(CORE_PROTOCOL_VERSION),
                operation: Some("context.buildHandoff".into()),
                payload: json!({
                    "message": "compare",
                    "snapshots": [{
                        "surfaceKind": "Browser", "application": "Edge", "selection": ["value"]
                    }],
                    "imageCount": 1
                }),
            })
            .await;
        let result = serde_json::to_value(action.response).expect("serialize response");
        let text = result["result"]["text"].as_str().expect("handoff text");
        assert!(text.contains("<user_message>\ncompare"));
        assert!(text.contains("PRIMARY SURFACE SELECTION"));
        assert!(text.contains("User-selected image regions attached: 1"));
    }

    #[tokio::test]
    async fn rejects_protocol_skew() {
        let (event_tx, _events) = mpsc::unbounded_channel();
        let mut host = HostState::new(event_tx);
        let action = host
            .handle(CoreRequest {
                id: Some("3".into()),
                protocol_version: Some(99),
                operation: Some("core.initialize".into()),
                payload: json!({}),
            })
            .await;
        let result = serde_json::to_value(action.response).expect("serialize response");
        assert_eq!(result["ok"], false);
        assert_eq!(result["error"]["code"], "unsupported-version");
    }
}
