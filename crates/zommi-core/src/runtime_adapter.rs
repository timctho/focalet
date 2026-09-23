use std::path::PathBuf;

use serde_json::Value;

use crate::{
    RuntimeCommand, RuntimeTarget,
    acp_adapter::{AcpAdapter, AcpConfig, AcpTurnRequest},
    codex_adapter::{CodexConfig, CodexError, CodexTurnRequest, EventSender, TurnReceipt},
    hermes_gateway_adapter::{HermesGatewayAdapter, HermesGatewayConfig, HermesGatewayTurnRequest},
    openclaw_gateway_adapter::{
        OpenClawGatewayAdapter, OpenClawGatewayConfig, OpenClawGatewayTurnRequest,
    },
    pi_adapter::{PiAdapter, PiConfig, PiTurnRequest},
    pty_adapter::{PtyAdapter, PtyConfig, PtyTurnRequest},
    supervised_codex::SupervisedCodex,
};

pub struct AdapterTurnRequest<'a> {
    pub session_id: &'a str,
    pub message: &'a str,
    pub slash_command: bool,
    pub snapshots: &'a [Value],
    pub images: &'a [String],
    pub client_operation_id: &'a str,
    pub model: Option<&'a str>,
    pub effort: Option<&'a str>,
    pub cwd: Option<&'a str>,
    pub profile: Option<&'a str>,
}

#[derive(Clone)]
pub enum RuntimeAdapter {
    Codex(SupervisedCodex),
    Acp(AcpAdapter),
    HermesGateway(HermesGatewayAdapter),
    OpenClawGateway(OpenClawGatewayAdapter),
    Pi(PiAdapter),
    Pty(PtyAdapter),
}

impl RuntimeAdapter {
    pub fn supports_preparation(adapter_id: &str) -> bool {
        matches!(
            adapter_id,
            "codex-app-server"
                | "hermes-acp"
                | "opencode-acp"
                | "openclaw-acp"
                | "hermes-gateway"
                | "openclaw-gateway"
        )
    }

    /// Select only after a caller chooses this runtime. Preparation itself has
    /// no active chat, history read, prompt, or persisted session binding.
    pub async fn activate(
        &self,
        session_id: Option<String>,
        cwd: Option<&str>,
    ) -> Result<Value, CodexError> {
        match self {
            Self::Codex(adapter) => adapter.activate(session_id, cwd).await?,
            Self::Acp(adapter) => adapter.activate(session_id.as_deref(), cwd).await?,
            Self::HermesGateway(adapter) => adapter.activate(session_id, cwd).await?,
            Self::OpenClawGateway(adapter) => adapter.activate(session_id).await?,
            _ => {
                return Err(CodexError {
                    code: "capability-unavailable".into(),
                    message: "This runtime requires a session to initialize.".into(),
                    retryable: false,
                });
            }
        }
        self.connection_value().await
    }
    pub async fn connect(
        target: RuntimeTarget,
        command: RuntimeCommand,
        cwd: PathBuf,
        preferred_session_id: Option<String>,
        preferred_session_file: Option<String>,
        event_tx: EventSender,
    ) -> Result<Self, CodexError> {
        Self::connect_with_mode(
            target,
            command,
            cwd,
            preferred_session_id,
            preferred_session_file,
            event_tx,
            false,
        )
        .await
    }

    pub async fn connect_for_listing(
        target: RuntimeTarget,
        command: RuntimeCommand,
        cwd: PathBuf,
        event_tx: EventSender,
    ) -> Result<Self, CodexError> {
        if !matches!(
            target.adapter_id.as_str(),
            "codex-app-server"
                | "hermes-gateway"
                | "hermes-acp"
                | "opencode-acp"
                | "openclaw-acp"
                | "openclaw-gateway"
        ) {
            return Err(CodexError {
                code: "capability-unavailable".into(),
                message: "This runtime does not support listing saved chats without opening one."
                    .into(),
                retryable: false,
            });
        }
        Self::connect_with_mode(target, command, cwd, None, None, event_tx, true).await
    }

