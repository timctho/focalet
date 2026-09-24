use std::{
    collections::{HashMap, HashSet},
    env, io,
    path::PathBuf,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader, BufWriter},
    sync::{mpsc, watch},
};
use uuid::Uuid;
use zommi_core::{
    ConfiguredRuntimeOverride, RuntimeDiscoveryCacheStore, RuntimeOverrideStore, SessionBinding,
    SessionBindingStore, build_context_handoff,
    codex_adapter::{CodexError, CoreEvent, EventSender},
    command_for_target, discover_runtime_targets_resilient_with_overrides, operation_fingerprint,
    runtime_adapter::{AdapterTurnRequest, RuntimeAdapter},
    runtime_discovery_settings, select_default_target, target_from_override,
    validate_broker_request, validate_turn_input,
};

mod wsl_relay;

#[cfg(target_os = "windows")]
mod windows_lifetime;

#[cfg(target_os = "linux")]
mod parent_lifetime;

const CORE_PROTOCOL_VERSION: u64 = 1;
const MAX_REQUEST_BYTES: usize = 64 * 1024 * 1024;
const WSL_PROBE_BACKOFF: Duration = Duration::from_secs(45);

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CoreRequest {
    id: Option<String>,
    protocol_version: Option<u64>,
    operation: Option<String>,
    #[serde(default)]
    timeout_ms: Option<u64>,
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
    adapters: HashMap<String, RuntimeAdapter>,
    prepared: HashSet<String>,
    binding_generation: Arc<Mutex<u64>>,
    request_generation: u64,
    binding_store: SessionBindingStore,
    override_store: RuntimeOverrideStore,
    discovery_cache: RuntimeDiscoveryCacheStore,
    wsl_probe_retry_at: Option<Instant>,
    overrides: Vec<ConfiguredRuntimeOverride>,
    operations: Arc<Mutex<HashMap<String, OperationRecord>>>,
    event_tx: EventSender,
}

#[derive(Clone)]
struct OperationRecord {
    fingerprint: String,
    outcome: Option<Result<Value, HostError>>,
}

