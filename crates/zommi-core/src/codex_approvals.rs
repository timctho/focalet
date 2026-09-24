//! Server-initiated app-server approvals. IDs and replies stay opaque on the wire.
use super::*;

pub(super) struct PendingApproval {
    pub rpc_id: Value,
    pub session_id: String,
    pub turn_id: Option<String>,
    choices: Vec<(String, Value)>,
    denied: Value,
}

fn normalize(method: &str, params: &Value, rpc_id: Value) -> Option<(PendingApproval, Value)> {
    let (title, legacy, permissions) = match method {
        "item/commandExecution/requestApproval" => ("Run command", false, false),
        "item/fileChange/requestApproval" => ("Change files", false, false),
        "item/permissions/requestApproval" => ("Grant additional access", false, true),
        "execCommandApproval" => ("Run command", true, false),
        "applyPatchApproval" => ("Change files", true, false),
        _ => return None,
    };
    let session_id = params
        .get(if legacy { "conversationId" } else { "threadId" })?
        .as_str()?
        .to_owned();
    if session_id.is_empty() {
        return None;
    }
    let turn_id = params
        .get("turnId")
        .and_then(Value::as_str)
        .map(str::to_owned);
    let mut choices = Vec::new();
    let mut options = Vec::new();
    let mut add = |id: &str, name: &str, kind: &str, result: Value| {
        choices.push((id.to_owned(), result));
        options.push(json!({"optionId":id,"name":name,"kind":kind}));
    };
    let mut has_reject = false;
    let denied = if permissions {
        // Grant exactly the requested profile, never a broader inferred scope.
        let requested = params.get("permissions")?.as_object()?;
        let profile: serde_json::Map<String, Value> = requested
            .iter()
            .filter(|(key, _)| matches!(key.as_str(), "fileSystem" | "network"))
            .map(|(key, value)| (key.clone(), value.clone()))
            .collect();
        add(
            "allow_once",
            "Allow for this turn",
            "allow_once",
            json!({"permissions":profile,"scope":"turn"}),
        );
        add(
            "allow_session",
            "Allow for this session",
            "allow_always",
            json!({"permissions":profile,"scope":"session"}),
        );
        json!({"permissions":{},"scope":"turn"})
    } else if let Some(available) = params
        .get("availableDecisions")
        .and_then(Value::as_array)
        .filter(|_| !legacy)
    {
        for (index, decision) in available.iter().enumerate() {
            let (name, kind) = match decision.as_str() {
                Some("accept") => ("Allow once".to_owned(), "allow_once"),
                Some("acceptForSession") => ("Allow for this session".to_owned(), "allow_always"),
                Some("decline") => ("Deny".to_owned(), "reject_once"),
                Some("cancel") => ("Deny and stop".to_owned(), "reject_once"),
                _ if decision.get("acceptWithExecpolicyAmendment").is_some() => {
                    ("Always allow this command rule".to_owned(), "allow_always")
                }
                _ if decision.get("applyNetworkPolicyAmendment").is_some() => {
                    let rule = &decision["applyNetworkPolicyAmendment"]["network_policy_amendment"];
                    let host = rule["host"].as_str().unwrap_or("this host");
                    match rule["action"].as_str() {
                        Some("allow") => (
                            format!("Always allow network access to {host}"),
                            "allow_always",
                        ),
                        Some("deny") => {
                            (format!("Block network access to {host}"), "reject_always")
                        }
                        _ => continue,
                    }
                }
                _ => continue,
            };
            has_reject |= kind.starts_with("reject");
            add(
                &format!("decision-{index}"),
                &name,
                kind,
                json!({"decision":decision}),
            );
        }
        // Closing/expiring a prompt must never persist an allow or deny rule.
        json!({"decision": if available.iter().any(|value| value == "decline") { "decline" } else { "cancel" }})
    } else {
        add(
            "allow_once",
            "Allow once",
            "allow_once",
            json!({"decision":if legacy { "approved" } else { "accept" }}),
        );
        add(
            "allow_session",
            "Allow for this session",
            "allow_always",
            json!({"decision":if legacy { "approved_for_session" } else { "acceptForSession" }}),
        );
        json!({"decision":if legacy { "abort" } else { "decline" }})
    };
    if !has_reject {
        add(
            "reject_once",
            if legacy { "Deny and stop" } else { "Deny" },
            "reject_once",
            denied.clone(),
        );
    }
    let mut detail = params.clone();
    if let Some(object) = detail.as_object_mut() {
        for key in [
            "threadId",
            "conversationId",
            "turnId",
            "itemId",
            "callId",
            "approvalId",
            "startedAtMs",
        ] {
            object.remove(key);
        }
        object.retain(|_, value| !value.is_null());
    }
    Some((
        PendingApproval {
            rpc_id,
            session_id,
            turn_id,
            choices,
            denied,
        },
        json!({"toolCall":{"title":title,"rawInput":detail},"options":options}),
    ))
}