    async fn connect_with_mode(
        target: RuntimeTarget,
        command: RuntimeCommand,
        cwd: PathBuf,
        preferred_session_id: Option<String>,
        preferred_session_file: Option<String>,
        event_tx: EventSender,
        list_only: bool,
    ) -> Result<Self, CodexError> {
        match target.adapter_id.as_str() {
            "codex-app-server" => Ok(Self::Codex(
                SupervisedCodex::connect(
                    CodexConfig {
                        list_only,
                        ..CodexConfig::new(target, command, cwd, preferred_session_id)
                    },
                    event_tx,
                )
                .await?,
            )),
            "hermes-acp" | "openclaw-acp" | "opencode-acp" => Ok(Self::Acp(
                AcpAdapter::connect(
                    AcpConfig {
                        target,
                        command,
                        cwd,
                        preferred_session_id,
                        list_only,
                    },
                    event_tx,
                )
                .await?,
            )),
            "hermes-gateway" => Ok(Self::HermesGateway(
                HermesGatewayAdapter::connect(
                    HermesGatewayConfig {
                        target,
                        command,
                        cwd,
                        preferred_session_id,
                        list_only,
                    },
                    event_tx,
                )
                .await?,
            )),
            "openclaw-gateway" => Ok(Self::OpenClawGateway(
                OpenClawGatewayAdapter::connect(
                    OpenClawGatewayConfig {
                        target,
                        preferred_session_id,
                        list_only,
                    },
                    event_tx,
                )
                .await?,
            )),
            "pi-rpc" | "grok-pi-rpc" => Ok(Self::Pi(
                PiAdapter::connect(
                    PiConfig {
                        target,
                        command,
                        cwd,
                        preferred_session_id,
                        preferred_session_file,
                    },
                    event_tx,
                )
                .await?,
            )),
            "pty-compatibility" => Ok(Self::Pty(
                PtyAdapter::connect(
                    PtyConfig {
                        target,
                        command,
                        cwd,
                    },
                    event_tx,
                )
                .await?,
            )),
            adapter_id => Err(CodexError {
                code: "capability-unavailable".into(),
                message: format!("Rust adapter '{adapter_id}' is not supported."),
                retryable: false,
            }),
        }
    }

    pub fn target_id(&self) -> &str {
        match self {
            Self::Codex(adapter) => adapter.target_id(),
            Self::Acp(adapter) => adapter.target_id(),
            Self::HermesGateway(adapter) => adapter.target_id(),
            Self::OpenClawGateway(adapter) => adapter.target_id(),
            Self::Pi(adapter) => adapter.target_id(),
            Self::Pty(adapter) => adapter.target_id(),
        }
    }

    pub async fn is_running(&self) -> bool {
        match self {
            Self::Codex(adapter) => adapter.is_running().await,
            Self::Acp(adapter) => adapter.is_running().await,
            Self::HermesGateway(adapter) => adapter.is_running().await,
            Self::OpenClawGateway(adapter) => adapter.is_running().await,
            Self::Pi(adapter) => adapter.is_running().await,
            Self::Pty(_) => true,
        }
    }

    pub async fn active_session_id(&self) -> Result<String, CodexError> {
        match self {
            Self::Codex(adapter) => adapter.ready().await?.active_session_id().await,
            Self::Acp(adapter) => adapter.active_session_id().await,
            Self::HermesGateway(adapter) => adapter.active_session_id().await,
            Self::OpenClawGateway(adapter) => adapter.active_session_id().await,
            Self::Pi(adapter) => adapter.active_session_id().await,
            Self::Pty(adapter) => Ok(adapter.active_session_id()),
        }
    }

    pub async fn connection_value(&self) -> Result<Value, CodexError> {
        match self {
            Self::Codex(adapter) => {
                serde_json::to_value(adapter.ready().await?.connection().await?).map_err(|error| {
                    CodexError {
                        code: "protocol-error".into(),
                        message: error.to_string(),
                        retryable: false,
                    }
                })
            }
            Self::Acp(adapter) => adapter.connection_value().await,
            Self::HermesGateway(adapter) => adapter.connection_value().await,
            Self::OpenClawGateway(adapter) => adapter.connection_value().await,
            Self::Pi(adapter) => adapter.connection_value().await,
            Self::Pty(adapter) => Ok(adapter.connection_value().await),
        }
    }