impl HostState {
    fn new(event_tx: EventSender) -> Self {
        Self {
            targets: Vec::new(),
            adapters: HashMap::new(),
            prepared: HashSet::new(),
            binding_generation: Arc::new(Mutex::new(0)),
            request_generation: 0,
            binding_store: SessionBindingStore::platform_default(),
            override_store: RuntimeOverrideStore::platform_default(),
            discovery_cache: RuntimeDiscoveryCacheStore::platform_default(),
            wsl_probe_retry_at: None,
            overrides: Vec::new(),
            operations: Arc::new(Mutex::new(HashMap::new())),
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
                    "artifact.extract.v1",
                    "protocol.validation.v1",
                    "runtime.discovery.v1",
                    "runtime.overrides.v1",
                    "runtime.adapters.v1",
                    "runtime.prepare.v1",
                    "runtime.models.refresh.v1",
                    "session.binding.v1",
                    "session.list.v1",
                    "session.catalog.v1",
                    "session.create.v1",
                    "session.fork.v1",
                    "session.rewind.v1",
                    "session.resume.v1",
                    "session.configure.v1",
                    "history.read.v1",
                    "turn.stream.v1",
                    "turn.interrupt.v1",
                    "turn.steer.v1",
                    "approval.resolve.v1",
                    "question.resolve.v1"
                ]
            })),
            "core.cancelSelection" => {
                *self.binding_generation.lock().unwrap() += 1;
                Ok(json!({"cancelled":true}))
            }
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
                self.refresh_runtime_targets(
                    payload.get("force").and_then(Value::as_bool) == Some(true),
                )
                .await?;
                Ok(self.discovery_value(payload))
            }
            "runtime.addOverride" => {
                let mut value = payload.get("override").cloned().ok_or_else(|| {
                    HostError::new("invalid-request", "Runtime override is required.")
                })?;
                let object = value.as_object_mut().ok_or_else(|| {
                    HostError::new("invalid-request", "Runtime override must be an object.")
                })?;
                let generate_id = match object.get("id") {
                    None | Some(Value::Null) => true,
                    Some(Value::String(id)) => id.is_empty(),
                    Some(_) => false,
                };
                if generate_id {
                    object.insert(
                        "id".into(),
                        Value::String(format!("override-{}", Uuid::new_v4())),
                    );
                }
                let mut configured: ConfiguredRuntimeOverride = serde_json::from_value(value)
                    .map_err(|error| HostError::new("invalid-request", error.to_string()))?;
                if cfg!(windows) && configured.execution_host.kind == "wsl" {
                    let distribution = configured.execution_host.name.clone().unwrap_or_default();
                    let path = configured.executable_path.clone().unwrap_or_default();
                    let resolved = tokio::task::spawn_blocking(move || {
                        wsl_relay::resolve_runtime_executable(&distribution, path.trim())
                    })
                    .await
                    .map_err(|error| HostError::new("invalid-configuration", error.to_string()))?
                    .map_err(|error| HostError::new("invalid-configuration", error.to_string()))?;
                    configured.executable_path = Some(resolved);
                }
                let added_target = target_from_override(&configured, env::consts::OS)
                    .map_err(|message| HostError::new("invalid-configuration", message))?;
                self.overrides
                    .retain(|existing| existing.id != configured.id);
                self.overrides.push(configured);
                self.override_store
                    .save(&self.overrides)
                    .map_err(|error| HostError::new("persistence-failed", error.to_string()))?;
                self.refresh_runtime_targets(true).await?;
                let mut discovery = self.discovery_value(payload);
                discovery["selectedTargetId"] = json!(added_target.id);
                Ok(discovery)
            }
            "runtime.removeOverride" => {
                let override_id = required_string(payload, "overrideId")?;
                let previous = self.overrides.len();
                self.overrides.retain(|existing| existing.id != override_id);
                if previous == self.overrides.len() {
                    return Err(HostError::new(
                        "not-found",
                        "The runtime override no longer exists.",
                    ));
                }
                self.override_store
                    .save(&self.overrides)
                    .map_err(|error| HostError::new("persistence-failed", error.to_string()))?;
                self.refresh_runtime_targets(true).await?;
                Ok(self.discovery_value(payload))
            }
            "runtime.connect" => self.connect_runtime(payload, false, false).await,
            "runtime.prepare" => self.connect_runtime(payload, false, true).await,
            "runtime.refreshModels" => {
                let target_id = required_string(payload, "runtimeTargetId")?;
                let models = match self.adapters.get_mut(target_id) {
                    Some(adapter)
                        if !self.prepared.contains(target_id)
                            || matches!(
                                adapter,
                                RuntimeAdapter::Acp(_) | RuntimeAdapter::Claude(_)
                            ) =>
                    {
                        adapter.refresh_models().await?
                    }
                    _ => None,
                };
                Ok(json!({"models": models}))
            }
            "session.catalog" => {
                required_string(payload, "runtimeTargetId")?;
                self.connect_runtime(payload, true, false).await
            }
            "session.list" => {
                let adapter = self.exact_adapter(payload)?;
                Ok(json!({"data": adapter.list_sessions().await?}))
            }
            "session.create" => {
                let target_id = required_string(payload, "runtimeTargetId")?;
                let running = match self.adapters.get(target_id) {
                    Some(adapter) => adapter.is_running().await,
                    None => false,
                };
                if !running {
                    let preparable = self
                        .targets
                        .iter()
                        .find(|target| target.id == target_id)
                        .is_some_and(|target| {
                            RuntimeAdapter::supports_preparation(&target.adapter_id)
                        });
                    let mut fresh = payload.clone();
                    fresh["newSession"] = json!(true);
                    self.connect_runtime(&fresh, false, preparable).await?;
                }
                let adapter = self.exact_adapter(payload)?;
                let connection = adapter
                    .create_session(
                        payload.get("model").and_then(Value::as_str),
                        payload.get("effort").and_then(Value::as_str),
                        payload.get("cwd").and_then(Value::as_str),
                        payload.get("profile").and_then(Value::as_str),
                    )
                    .await?;
                self.prepared.remove(adapter.target_id());
                let session_id = adapter.active_session_id().await?;
                self.save_binding(
                    adapter.target_id(),
                    &session_id,
                    adapter.binding_metadata().await,
                    payload,
                )?;
                Ok(connection)
            }
            "session.fork" => {
                let adapter = self.exact_adapter(payload)?;
                let source_id = required_string(payload, "sessionId")?;
                let connection = adapter.fork_session(source_id).await?;
                let session_id = adapter.active_session_id().await?;
                let mut binding_payload = payload.clone();
                if let Some(cwd) = connection
                    .pointer("/sessionMetadata/cwd")
                    .and_then(Value::as_str)
                {
                    binding_payload["cwd"] = Value::String(cwd.into());
                }
                self.save_binding(
                    adapter.target_id(),
                    &session_id,
                    adapter.binding_metadata().await,
                    &binding_payload,
                )?;
                Ok(connection)
            }
            "session.open" => {
                let adapter = self.exact_adapter(payload)?;
                let session_id = required_string(payload, "sessionId")?;
                let connection = adapter
                    .open_session(
                        session_id,
                        payload.get("profile").and_then(Value::as_str),
                        payload.get("cwd").and_then(Value::as_str),
                    )
                    .await?;
                let active_session_id = adapter.active_session_id().await?;
                self.save_binding(
                    adapter.target_id(),
                    &active_session_id,
                    adapter.binding_metadata().await,
                    payload,
                )?;
                Ok(connection)
            }
            "session.configure" => {
                self.validate_workspace_payload(payload).await?;
                let adapter = self.exact_adapter(payload)?;
                let session_id = required_string(payload, "sessionId")?;
                let connection = adapter
                    .configure_session(
                        session_id,
                        payload.get("cwd").and_then(Value::as_str),
                        payload.get("profile").and_then(Value::as_str),
                        payload.get("model").and_then(Value::as_str),
                        payload.get("effort").and_then(Value::as_str),
                    )
                    .await?;
                let active_session_id = adapter.active_session_id().await?;
                self.save_binding(
                    adapter.target_id(),
                    &active_session_id,
                    adapter.binding_metadata().await,
                    payload,
                )?;
                Ok(connection)
            }
            "session.rewind.prepare" => {
                let adapter = self.exact_adapter(payload)?;
                Ok(adapter
                    .prepare_rewind(required_string(payload, "sessionId")?)
                    .await?)
            }
            "session.rewind" => {
                let adapter = self.exact_adapter(payload)?;
                let result = adapter
                    .rewind_session(
                        required_string(payload, "sessionId")?,
                        required_string(payload, "turnId")?,
                        required_string(payload, "expectedLastTurnId")?,
                    )
                    .await?;
                let active = adapter.active_session_id().await?;
                self.save_binding(
                    adapter.target_id(),
                    &active,
                    adapter.binding_metadata().await,
                    payload,
                )?;
                Ok(result)
            }
            "session.read" => {
                let adapter = self.exact_adapter(payload)?;
                let session_id = required_string(payload, "sessionId")?;
                Ok(adapter.read_session(session_id).await?)
            }
            "session.status" => {
                let adapter = self.exact_adapter(payload)?;
                Ok(adapter
                    .session_status(required_string(payload, "sessionId")?)
                    .await?)
            }
            "session.history.page" => Ok(self
                .exact_adapter(payload)?
                .read_history_page(
                    required_string(payload, "sessionId")?,
                    payload.get("cursor").and_then(Value::as_str),
                )
                .await?),
            "session.history.turn" => Ok(self
                .exact_adapter(payload)?
                .read_history_turn(
                    required_string(payload, "sessionId")?,
                    required_string(payload, "turnId")?,
                )
                .await?),
            "session.goal" => {
                let adapter = self.exact_adapter(payload)?;
                let session_id = required_string(payload, "sessionId")?;
                Ok(adapter.goal_command(session_id, payload).await?)
            }
            "session.commands" => {
                let adapter = self.exact_adapter(payload)?;
                let session_id = required_string(payload, "sessionId")?;
                tokio::time::timeout(
                    std::time::Duration::from_secs(5),
                    adapter.list_commands(
                        session_id,
                        payload
                            .get("force")
                            .and_then(Value::as_bool)
                            .unwrap_or(false),
                    ),
                )
                .await
                .map_err(|_| HostError::new("timeout", "Command discovery timed out."))?
                .map_err(Into::into)
            }
            "turn.start" | "command.execute" => {
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
                let input = validate_turn_input(message, snapshots, &images).map_err(|error| {
                    HostError {
                        code: error.code,
                        message: error.message,
                        retryable: error.retryable,
                    }
                })?;
                let fingerprint = operation_fingerprint(&json!({
                    "runtimeTargetId": adapter.target_id(),
                    "sessionId": session_id,
                    "command": operation == "command.execute",
                    "message": input.message,
                    "snapshots": input.snapshots,
                    "images": input.images,
                    "model": payload.get("model"),
                    "effort": payload.get("effort"),
                    "cwd": payload.get("cwd"),
                    "profile": payload.get("profile")
                }));
                {
                    let mut operations = self.operations.lock().unwrap();
                    if let Some(previous) = operations.get(&client_operation_id) {
                        if previous.fingerprint != fingerprint {
                            return Err(HostError::new(
                                "conflict",
                                "clientOperationId was reused for a different turn.",
                            ));
                        }
                        return previous.outcome.clone().unwrap_or_else(|| {
                            Err(HostError::new(
                                "runtime-overloaded",
                                "This operation is already being submitted.",
                            ))
                        });
                    }
                    // Reserve before awaiting the runtime so another worker
                    // cannot reuse this identity for a different target.
                    operations.insert(
                        client_operation_id.clone(),
                        OperationRecord {
                            fingerprint: fingerprint.clone(),
                            outcome: None,
                        },
                    );
                }
                let outcome = adapter
                    .start_turn(AdapterTurnRequest {
                        session_id,
                        message: &input.message,
                        slash_command: operation == "command.execute",
                        snapshots: &input.snapshots,
                        images: &input.images,
                        client_operation_id: &client_operation_id,
                        model: payload.get("model").and_then(Value::as_str),
                        effort: payload.get("effort").and_then(Value::as_str),
                        cwd: payload.get("cwd").and_then(Value::as_str),
                        profile: payload.get("profile").and_then(Value::as_str),
                    })
                    .await
                    .map_err(HostError::from)
                    .and_then(|receipt| serde_json::to_value(receipt).map_err(HostError::from));
                let mut operations = self.operations.lock().unwrap();
                operations.insert(
                    client_operation_id,
                    OperationRecord {
                        fingerprint,
                        outcome: Some(outcome.clone()),
                    },
                );
                if operations.len() > 512
                    && let Some(oldest) = operations
                        .iter()
                        .find(|(_, record)| record.outcome.is_some())
                        .map(|(id, _)| id.clone())
                {
                    operations.remove(&oldest);
                }
                outcome
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
            "turn.steer" => {
                let adapter = self.exact_adapter(payload)?;
                let images = payload
                    .get("images")
                    .and_then(Value::as_array)
                    .into_iter()
                    .flatten()
                    .map(|value| value.as_str().unwrap_or_default().to_owned())
                    .collect::<Vec<_>>();
                Ok(adapter
                    .steer_turn(
                        required_string(payload, "sessionId")?,
                        required_string(payload, "turnId")?,
                        required_string(payload, "message")?,
                        &images,
                    )
                    .await?)
            }
            "approval.resolve" => {
                let adapter = self.exact_adapter(payload)?;
                Ok(adapter
                    .resolve_approval(
                        required_string(payload, "sessionId")?,
                        required_string(payload, "approvalId")?,
                        payload.get("optionId").and_then(Value::as_str),
                    )
                    .await?)
            }
            "question.resolve" => {
                let adapter = self.exact_adapter(payload)?;
                Ok(adapter
                    .resolve_question(
                        required_string(payload, "sessionId")?,
                        required_string(payload, "questionId")?,
                        payload.get("answer").unwrap_or(&Value::Null),
                    )
                    .await?)
            }
            "core.shutdown" => {
                for (_, adapter) in std::mem::take(&mut self.adapters) {
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

    async fn refresh_runtime_targets(&mut self, force: bool) -> Result<(), HostError> {
        self.overrides = self
            .override_store
            .load()
            .map_err(|error| HostError::new("persistence-failed", error.to_string()))?;
        let overrides = self.overrides.clone();
        let cache = self.discovery_cache.clone();
        let now = Instant::now();
        let retry_allowed = force
            || self
                .wsl_probe_retry_at
                .is_none_or(|retry_at| now >= retry_at);
        let (outcome, probed_wsl) = tokio::task::spawn_blocking(move || {
            let cached = cache.load().unwrap_or_default();
            let relay_ready =
                cfg!(target_os = "windows") && wsl_relay::cached_default_relay_available(&cached);
            if retry_allowed && relay_ready {
                let mut outcome =
                    discover_runtime_targets_resilient_with_overrides(&overrides, &cache, false);
                if let Ok(discovered) = wsl_relay::discover_targets_via_cached_relays(&cached) {
                    // Replace only automatic/cached WSL entries. User-configured
                    // targets remain available even if their executable is not
                    // currently on the login shell PATH.
                    outcome.targets.retain(|target| {
                        target.execution_host.kind != "wsl"
                            || target.source.as_deref() == Some("configured-ui")
                    });
                    outcome.targets.extend(discovered.iter().cloned());
                    let mut seen = HashSet::new();
                    outcome
                        .targets
                        .retain(|target| seen.insert(target.id.clone()));
                    outcome.wsl_probe_succeeded = true;
                    let _ = cache.save(&discovered);
                }
                return (outcome, true);
            }
            let probe_wsl = retry_allowed;
            let outcome =
                discover_runtime_targets_resilient_with_overrides(&overrides, &cache, probe_wsl);
            (outcome, probe_wsl)
        })
        .await
        .map_err(|error| HostError::new("discovery-failed", error.to_string()))?;
        if probed_wsl {
            self.wsl_probe_retry_at = if outcome.wsl_probe_succeeded {
                None
            } else {
                Some(Instant::now() + WSL_PROBE_BACKOFF)
            };
        }
        self.targets = outcome.targets;
        Ok(())
    }

    fn discovery_value(&self, payload: &Value) -> Value {
        let binding = self.binding_store.load();
        let selected_target_id = select_default_target(
            &self.targets,
            binding
                .as_ref()
                .map(|value| value.runtime_target_id.as_str()),
            payload.get("lastSelectedTargetId").and_then(Value::as_str),
        )
        .map(|target| target.id.clone());
        json!({
            "targets": self.targets,
            "selectedTargetId": selected_target_id,
            "binding": binding,
            "settings": runtime_discovery_settings(&self.targets, &self.overrides)
        })
    }

    async fn connect_runtime(
        &mut self,
        payload: &Value,
        catalog_only: bool,
        prepare_only: bool,
    ) -> Result<Value, HostError> {
        if self.targets.is_empty() {
            self.refresh_runtime_targets(false).await?;
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
                    || "No supported agent runtime was found. Install a supported CLI, then refresh.".into(),
                    |target_id| format!("The exact runtime target '{target_id}' was not found."),
                ),
            )
        })?;

        if prepare_only && !RuntimeAdapter::supports_preparation(&target.adapter_id) {
            return Ok(json!({"prepared": false}));
        }

        let explicit_cwd = payload
            .get("cwd")
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
            .map(PathBuf::from);
        let requested_cwd = explicit_cwd
            .clone()
            .or_else(|| {
                binding
                    .as_ref()
                    .filter(|binding| binding.runtime_target_id == target.id)
                    .map(|binding| PathBuf::from(&binding.cwd))
            })
            .or_else(|| env::current_dir().ok())
            .unwrap_or_else(env::temp_dir);
        let cwd = if target.execution_host.kind == "wsl" && explicit_cwd.is_none() {
            target
                .runtime_home
                .as_deref()
                .map(PathBuf::from)
                .unwrap_or_else(|| PathBuf::from("/"))
        } else {
            requested_cwd
        };
        let explicit_session_id = payload
            .get("preferredSessionId")
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
            .map(str::to_owned);
        let preferred_session_id = explicit_session_id.clone().or_else(|| {
            if payload.get("newSession").and_then(Value::as_bool) == Some(true) {
                return None;
            }
            binding
                .as_ref()
                .filter(|binding| binding.runtime_target_id == target.id)
                .map(|binding| binding.session_id.clone())
        });
        let preferred_session_file = payload
            .get("preferredSessionFile")
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
            .map(str::to_owned)
            .or_else(|| {
                binding
                    .as_ref()
                    .filter(|binding| binding.runtime_target_id == target.id)
                    .filter(|binding| preferred_session_id.as_deref() == Some(&binding.session_id))
                    .and_then(|binding| binding.session_metadata.as_ref())
                    .and_then(|metadata| metadata.get("sessionFile"))
                    .and_then(Value::as_str)
                    .map(str::to_owned)
            });
        if let Some(adapter) = self.adapters.get(&target.id).cloned() {
            if adapter.is_running().await && catalog_only {
                return Ok(json!({"data": adapter.list_sessions().await?}));
            }
            if adapter.is_running().await {
                if prepare_only {
                    return Ok(json!({"prepared": true}));
                }
                let connection = if self.prepared.contains(&target.id) {
                    let activation = adapter
                        .activate(preferred_session_id.clone(), cwd.to_str())
                        .await;
                    if activation.is_err() {
                        self.adapters.remove(&target.id);
                        self.prepared.remove(&target.id);
                        adapter.shutdown().await;
                    }
                    let connection = activation?;
                    self.prepared.remove(&target.id);
                    connection
                } else {
                    adapter.connection_value().await?
                };
                let session_id = adapter.active_session_id().await?;
                self.persist_binding(SessionBinding {
                    runtime_target_id: adapter.target_id().to_owned(),
                    session_id,
                    cwd: cwd.to_string_lossy().into_owned(),
                    session_metadata: adapter.binding_metadata().await,
                })?;
                return Ok(connection);
            }
            if let Some(stale) = self.adapters.remove(&target.id) {
                self.prepared.remove(&target.id);
                stale.shutdown().await;
            }
        }
        let mut runtime_command = command_for_target(&target);
        let adapter_override = format!(
            "ZOMMI_{}_ARGS_JSON",
            target.adapter_id.to_ascii_uppercase().replace('-', "_")
        );
        let runtime_override =
            format!("ZOMMI_{}_ARGS_JSON", target.runtime_id.to_ascii_uppercase());
        if let Some(arguments) =
            env::var_os(adapter_override).or_else(|| env::var_os(runtime_override))
        {
            let parsed = serde_json::from_str::<Vec<String>>(&arguments.to_string_lossy())
                .map_err(|error| {
                    HostError::new(
                        "invalid-configuration",
                        format!("Runtime argument override is invalid: {error}"),
                    )
                })?;
            runtime_command.args = parsed;
        }
        if cfg!(target_os = "windows") && target.execution_host.kind == "wsl" {
            runtime_command = wsl_relay::wrap_wsl_command(&target, runtime_command)
                .map_err(|error| HostError::new("runtime-unavailable", error.to_string()))?;
        }
        if catalog_only || prepare_only {
            let adapter = RuntimeAdapter::connect_for_listing(
                target,
                runtime_command,
                cwd,
                self.event_tx.clone(),
            )
            .await?;
            if prepare_only {
                self.prepared.insert(adapter.target_id().to_owned());
                self.adapters
                    .insert(adapter.target_id().to_owned(), adapter);
                return Ok(json!({"prepared": true}));
            }
            // Listing has no selected session and must never persist a binding.
            let result = adapter.list_sessions().await;
            adapter.shutdown().await;
            return Ok(json!({"data": result?}));
        }
        let connection_attempt = RuntimeAdapter::connect(
            target.clone(),
            runtime_command.clone(),
            cwd.clone(),
            preferred_session_id.clone(),
            preferred_session_file,
            self.event_tx.clone(),
        )
        .await;
        let adapter = match connection_attempt {
            // A remembered empty/deleted Codex chat may have no persisted
            // rollout. It must not prevent startup or creating a new agent.
            // Explicit session selection and every other failure stay exact.
            Err(error)
                if error.code == "session-not-found"
                    && explicit_session_id.is_none()
                    && preferred_session_id.is_some() =>
            {
                RuntimeAdapter::connect(
                    target,
                    runtime_command,
                    cwd.clone(),
                    None,
                    None,
                    self.event_tx.clone(),
                )
                .await?
            }
            result => result?,
        };
        let connection = adapter.connection_value().await?;
        let runtime_target_id = adapter.target_id().to_owned();
        let session_id = adapter.active_session_id().await?;
        let session_metadata = adapter.binding_metadata().await;
        self.persist_binding(SessionBinding {
            runtime_target_id: runtime_target_id.clone(),
            session_id,
            cwd: cwd.to_string_lossy().into_owned(),
            session_metadata,
        })?;
        self.adapters.insert(runtime_target_id, adapter);
        Ok(connection)
    }

    fn exact_adapter(&self, payload: &Value) -> Result<RuntimeAdapter, HostError> {
        let requested = required_string(payload, "runtimeTargetId")?;
        let adapter = self.adapters.get(requested).ok_or_else(|| {
            HostError::new(
                "runtime-unavailable",
                "Connect this exact runtime target before using its sessions or turns.",
            )
        })?;
        Ok(adapter.clone())
    }

    async fn validate_workspace_payload(&self, payload: &Value) -> Result<(), HostError> {
        let Some(cwd) = payload
            .get("cwd")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
        else {
            return Ok(());
        };
        let target_id = required_string(payload, "runtimeTargetId")?;
        let target = self
            .targets
            .iter()
            .find(|target| target.id == target_id)
            .cloned()
            .ok_or_else(|| {
                HostError::new(
                    "runtime-unavailable",
                    "The workspace execution host is no longer available.",
                )
            })?;
        let absolute = if target.execution_host.kind == "wsl" {
            cwd.starts_with('/')
        } else {
            std::path::Path::new(cwd).is_absolute()
        };
        if !absolute || cwd.contains('\0') {
            return Err(HostError::new(
                "invalid-workspace",
                "Workspace must be an absolute folder path.",
            ));
        }

        let exists = match target.execution_host.kind.as_str() {
            "native" => std::path::Path::new(cwd).is_dir(),
            "wsl" if cfg!(target_os = "windows") => {
                let path = cwd.to_owned();
                tokio::task::spawn_blocking(move || {
                    wsl_relay::workspace_directory_exists(&target, &path)
                })
                .await
                .map_err(|error| {
                    HostError::new(
                        "workspace-validation-failed",
                        format!("Workspace validation stopped unexpectedly: {error}"),
                    )
                })?
                .map_err(|error| {
                    HostError::new(
                        "workspace-validation-failed",
                        format!("Could not validate the WSL workspace: {error}"),
                    )
                })?
            }
            "wsl" => std::path::Path::new(cwd).is_dir(),
            _ => {
                return Err(HostError::new(
                    "workspace-validation-failed",
                    "This execution host cannot validate workspace folders yet.",
                ));
            }
        };
        if !exists {
            return Err(HostError::new(
                "workspace-not-found",
                format!("Workspace folder does not exist: {cwd}"),
            ));
        }
        Ok(())
    }

    fn save_binding(
        &self,
        runtime_target_id: &str,
        session_id: &str,
        session_metadata: Option<Value>,
        payload: &Value,
    ) -> Result<(), HostError> {
        let cwd = payload
            .get("cwd")
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
            .map(str::to_owned)
            .or_else(|| {
                session_metadata
                    .as_ref()?
                    .get("cwd")?
                    .as_str()
                    .map(str::to_owned)
            })
            .or_else(|| {
                self.binding_store
                    .load()
                    .filter(|binding| binding.runtime_target_id == runtime_target_id)
                    .map(|binding| binding.cwd)
            })
            .or_else(|| {
                env::current_dir()
                    .ok()
                    .map(|path| path.to_string_lossy().into_owned())
            })
            .unwrap_or_default();
        self.persist_binding(SessionBinding {
            runtime_target_id: runtime_target_id.into(),
            session_id: session_id.into(),
            cwd,
            session_metadata,
        })
    }

    fn persist_binding(&self, binding: SessionBinding) -> Result<(), HostError> {
        // A slow connection from an older selection may finish after the user
        // has selected another runtime. Serialize the check and atomic save.
        let generation = self.binding_generation.lock().unwrap();
        if *generation != self.request_generation {
            return Ok(());
        }
        self.binding_store
            .save(&binding)
            .map_err(|error| HostError::new("persistence-failed", error.to_string()))
    }
}