impl CodexAdapter {
    pub async fn resolve_approval(
        &self,
        session_id: &str,
        approval_id: &str,
        option_id: Option<&str>,
    ) -> Result<Value, CodexError> {
        self.inner
            .answer_approval(session_id, approval_id, option_id, "answered")
            .await
    }
}

impl Inner {
    async fn answer_approval(
        &self,
        session_id: &str,
        approval_id: &str,
        option_id: Option<&str>,
        reason: &str,
    ) -> Result<Value, CodexError> {
        let mut state = self.state.lock().await;
        let pending = state.approvals.get(approval_id).ok_or_else(|| {
            CodexError::new(
                "approval-expired",
                "This permission request has expired or was already answered.",
            )
        })?;
        if pending.session_id != session_id {
            return Err(CodexError::new(
                "identity-mismatch",
                "The permission request belongs to another chat.",
            ));
        }
        let result = match option_id {
            None => pending.denied.clone(),
            Some(id) => pending
                .choices
                .iter()
                .find(|(key, _)| key == id)
                .map(|(_, value)| value.clone())
                .ok_or_else(|| CodexError::new("invalid-request", "Unknown permission option."))?,
        };
        let pending = state.approvals.remove(approval_id).unwrap();
        drop(state);
        let result = self
            .write_json(&json!({"id":pending.rpc_id,"result":result}))
            .await;
        self.emit(
            "approval.resolved",
            Some(session_id),
            pending.turn_id.as_deref(),
            None,
            json!({"approvalId":approval_id,"reason":reason}),
        );
        result?;
        Ok(json!({"resolved":true,"approvalId":approval_id}))
    }

    pub(super) async fn handle_approval(self: &Arc<Self>, method: &str, message: &Value) -> bool {
        let Some((mut pending, mut payload)) =
            normalize(method, &message["params"], message["id"].clone())
        else {
            return false;
        };
        let mut state = self.state.lock().await;
        if pending.turn_id.is_none() {
            pending.turn_id = state.active_turns.get(&pending.session_id).cloned();
        }
        if state.exited
            || state.stopping
            || pending.turn_id.as_ref().is_some_and(|turn| {
                state
                    .completed_turns
                    .contains(&turn_key(&pending.session_id, turn))
            })
        {
            drop(state);
            let _ = self
                .write_json(&json!({"id":pending.rpc_id,"result":pending.denied}))
                .await;
            return true;
        }
        if let Some(item) = message["params"]
            .get("itemId")
            .and_then(Value::as_str)
            .and_then(|id| state.approval_items.get(id))
        {
            payload["toolCall"]["rawInput"]["changes"] = item.clone();
        }
        let id = uuid::Uuid::new_v4().to_string();
        let session_id = pending.session_id.clone();
        let turn_id = pending.turn_id.clone();
        payload["approvalId"] = json!(id);
        state.approvals.insert(id.clone(), pending);
        drop(state);
        self.emit(
            "approval.requested",
            Some(&session_id),
            turn_id.as_deref(),
            None,
            payload,
        );
        let weak = Arc::downgrade(self);
        let deadline = self.config.approval_timeout;
        tokio::spawn(async move {
            tokio::time::sleep(deadline).await;
            if let Some(inner) = weak.upgrade() {
                let _ = inner
                    .answer_approval(&session_id, &id, None, "expired")
                    .await;
            }
        });
        true
    }