    /// Refresh only inventory; never select a chat or persist a new binding.
    pub async fn refresh_models(&mut self) -> Result<Option<Vec<Value>>, CodexError> {
        let models = match self {
            Self::Codex(adapter) => adapter.ready().await?.load_models().await?,
            Self::Acp(adapter) => {
                let replacement = adapter.refreshed().await?;
                let models = replacement.model_inventory().await;
                *adapter = replacement;
                return Ok(models);
            }
            Self::Pi(adapter) => adapter.refresh_models().await?,
            Self::HermesGateway(adapter) => adapter.reload_models().await?,
            Self::OpenClawGateway(adapter) => adapter.reload_models().await?,
            Self::Pty(_) => return Ok(None),
        };
        Ok(Some(models))
    }

    pub async fn list_sessions(&self) -> Result<Vec<Value>, CodexError> {
        match self {
            Self::Codex(adapter) => adapter.ready().await?.list_sessions().await,
            Self::Acp(adapter) => adapter.list_sessions().await,
            Self::HermesGateway(adapter) => adapter.list_sessions().await,
            Self::OpenClawGateway(adapter) => adapter.list_sessions().await,
            Self::Pi(adapter) => adapter.list_sessions().await,
            Self::Pty(adapter) => {
                let connection = adapter.connection_value().await;
                Ok(connection
                    .get("sessions")
                    .and_then(Value::as_array)
                    .cloned()
                    .unwrap_or_default())
            }
        }
    }

    pub async fn create_session(
        &self,
        model: Option<&str>,
        effort: Option<&str>,
        cwd: Option<&str>,
        profile: Option<&str>,
    ) -> Result<Value, CodexError> {
        match self {
            Self::Codex(adapter) => {
                let connection = adapter
                    .ready()
                    .await?
                    .create_session(model, effort, cwd)
                    .await?;
                adapter.ensure_monitor().await;
                serde_json::to_value(connection).map_err(|error| CodexError {
                    code: "protocol-error".into(),
                    message: error.to_string(),
                    retryable: false,
                })
            }
            Self::Acp(adapter) => adapter.create_session(model).await,
            Self::HermesGateway(adapter) => {
                adapter.create_session(model, effort, cwd, profile).await
            }
            Self::OpenClawGateway(adapter) => adapter.create_session(model, effort).await,
            Self::Pi(adapter) => adapter.create_session(model, effort).await,
            Self::Pty(_) => Err(CodexError {
                code: "capability-unavailable".into(),
                message: "Terminal compatibility creates a new session only by reconnecting."
                    .into(),
                retryable: false,
            }),
        }
    }

    pub async fn fork_session(&self, session_id: &str) -> Result<Value, CodexError> {
        match self {
            Self::Codex(adapter) => {
                serde_json::to_value(adapter.ready().await?.fork_session(session_id).await?)
                    .map_err(|error| CodexError {
                        code: "protocol-error".into(),
                        message: error.to_string(),
                        retryable: false,
                    })
            }
            _ => Err(CodexError {
                code: "capability-unavailable".into(),
                message: "This runtime does not support duplicating chats.".into(),
                retryable: false,
            }),
        }
    }

    pub async fn rewind_session(
        &self,
        session_id: &str,
        turn_id: &str,
        expected_last_turn_id: &str,
    ) -> Result<Value, CodexError> {
        match self {
            Self::Codex(adapter) => {
                adapter
                    .ready()
                    .await?
                    .rewind_session(session_id, turn_id, expected_last_turn_id)
                    .await
            }
            Self::Pi(adapter) => {
                adapter
                    .rewind_session(session_id, turn_id, expected_last_turn_id)
                    .await
            }
            Self::HermesGateway(adapter) => {
                adapter
                    .rewind_session(session_id, turn_id, expected_last_turn_id)
                    .await
            }
            Self::OpenClawGateway(adapter) => {
                adapter
                    .rewind_session(session_id, turn_id, expected_last_turn_id)
                    .await
            }
            _ => Err(CodexError {
                code: "capability-unavailable".into(),
                message: "This runtime does not support editing earlier messages.".into(),
                retryable: false,
            }),
        }
    }