#[derive(Debug, Clone)]
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

struct RuntimeWork {
    request: CoreRequest,
    targets: Vec<zommi_core::RuntimeTarget>,
    generation: u64,
    deadline: tokio::time::Instant,
}

struct RuntimeWorker {
    sender: mpsc::UnboundedSender<RuntimeWork>,
    task: tokio::task::JoinHandle<()>,
}

fn runtime_request_target(request: &CoreRequest) -> Option<&str> {
    if request.protocol_version != Some(CORE_PROTOCOL_VERSION)
        || request.id.as_deref().is_none_or(str::is_empty)
        || !request.payload.is_object()
    {
        return None;
    }
    let operation = request.operation.as_deref()?;
    if !(matches!(
        operation,
        "runtime.connect" | "runtime.prepare" | "runtime.refreshModels" | "command.execute"
    ) || operation.starts_with("session.")
        || operation.starts_with("turn.")
        || operation.starts_with("approval.")
        || operation.starts_with("question."))
    {
        return None;
    }
    request
        .payload
        .get("runtimeTargetId")?
        .as_str()
        .filter(|id| !id.is_empty())
}

fn selects_session(operation: Option<&str>) -> bool {
    matches!(
        operation,
        Some(
            "runtime.connect"
                | "session.open"
                | "session.create"
                | "session.fork"
                | "session.configure"
                | "session.rewind"
        )
    )
}