    pub(super) async fn clear_approvals(
        &self,
        session: Option<&str>,
        turn: Option<&str>,
        rpc: Option<&Value>,
        reason: &str,
    ) {
        let mut state = self.state.lock().await;
        let ids: Vec<String> = state
            .approvals
            .iter()
            .filter(|(_, approval)| {
                session.is_none_or(|id| id == approval.session_id)
                    && turn.is_none_or(|id| approval.turn_id.as_deref() == Some(id))
                    && rpc.is_none_or(|id| id == &approval.rpc_id)
            })
            .map(|(id, _)| id.clone())
            .collect();
        for id in ids {
            let approval = state.approvals.remove(&id).unwrap();
            self.emit(
                "approval.resolved",
                Some(&approval.session_id),
                approval.turn_id.as_deref(),
                None,
                json!({"approvalId":id,"reason":reason}),
            );
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn replies_preserve_id_type_and_decision_dialect() {
        for (method, session_key, decision) in [
            ("execCommandApproval", "conversationId", "approved"),
            ("applyPatchApproval", "conversationId", "approved"),
            (
                "item/commandExecution/requestApproval",
                "threadId",
                "accept",
            ),
            ("item/fileChange/requestApproval", "threadId", "accept"),
        ] {
            for id in [json!(42), json!("42")] {
                let (pending, event) = normalize(
                    method,
                    &json!({session_key:"chat", "command":"echo test"}),
                    id.clone(),
                )
                .unwrap();
                assert_eq!(pending.rpc_id, id);
                assert_eq!(pending.choices[0].1, json!({"decision":decision}));
                assert_eq!(event["toolCall"]["rawInput"]["command"], "echo test");
                assert!(event["toolCall"]["rawInput"].get(session_key).is_none());
            }
        }
    }
    #[test]
    fn permissions_grant_only_requested_access_and_deny_grants_nothing() {
        let (pending, _) = normalize(
            "item/permissions/requestApproval",
            &json!({"threadId":"chat", "permissions":{"network":{"enabled":true}}}),
            json!(1),
        )
        .unwrap();
        assert_eq!(
            pending.choices[0].1,
            json!({"permissions":{"network":{"enabled":true}},"scope":"turn"})
        );
        assert_eq!(pending.denied, json!({"permissions":{},"scope":"turn"}));
        assert!(normalize("item/fileChange/requestApproval", &json!({}), json!(1)).is_none());
    }
    #[test]
    fn restricted_decisions_do_not_offer_unavailable_permissions() {
        let rule =
            json!({"acceptWithExecpolicyAmendment":{"execpolicy_amendment":["git", "status"]}});
        let (pending, event) = normalize(
            "item/commandExecution/requestApproval",
            &json!({"threadId":"chat", "availableDecisions":[rule, "decline"]}),
            json!(2),
        )
        .unwrap();
        assert_eq!(pending.choices.len(), 2);
        assert_eq!(pending.choices[0].1, json!({"decision":rule}));
        assert_eq!(pending.denied, json!({"decision":"decline"}));
        assert_eq!(
            event["options"][0]["name"],
            "Always allow this command rule"
        );
        assert!(
            !pending
                .choices
                .iter()
                .any(|(_, value)| value["decision"] == "acceptForSession")
        );
        let (pending, _) = normalize(
            "item/commandExecution/requestApproval",
            &json!({"threadId":"chat", "availableDecisions":[]}),
            json!(3),
        )
        .unwrap();
        assert_eq!(
            pending.choices,
            vec![("reject_once".into(), json!({"decision":"cancel"}))]
        );
    }

    #[tokio::test]
    async fn timeout_denies_on_the_wire_and_clears_the_prompt() {
        let root = std::env::temp_dir().join(format!("zommi-approval-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&root).unwrap();
        let python = if cfg!(windows) { "python" } else { "python3" };
        let environment = HashMap::from([
            (
                "ZOMMI_RUNTIME_DISCOVERY_MODE".into(),
                "configured-only".into(),
            ),
            ("ZOMMI_CODEX_COMMAND".into(), python.into()),
        ]);
        let target = crate::runtime_discovery::discover_runtime_targets_with(
            &environment,
            std::env::consts::OS,
        )
        .remove(0);
        let mut command = crate::runtime_discovery::command_for_target(&target);
        command.args = vec![
            format!(
                "{}/../zommi-core-host/tests/fake_codex_app_server.py",
                env!("CARGO_MANIFEST_DIR")
            ),
            "--control-dir".into(),
            root.to_string_lossy().into_owned(),
        ];
        let mut config = CodexConfig::new(target, command, root.clone(), None);
        config.approval_timeout = Duration::from_millis(25);
        let (events, mut received) = mpsc::unbounded_channel();
        let adapter = CodexAdapter::connect(config, events).await.unwrap();
        let session = adapter.active_session_id().await.unwrap();
        adapter
            .start_turn(CodexTurnRequest {
                session_id: &session,
                message: "request-approval:command",
                slash_command: false,
                snapshots: &[],
                images: &[],
                client_operation_id: "timeout-test",
                model: None,
                effort: None,
                cwd: None,
            })
            .await
            .unwrap();
        let approval = timeout(Duration::from_secs(5), async {
            let mut id = String::new();
            while let Some(event) = received.recv().await {
                if event.name == "approval.requested" {
                    id = event.payload["approvalId"].as_str().unwrap().to_owned();
                }
                if event.name == "approval.resolved" {
                    assert_eq!(event.payload["reason"], "expired");
                    assert_eq!(event.payload["approvalId"], id);
                    return id;
                }
            }
            panic!("Missing expiry event");
        })
        .await
        .unwrap();
        assert_eq!(
            adapter
                .resolve_approval(&session, &approval, Some("allow_once"))
                .await
                .unwrap_err()
                .code,
            "approval-expired"
        );
        // The fixture only finishes its turn after receiving the approval reply.
        timeout(Duration::from_secs(5), async {
            while let Some(event) = received.recv().await {
                if event.name == "turn.completed" {
                    return;
                }
            }
            panic!("Missing turn completion");
        })
        .await
        .unwrap();
        let log = std::fs::read_to_string(root.join("requests.jsonl")).unwrap();
        assert!(
            log.lines()
                .filter_map(|line| serde_json::from_str::<Value>(line).ok())
                .any(|value| value["id"] == 77 && value["result"]["decision"] == "decline")
        );
        adapter.shutdown().await;
        let _ = std::fs::remove_dir_all(root);
    }
}