    pub async fn prepare_rewind(&self, session_id: &str) -> Result<Value, CodexError> {
        match self {
            Self::Pi(adapter) => adapter.prepare_rewind(session_id).await,
            Self::HermesGateway(adapter) => adapter.prepare_rewind(session_id).await,
            Self::OpenClawGateway(adapter) => adapter.prepare_rewind(session_id).await,
            _ => Err(CodexError {
                code: "capability-unavailable".into(),
                message: "This connection does not expose rewind preparation.".into(),
                retryable: false,
            }),
        }
    }

    pub async fn open_session(
        &self,
        session_id: &str,
        profile: Option<&str>,
        cwd: Option<&str>,
    ) -> Result<Value, CodexError> {
        match self {
            Self::Codex(adapter) => {
                serde_json::to_value(adapter.ready().await?.open_session(session_id).await?)
                    .map_err(|error| CodexError {
                        code: "protocol-error".into(),
                        message: error.to_string(),
                        retryable: false,
                    })
            }
            Self::Acp(adapter) => adapter.open_session(session_id).await,
            Self::HermesGateway(adapter) => adapter.open_session(session_id, profile).await,
            Self::OpenClawGateway(adapter) => adapter.open_session(session_id).await,
            Self::Pi(adapter) => adapter.open_session(session_id, cwd).await,
            Self::Pty(_) => Err(CodexError {
                code: "capability-unavailable".into(),
                message: "Terminal compatibility does not provide canonical session resume.".into(),
                retryable: false,
            }),
        }
    }

    pub async fn configure_session(
        &self,
        session_id: &str,
        cwd: Option<&str>,
        profile: Option<&str>,
        model: Option<&str>,
        effort: Option<&str>,
    ) -> Result<Value, CodexError> {
        match self {
            Self::Codex(adapter) => serde_json::to_value(
                adapter
                    .ready()
                    .await?
                    .configure_session(session_id, cwd)
                    .await?,
            )
            .map_err(|error| CodexError {
                code: "protocol-error".into(),
                message: error.to_string(),
                retryable: false,
            }),
            Self::HermesGateway(adapter) => {
                adapter
                    .configure_session(session_id, cwd, profile, model, effort)
                    .await
            }
            _ => Err(CodexError {
                code: "capability-unavailable".into(),
                message: "This runtime cannot change the workspace of a live session.".into(),
                retryable: false,
            }),
        }
    }

    pub async fn read_session(&self, session_id: &str) -> Result<Value, CodexError> {
        match self {
            Self::Codex(adapter) => adapter.ready().await?.read_session(session_id).await,
            Self::Acp(adapter) => adapter.read_session(session_id).await,
            Self::HermesGateway(adapter) => adapter.read_session(session_id).await,
            Self::OpenClawGateway(adapter) => adapter.read_session(session_id).await,
            Self::Pi(adapter) => adapter.read_session(session_id).await,
            Self::Pty(adapter) => adapter.read_session(session_id).await,
        }
    }

    pub async fn read_history_page(
        &self,
        session_id: &str,
        cursor: Option<&str>,
    ) -> Result<Value, CodexError> {
        match self {
            Self::Codex(adapter) => {
                adapter
                    .ready()
                    .await?
                    .read_history_page(session_id, cursor)
                    .await
            }
            _ => Err(CodexError {
                code: "capability-unavailable".into(),
                message: "This runtime does not expose paginated history.".into(),
                retryable: false,
            }),
        }
    }

    pub async fn read_history_turn(
        &self,
        session_id: &str,
        turn_id: &str,
    ) -> Result<Value, CodexError> {
        match self {
            Self::Codex(adapter) => {
                adapter
                    .ready()
                    .await?
                    .read_history_turn(session_id, turn_id)
                    .await
            }
            _ => Err(CodexError {
                code: "capability-unavailable".into(),
                message: "This runtime does not expose turn details.".into(),
                retryable: false,
            }),
        }
    }