fn runtime_worker(
    event_tx: EventSender,
    binding_generation: Arc<Mutex<u64>>,
    operations: Arc<Mutex<HashMap<String, OperationRecord>>>,
    output: mpsc::UnboundedSender<Value>,
    mut shutdown: watch::Receiver<bool>,
) -> RuntimeWorker {
    let (sender, mut requests) = mpsc::unbounded_channel::<RuntimeWork>();
    let task = tokio::spawn(async move {
        let mut state = HostState::new(event_tx);
        state.binding_generation = binding_generation;
        state.operations = operations;
        loop {
            let work = tokio::select! {
                biased;
                _ = shutdown.changed() => break,
                work = requests.recv() => match work { Some(work) => work, None => break },
            };
            state.targets = work.targets;
            state.request_generation = work.generation;
            let request_id = work.request.id.clone();
            let operation = work.request.operation.clone().unwrap_or_default();
            let action = if tokio::time::Instant::now() >= work.deadline {
                failure(
                    request_id,
                    "request-expired",
                    "Request expired in the runtime queue and was not executed.",
                    true,
                )
            } else {
                tokio::select! {
                    biased;
                    _ = shutdown.changed() => break,
                    result = tokio::time::timeout_at(work.deadline, Box::pin(state.handle(work.request))) => {
                        result.unwrap_or_else(|_| failure(request_id, "runtime-timeout",
                            format!("Agent did not finish '{operation}' before its deadline. Retry the connection or choose another agent. Requests are not resent automatically."), true))
                    },
                }
            };
            if let Ok(value) = serde_json::to_value(action.response) {
                let _ = output.send(value);
            }
        }
        for (_, adapter) in std::mem::take(&mut state.adapters) {
            adapter.shutdown().await;
        }
    });
    RuntimeWorker { sender, task }
}