    pub async fn list_commands(&self, session_id: &str, force: bool) -> Result<Value, CodexError> {
        if self.active_session_id().await? != session_id {
            return Err(crate::command_catalog::error(
                "Command catalog belongs to a different session.",
            ));
        }
        let commands = match self {
            Self::Codex(a) => a.ready().await?.list_commands(session_id, force).await?,
            Self::Acp(a) => a.list_commands(session_id, force).await?,
            Self::Pi(a) => a.list_commands(session_id, force).await?,
            Self::HermesGateway(a) => a.list_commands(session_id, force).await?,
            Self::OpenClawGateway(a) => a.list_commands(session_id, force).await?,
            Self::Pty(_) => {
                return Err(crate::command_catalog::error(
                    "Terminal compatibility does not expose command discovery.",
                ));
            }
        };
        Ok(serde_json::json!({"commands":commands}))
    }

    pub async fn start_turn(
        &self,
        request: AdapterTurnRequest<'_>,
    ) -> Result<TurnReceipt, CodexError> {
        if request.slash_command {
            if !request.snapshots.is_empty() || !request.images.is_empty() {
                return Err(crate::command_catalog::error(
                    "Send or remove attachments before running a command.",
                ));
            }
            let catalog = self.list_commands(request.session_id, false).await?;
            crate::command_catalog::require_command(
                catalog["commands"].as_array().unwrap(),
                request.message,
            )?;
        }
        match self {
            Self::Codex(adapter) => {
                adapter
                    .ready()
                    .await?
                    .start_turn(CodexTurnRequest {
                        session_id: request.session_id,
                        message: request.message,
                        slash_command: request.slash_command,
                        snapshots: request.snapshots,
                        images: request.images,
                        client_operation_id: request.client_operation_id,
                        model: request.model,
                        effort: request.effort,
                        cwd: request.cwd,
                    })
                    .await
            }
            Self::Acp(adapter) => {
                adapter
                    .start_turn(AcpTurnRequest {
                        session_id: request.session_id,
                        message: request.message,
                        slash_command: request.slash_command,
                        snapshots: request.snapshots,
                        images: request.images,
                        client_operation_id: request.client_operation_id,
                        model: request.model,
                    })
                    .await
            }
            Self::HermesGateway(adapter) => {
                adapter
                    .start_turn(HermesGatewayTurnRequest {
                        session_id: request.session_id,
                        message: request.message,
                        slash_command: request.slash_command,
                        snapshots: request.snapshots,
                        images: request.images,
                        client_operation_id: request.client_operation_id,
                        model: request.model,
                        effort: request.effort,
                    })
                    .await
            }
            Self::OpenClawGateway(adapter) => {
                adapter
                    .start_turn(OpenClawGatewayTurnRequest {
                        session_id: request.session_id,
                        message: request.message,
                        slash_command: request.slash_command,
                        snapshots: request.snapshots,
                        images: request.images,
                        client_operation_id: request.client_operation_id,
                        model: request.model,
                        effort: request.effort,
                    })
                    .await
            }
            Self::Pi(adapter) => {
                adapter
                    .start_turn(PiTurnRequest {
                        session_id: request.session_id,
                        message: request.message,
                        slash_command: request.slash_command,
                        snapshots: request.snapshots,
                        images: request.images,
                        client_operation_id: request.client_operation_id,
                        model: request.model,
                        effort: request.effort,
                    })
                    .await
            }
            Self::Pty(adapter) => {
                adapter
                    .start_turn(PtyTurnRequest {
                        session_id: request.session_id,
                        message: request.message,
                        snapshots: request.snapshots,
                        images: request.images,
                        client_operation_id: request.client_operation_id,
                    })
                    .await
            }
        }
    }

    pub async fn interrupt_turn(
        &self,
        session_id: &str,
        turn_id: &str,
    ) -> Result<Value, CodexError> {
        match self {
            Self::Codex(adapter) => {
                adapter
                    .ready()
                    .await?
                    .interrupt_turn(session_id, turn_id)
                    .await
            }
            Self::Acp(adapter) => adapter.interrupt_turn(session_id, turn_id).await,
            Self::HermesGateway(adapter) => adapter.interrupt_turn(session_id, turn_id).await,
            Self::OpenClawGateway(adapter) => adapter.interrupt_turn(session_id, turn_id).await,
            Self::Pi(adapter) => adapter.interrupt_turn(session_id, turn_id).await,
            Self::Pty(_) => Err(CodexError {
                code: "capability-unavailable".into(),
                message:
                    "This terminal compatibility profile does not advertise reliable interruption."
                        .into(),
                retryable: false,
            }),
        }
    }

    pub async fn session_status(&self, session_id: &str) -> Result<Value, CodexError> {
        match self {
            Self::Codex(adapter) => adapter.ready().await?.session_status(session_id).await,
            _ => Err(CodexError {
                code: "capability-unavailable".into(),
                message: "Status is not advertised by this runtime.".into(),
                retryable: false,
            }),
        }
    }

    pub async fn goal_command(
        &self,
        session_id: &str,
        payload: &Value,
    ) -> Result<Value, CodexError> {
        match self {
            Self::Codex(adapter) => {
                adapter
                    .ready()
                    .await?
                    .goal_command(session_id, payload)
                    .await
            }
            _ => Err(CodexError {
                code: "capability-unavailable".into(),
                message: "Goal commands are available for Codex chats.".into(),
                retryable: false,
            }),
        }
    }

    pub async fn resolve_approval(
        &self,
        session_id: &str,
        approval_id: &str,
        option_id: Option<&str>,
    ) -> Result<Value, CodexError> {
        match self {
            Self::Acp(adapter) => {
                adapter
                    .resolve_approval(session_id, approval_id, option_id)
                    .await
            }
            Self::HermesGateway(adapter) => {
                adapter
                    .resolve_approval(session_id, approval_id, option_id)
                    .await
            }
            Self::OpenClawGateway(adapter) => {
                adapter
                    .resolve_approval(session_id, approval_id, option_id)
                    .await
            }
            Self::Codex(_) => Err(CodexError {
                code: "capability-unavailable".into(),
                message: "This Codex target does not expose structured approvals.".into(),
                retryable: false,
            }),
            Self::Pi(_) => Err(CodexError {
                code: "capability-unavailable".into(),
                message: "Pi does not expose structured approvals.".into(),
                retryable: false,
            }),
            Self::Pty(_) => Err(CodexError {
                code: "capability-unavailable".into(),
                message: "Terminal compatibility does not expose structured approvals.".into(),
                retryable: false,
            }),
        }
    }

    pub async fn shutdown(&self) {
        match self {
            Self::Codex(adapter) => adapter.shutdown().await,
            Self::Acp(adapter) => adapter.shutdown().await,
            Self::HermesGateway(adapter) => adapter.shutdown().await,
            Self::OpenClawGateway(adapter) => adapter.shutdown().await,
            Self::Pi(adapter) => adapter.shutdown().await,
            Self::Pty(adapter) => adapter.shutdown().await,
        }
    }

    pub async fn steer_turn(
        &self,
        session_id: &str,
        turn_id: &str,
        message: &str,
        images: &[String],
    ) -> Result<Value, CodexError> {
        match self {
            Self::Pi(adapter) => {
                adapter
                    .steer_turn(session_id, turn_id, message, images)
                    .await
            }
            _ => Err(CodexError {
                code: "capability-unavailable".into(),
                message: "The selected runtime does not support same-turn steering.".into(),
                retryable: false,
            }),
        }
    }

    pub async fn resolve_question(
        &self,
        session_id: &str,
        question_id: &str,
        answer: &Value,
    ) -> Result<Value, CodexError> {
        match self {
            Self::Pi(adapter) => {
                adapter
                    .resolve_question(session_id, question_id, answer)
                    .await
            }
            Self::HermesGateway(adapter) => {
                adapter
                    .resolve_question(session_id, question_id, answer)
                    .await
            }
            Self::OpenClawGateway(adapter) => {
                adapter
                    .resolve_question(session_id, question_id, answer)
                    .await
            }
            _ => Err(CodexError {
                code: "capability-unavailable".into(),
                message: "The selected runtime does not expose structured questions.".into(),
                retryable: false,
            }),
        }
    }

    pub async fn binding_metadata(&self) -> Option<Value> {
        match self {
            Self::Pi(adapter) => adapter.binding_metadata().await,
            Self::HermesGateway(adapter) => adapter.binding_metadata().await,
            Self::OpenClawGateway(adapter) => adapter
                .active_session_id()
                .await
                .ok()
                .map(|session_id| serde_json::json!({"sessionKey": session_id})),
            _ => None,
        }
    }
}