#[tokio::main]
async fn main() -> io::Result<()> {
    #[cfg(target_os = "windows")]
    windows_lifetime::contain_children()?;
    #[cfg(target_os = "linux")]
    parent_lifetime::bind_to_parent()?;
    let arguments = env::args().skip(1).collect::<Vec<_>>();
    let catalog_worker = arguments
        .iter()
        .any(|argument| argument == "--session-catalog-worker");
    if arguments
        .first()
        .is_some_and(|argument| argument == "--wsl-proxy")
    {
        let exit_code = match wsl_relay::run_proxy(&arguments[1..]) {
            Ok(code) => code,
            Err(error) => {
                eprintln!("Persistent WSL relay failed: {error}");
                70
            }
        };
        std::process::exit(exit_code);
    }
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
        let mut sequences = HashMap::<String, u64>::new();
        while let Some(mut event) = event_rx.recv().await {
            // Adapter replacements start their counters at zero. Sequence at
            // the host boundary so the UI accepts events after every restart.
            let sequence = sequences
                .entry(event.runtime_target_id.clone())
                .or_default();
            *sequence += 1;
            event.sequence = *sequence;
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
    let mut workers = HashMap::<String, RuntimeWorker>::new();
    let (shutdown_tx, shutdown_rx) = watch::channel(false);
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
                Ok(request)
                    if catalog_worker
                        && request.operation.as_deref() == Some("session.catalog") =>
                {
                    // This dedicated host only reads a catalog. Accept shutdown
                    // while a provider is starting so closing the UI cancels
                    // the read and drops its child processes promptly.
                    tokio::select! {
                        // Adapter futures are large in debug builds. Keep the
                        // cancellable catalog request off Windows' small main
                        // stack while still polling shutdown concurrently.
                        action = Box::pin(state.handle(request)) => action,
                        next = lines.next_line() => {
                            let shutdown = next?.filter(|line| line.len() <= MAX_REQUEST_BYTES)
                                .and_then(|line| serde_json::from_str::<CoreRequest>(&line).ok())
                                .filter(|request| request.protocol_version == Some(CORE_PROTOCOL_VERSION)
                                    && request.operation.as_deref() == Some("core.shutdown")
                                    && request.id.as_deref().is_some_and(|id| !id.is_empty())
                                    && request.payload.is_object());
                            HostAction {
                                response: match shutdown {
                                    Some(request) => success_response(request.id, json!({"shutdown": true})),
                                    None => failure(None, "core-closed", "Catalog worker input closed.", false).response,
                                },
                                shutdown: true,
                            }
                        }
                    }
                }
                Ok(mut request)
                    if !catalog_worker
                        && (runtime_request_target(&request).is_some()
                            || (request.operation.as_deref() == Some("runtime.connect")
                                && request.protocol_version == Some(CORE_PROTOCOL_VERSION)
                                && request.id.as_deref().is_some_and(|id| !id.is_empty())
                                && request.payload.is_object()
                                && request.payload.get("runtimeTargetId").is_none())) =>
                {
                    if state.targets.is_empty() {
                        // Legacy clients can connect before explicit discovery.
                        if let Err(error) = state.refresh_runtime_targets(false).await {
                            let action =
                                failure(request.id, error.code, error.message, error.retryable);
                            output_tx
                                .send(
                                    serde_json::to_value(action.response)
                                        .map_err(io::Error::other)?,
                                )
                                .map_err(|_| {
                                    io::Error::new(io::ErrorKind::BrokenPipe, "core output closed")
                                })?;
                            continue;
                        }
                    }
                    if request.payload.get("runtimeTargetId").is_none() {
                        if let Some(target_id) =
                            state.discovery_value(&json!({}))["selectedTargetId"].as_str()
                        {
                            request.payload["runtimeTargetId"] = json!(target_id);
                        } else {
                            let action = Box::pin(state.handle(request)).await;
                            let _ = output_tx.send(
                                serde_json::to_value(action.response).map_err(io::Error::other)?,
                            );
                            continue;
                        }
                    }
                    let target_id = runtime_request_target(&request).unwrap().to_owned();
                    let deadline = tokio::time::Instant::now()
                        + Duration::from_millis(
                            request.timeout_ms.unwrap_or(75_000).clamp(1, 120_000),
                        );
                    let generation = {
                        let mut current = state.binding_generation.lock().unwrap();
                        if selects_session(request.operation.as_deref()) {
                            *current += 1;
                        }
                        *current
                    };
                    let worker = workers.entry(target_id).or_insert_with(|| {
                        runtime_worker(
                            state.event_tx.clone(),
                            state.binding_generation.clone(),
                            state.operations.clone(),
                            output_tx.clone(),
                            shutdown_rx.clone(),
                        )
                    });
                    worker
                        .sender
                        .send(RuntimeWork {
                            request,
                            targets: state.targets.clone(),
                            generation,
                            deadline,
                        })
                        .map_err(|_| {
                            io::Error::new(io::ErrorKind::BrokenPipe, "runtime worker closed")
                        })?;
                    continue;
                }
                Ok(request) => Box::pin(state.handle(request)).await,
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
    let _ = shutdown_tx.send(true);
    for (_, worker) in workers {
        let _ = worker.task.await;
    }
    for (_, adapter) in std::mem::take(&mut state.adapters) {
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
    use std::fs;

    use serde_json::{Value, json};
    use tokio::sync::mpsc;
    use zommi_core::{ExecutionHost, RuntimeTarget};

    use super::{CORE_PROTOCOL_VERSION, CoreRequest, HostState};

    #[tokio::test]
    async fn expired_work_is_never_polled_and_does_not_block_later_requests() {
        let (events, _) = mpsc::unbounded_channel();
        let (output, mut responses) = mpsc::unbounded_channel();
        let (shutdown, receiver) = tokio::sync::watch::channel(false);
        let generation = std::sync::Arc::new(std::sync::Mutex::new(0));
        let worker = super::runtime_worker(
            events,
            generation.clone(),
            Default::default(),
            output,
            receiver,
        );
        for (id, operation, deadline) in [
            (
                "expired",
                "core.cancelSelection",
                tokio::time::Instant::now(),
            ),
            (
                "live",
                "core.initialize",
                tokio::time::Instant::now() + std::time::Duration::from_secs(5),
            ),
        ] {
            worker
                .sender
                .send(super::RuntimeWork {
                    request: CoreRequest {
                        id: Some(id.into()),
                        protocol_version: Some(CORE_PROTOCOL_VERSION),
                        operation: Some(operation.into()),
                        timeout_ms: None,
                        payload: json!({}),
                    },
                    targets: vec![],
                    generation: 0,
                    deadline,
                })
                .unwrap();
        }
        let expired = responses.recv().await.unwrap();
        assert_eq!(expired["error"]["code"], "request-expired");
        assert_eq!(
            *generation.lock().unwrap(),
            0,
            "expired handler was executed"
        );
        let live = responses.recv().await.unwrap();
        assert_eq!(live["id"], "live");
        assert!(live.get("error").is_none_or(Value::is_null));
        shutdown.send(true).unwrap();
        worker.task.await.unwrap();
    }

    #[tokio::test]
    async fn initializes_a_versioned_event_capable_core() {
        let (event_tx, _events) = mpsc::unbounded_channel();
        let mut host = HostState::new(event_tx);
        let action = host
            .handle(CoreRequest {
                timeout_ms: None,
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
        assert!(
            result["result"]["capabilities"]
                .as_array()
                .expect("capabilities")
                .contains(&Value::String("runtime.adapters.v1".into()))
        );
    }

    #[tokio::test]
    async fn builds_context_handoffs_over_the_host_protocol() {
        let (event_tx, _events) = mpsc::unbounded_channel();
        let mut host = HostState::new(event_tx);
        let action = host
            .handle(CoreRequest {
                timeout_ms: None,
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
                timeout_ms: None,
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

    #[tokio::test]
    async fn rejects_non_object_runtime_overrides_without_crashing() {
        let (event_tx, _events) = mpsc::unbounded_channel();
        let mut host = HostState::new(event_tx);
        let action = host
            .handle(CoreRequest {
                timeout_ms: None,
                id: Some("4".into()),
                protocol_version: Some(CORE_PROTOCOL_VERSION),
                operation: Some("runtime.addOverride".into()),
                payload: json!({"override": "not-an-object"}),
            })
            .await;
        let result = serde_json::to_value(action.response).expect("serialize response");
        assert_eq!(result["ok"], false);
        assert_eq!(result["error"]["code"], "invalid-request");
        assert_eq!(
            result["error"]["message"],
            "Runtime override must be an object."
        );
    }

    #[tokio::test]
    async fn validates_native_workspace_directories_before_configuration() {
        let (event_tx, _events) = mpsc::unbounded_channel();
        let mut host = HostState::new(event_tx);
        host.targets.push(RuntimeTarget {
            id: "runtime-test".into(),
            runtime_id: "codex".into(),
            adapter_id: "codex-app-server".into(),
            display_name: "Codex".into(),
            protocol_name: "Codex app-server".into(),
            executable_path: "/bin/false".into(),
            execution_host: ExecutionHost {
                id: format!("native:{}", std::env::consts::OS),
                kind: "native".into(),
                platform: std::env::consts::OS.into(),
                display_name: "Local".into(),
                is_default: true,
                name: None,
            },
            status: "ready".into(),
            priority: 0,
            capability_hints: Vec::new(),
            runtime_home: None,
            launch_path: None,
            source: None,
            endpoint: None,
            profile_id: None,
        });
        let root = std::env::temp_dir().join(format!("zommi-workspace-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&root).expect("create workspace fixture");
        let valid = json!({
            "runtimeTargetId": "runtime-test",
            "cwd": root.to_string_lossy()
        });
        host.validate_workspace_payload(&valid)
            .await
            .expect("existing workspace is valid");

        let missing = json!({
            "runtimeTargetId": "runtime-test",
            "cwd": root.join("missing").to_string_lossy()
        });
        let error = host
            .validate_workspace_payload(&missing)
            .await
            .expect_err("missing workspace must be rejected");
        assert_eq!(error.code, "workspace-not-found");

        let relative = json!({"runtimeTargetId": "runtime-test", "cwd": "relative/path"});
        let error = host
            .validate_workspace_payload(&relative)
            .await
            .expect_err("relative workspace must be rejected");
        assert_eq!(error.code, "invalid-workspace");
        fs::remove_dir_all(root).expect("remove workspace fixture");
    }
}
