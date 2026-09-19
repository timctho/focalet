//! Keeps a connected Codex runtime alive without replaying application requests.
use std::sync::{
    Arc, Weak,
    atomic::{AtomicBool, Ordering},
};

use tokio::{
    sync::{Mutex, Notify, RwLock, RwLockReadGuard, watch},
    task::JoinHandle,
    time::{Duration, Instant, timeout},
};

use crate::codex_adapter::{CodexAdapter, CodexConfig, CodexError, EventSender};

#[derive(Clone, Copy)]
struct HealthPolicy {
    poll: Duration,
    probe_interval: Duration,
    probe_timeout: Duration,
    retry_base: Duration,
    retry_max: Duration,
}

impl Default for HealthPolicy {
    fn default() -> Self {
        Self {
            poll: Duration::from_secs(1),
            probe_interval: Duration::from_secs(15),
            probe_timeout: Duration::from_secs(5),
            retry_base: Duration::from_secs(1),
            retry_max: Duration::from_secs(30),
        }
    }
}

#[derive(Clone)]
pub struct SupervisedCodex {
    inner: Arc<Inner>,
}

struct Inner {
    target_id: String,
    adapter: RwLock<CodexAdapter>,
    stopped: AtomicBool,
    wake: Notify,
    changed: watch::Sender<()>,
    task: Mutex<Option<JoinHandle<()>>>,
}

impl SupervisedCodex {
    pub async fn connect(config: CodexConfig, events: EventSender) -> Result<Self, CodexError> {
        Self::connect_with_policy(config, events, HealthPolicy::default()).await
    }

    async fn connect_with_policy(
        config: CodexConfig,
        events: EventSender,
        policy: HealthPolicy,
    ) -> Result<Self, CodexError> {
        let supervise = !config.list_only;
        let adapter = CodexAdapter::connect(config, events).await?;
        let runtime = Self {
            inner: Arc::new(Inner {
                target_id: adapter.target_id().to_owned(),
                adapter: RwLock::new(adapter),
                stopped: AtomicBool::new(false),
                wake: Notify::new(),
                changed: watch::channel(()).0,
                task: Mutex::new(None),
            }),
        };
        if supervise {
            let weak = Arc::downgrade(&runtime.inner);
            *runtime.inner.task.lock().await = Some(tokio::spawn(monitor(weak, policy)));
        }
        Ok(runtime)
    }

    pub fn target_id(&self) -> &str {
        &self.inner.target_id
    }

    pub async fn activate(
        &self,
        session_id: Option<String>,
        cwd: Option<&str>,
    ) -> Result<(), CodexError> {
        self.ready().await?.activate(session_id, cwd).await?;
        let mut task = self.inner.task.lock().await;
        if task.is_none() && !self.inner.stopped.load(Ordering::Acquire) {
            *task = Some(tokio::spawn(monitor(
                Arc::downgrade(&self.inner),
                HealthPolicy::default(),
            )));
        }
        Ok(())
    }

    // The host must retain this supervisor while it replaces the child.
    pub async fn is_running(&self) -> bool {
        if self.inner.stopped.load(Ordering::Acquire) {
            return false;
        }
        // A prepared transport has no supervisor until a chat is selected.
        if self.inner.task.lock().await.is_none() {
            return self.inner.adapter.read().await.is_running().await;
        }
        true
    }

    pub async fn ready(&self) -> Result<RwLockReadGuard<'_, CodexAdapter>, CodexError> {
        timeout(Duration::from_secs(15), async {
            let mut changed = self.inner.changed.subscribe();
            loop {
                if self.inner.stopped.load(Ordering::Acquire) {
                    return Err(recovery_error("Codex runtime was closed."));
                }
                let adapter = self.inner.adapter.read().await;
                if adapter.is_running().await { return Ok(adapter); }
                drop(adapter);
                self.inner.wake.notify_one();
                if changed.changed().await.is_err() {
                    return Err(recovery_error("Codex runtime was closed."));
                }
            }
        }).await.unwrap_or_else(|_| Err(recovery_error(
            "Codex is reconnecting. This request was not sent; try again when the connection is ready.",
        )))
    }

    pub async fn shutdown(&self) {
        self.inner.stopped.store(true, Ordering::Release);
        self.inner.changed.send_replace(());
        if let Some(task) = self.inner.task.lock().await.take() {
            task.abort();
            let _ = task.await;
        }
        self.inner.adapter.write().await.shutdown().await;
    }
}

fn recovery_error(message: &str) -> CodexError {
    CodexError {
        code: "runtime-recovering".into(),
        message: message.into(),
        retryable: true,
    }
}

async fn monitor(weak: Weak<Inner>, policy: HealthPolicy) {
    let mut next_session_refresh = Instant::now() + policy.retry_base;
    let mut next_probe = Instant::now() + policy.probe_interval;
    let mut retry_at = Instant::now();
    let mut probe_failures = 0;
    let mut restart_failures: u32 = 0;
    loop {
        let Some(inner) = weak.upgrade() else {
            return;
        };
        tokio::select! {
            _ = tokio::time::sleep(policy.poll) => {},
            _ = inner.wake.notified() => {},
        }
        if inner.stopped.load(Ordering::Acquire) {
            return;
        }
        let adapter = inner.adapter.read().await;
        if adapter.is_running().await && Instant::now() >= next_session_refresh {
            // A writer owned by another process is a session condition, not a
            // dead runtime. Never restart unrelated active chats to acquire it.
            let _ = adapter.refresh_read_only_session().await;
            next_session_refresh = Instant::now() + policy.probe_interval;
        }
        if adapter.is_running().await && Instant::now() >= next_probe {
            match adapter.health_check(policy.probe_timeout).await {
                Ok(()) => {
                    probe_failures = 0;
                    restart_failures = 0;
                    next_probe = Instant::now() + policy.probe_interval;
                }
                Err(error) => {
                    probe_failures += 1;
                    next_probe = Instant::now() + policy.poll;
                    if probe_failures >= 2 {
                        adapter.mark_unhealthy(&error).await;
                    }
                }
            }
        }
        if adapter.is_running().await || Instant::now() < retry_at {
            continue;
        }
        drop(adapter);

        // The write lease excludes user operations until the exact saved chat
        // has been restored. Operations already sent are never retried here.
        let mut adapter = inner.adapter.write().await;
        if inner.stopped.load(Ordering::Acquire) {
            return;
        }
        let previous_session_id = adapter.active_session_id().await.unwrap_or_default();
        adapter.emit_status("Codex disconnected · reconnecting…", "recovering");
        restart_failures = restart_failures.saturating_add(1);
        let delay = policy
            .retry_base
            .saturating_mul(1u32 << restart_failures.saturating_sub(1).min(10))
            .min(policy.retry_max);
        match adapter.restart().await {
            Ok(replacement) => {
                *adapter = replacement;
                let _ = adapter.emit_recovered(&previous_session_id).await;
                adapter.emit_status("Codex connection restored", "ready");
                probe_failures = 0;
                next_probe = Instant::now() + policy.probe_interval;
            }
            Err(error) => {
                adapter.emit_status(
                    &format!(
                        "Codex reconnect failed · {} · retrying in {}s",
                        error.message,
                        delay.as_secs_f64()
                    ),
                    "recovering",
                );
            }
        }
        retry_at = Instant::now() + delay;
        inner.changed.send_replace(());
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        ExecutionHost, RuntimeCommand, RuntimeTarget,
        codex_adapter::{CodexTurnRequest, CoreEvent},
    };
    use serde_json::{Value, json};
    use std::{fs, path::PathBuf, process::Command};
    use tokio::sync::mpsc;

    struct Fixture(PathBuf);

    impl Fixture {
        fn new() -> Self {
            let root = std::env::temp_dir().join(format!("zommi-health-{}", uuid::Uuid::new_v4()));
            fs::create_dir_all(&root).unwrap();
            Self(root)
        }

        fn config(&self) -> CodexConfig {
            let python = ["python3", "python"]
                .into_iter()
                .find(|name| {
                    Command::new(name)
                        .arg("--version")
                        .output()
                        .is_ok_and(|o| o.status.success())
                })
                .expect("Python fixture interpreter");
            let script = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("../zommi-core-host/tests/fake_codex_app_server.py");
            CodexConfig::new(
                RuntimeTarget {
                    id: self.0.to_string_lossy().into_owned(),
                    runtime_id: "codex".into(),
                    adapter_id: "codex-app-server".into(),
                    display_name: "Codex".into(),
                    protocol_name: "Codex app-server".into(),
                    executable_path: python.into(),
                    execution_host: ExecutionHost {
                        id: "native:test".into(),
                        kind: "native".into(),
                        platform: std::env::consts::OS.into(),
                        display_name: "Test".into(),
                        is_default: true,
                        name: None,
                    },
                    status: "detected".into(),
                    priority: 0,
                    capability_hints: vec![],
                    runtime_home: None,
                    source: None,
                    endpoint: None,
                    profile_id: None,
                },
                RuntimeCommand {
                    command: python.into(),
                    working_directory: None,
                    args: vec![
                        script.to_string_lossy().into_owned(),
                        "--control-dir".into(),
                        self.0.to_string_lossy().into_owned(),
                    ],
                },
                self.0.clone(),
                None,
            )
        }

        async fn connect(&self) -> (SupervisedCodex, mpsc::UnboundedReceiver<CoreEvent>) {
            let (tx, rx) = mpsc::unbounded_channel();
            let runtime = SupervisedCodex::connect_with_policy(
                self.config(),
                tx,
                HealthPolicy {
                    poll: Duration::from_millis(10),
                    probe_interval: Duration::from_millis(80),
                    probe_timeout: Duration::from_millis(50),
                    retry_base: Duration::from_millis(60),
                    retry_max: Duration::from_millis(240),
                },
            )
            .await
            .unwrap();
            (runtime, rx)
        }

        fn requests(&self) -> Vec<Value> {
            fs::read_to_string(self.0.join("requests.jsonl"))
                .unwrap_or_default()
                .lines()
                .filter_map(|line| serde_json::from_str(line).ok())
                .collect()
        }

        fn pids(&self) -> Vec<u64> {
            self.requests()
                .iter()
                .filter_map(|v| v["fixturePid"].as_u64())
                .collect()
        }
        fn mark(&self, name: &str, value: impl ToString) {
            fs::write(self.0.join(name), value.to_string()).unwrap();
        }
        fn count(&self, method: &str) -> usize {
            self.requests()
                .iter()
                .filter(|r| r["method"] == method)
                .count()
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    async fn event(rx: &mut mpsc::UnboundedReceiver<CoreEvent>, name: &str) -> CoreEvent {
        timeout(Duration::from_secs(5), async {
            loop {
                let e = rx.recv().await.expect("event stream open");
                if e.name == name {
                    return e;
                }
            }
        })
        .await
        .unwrap_or_else(|_| panic!("missing {name}"))
    }

    async fn hold_turn(runtime: &SupervisedCodex, cwd: &str) {
        let adapter = runtime.ready().await.unwrap();
        adapter.open_session("saved-chat").await.unwrap();
        adapter
            .start_turn(CodexTurnRequest {
                slash_command: false,
                session_id: "saved-chat",
                message: "hold-for-interrupt",
                snapshots: &[],
                images: &[],
                client_operation_id: "test:held-turn",
                model: Some("chosen-model"),
                effort: Some("high"),
                cwd: Some(cwd),
            })
            .await
            .unwrap();
    }

    #[tokio::test]
    async fn prepared_transport_activates_supervision_and_recovers_exact_chat() {
        let fixture = Fixture::new();
        let mut config = fixture.config();
        config.list_only = true;
        let (tx, mut events) = mpsc::unbounded_channel();
        let runtime = SupervisedCodex::connect(config, tx).await.unwrap();
        assert_eq!(fixture.count("thread/start"), 0);
        assert!(runtime.inner.task.lock().await.is_none());
        runtime
            .activate(Some("saved-chat".into()), None)
            .await
            .unwrap();
        assert_eq!(fixture.pids().len(), 1);
        assert!(runtime.inner.task.lock().await.is_some());
        fixture.mark("exit-pid", fixture.pids()[0]);
        // The fixture exits on its next native request.
        let _ = runtime
            .ready()
            .await
            .unwrap()
            .health_check(Duration::from_millis(100))
            .await;
        let recovered = event(&mut events, "runtime.recovered").await;
        assert_eq!(recovered.payload["previousSessionId"], "saved-chat");
        assert_eq!(
            runtime
                .ready()
                .await
                .unwrap()
                .active_session_id()
                .await
                .unwrap(),
            "saved-chat"
        );
        assert_eq!(fixture.pids().len(), 2);
        assert_eq!(fixture.count("thread/start"), 0);
        runtime.shutdown().await;
    }

    #[tokio::test]
    async fn busy_saved_chat_opens_read_only_then_recovers_without_replacing_or_replaying() {
        let fixture = Fixture::new();
        fixture.mark("busy-session", "saved-chat");
        let (runtime, mut events) = fixture.connect().await;
        let connection = runtime
            .ready()
            .await
            .unwrap()
            .open_session("saved-chat")
            .await
            .unwrap();
        assert_eq!(connection.session_id, "saved-chat");
        assert_eq!(connection.session_metadata["readOnly"], true);
        assert_eq!(connection.history.unwrap()["thread"]["id"], "saved-chat");
        let adapter = runtime.ready().await.unwrap();
        let error = adapter
            .start_turn(CodexTurnRequest {
                slash_command: false,
                session_id: "saved-chat",
                message: "keep draft",
                snapshots: &[],
                images: &[],
                client_operation_id: "not-sent",
                model: None,
                effort: None,
                cwd: None,
            })
            .await
            .unwrap_err();
        assert_eq!(error.code, "session-busy");
        assert_eq!(
            adapter
                .goal_command(
                    "saved-chat",
                    &json!({"action":"set", "objective":"not sent"})
                )
                .await
                .unwrap_err()
                .code,
            "session-busy"
        );
        drop(adapter);
        fs::remove_file(fixture.0.join("busy-session")).unwrap();
        loop {
            let refreshed = event(&mut events, "session.refreshed").await;
            if refreshed.payload["connection"]["sessionMetadata"]["readOnly"] == false {
                break;
            }
        }
        assert_eq!(
            runtime
                .ready()
                .await
                .unwrap()
                .active_session_id()
                .await
                .unwrap(),
            "saved-chat"
        );
        assert_eq!(fixture.pids().len(), 1);
        assert!(
            !fixture
                .requests()
                .iter()
                .any(|r| r["method"] == "turn/start" || r["method"] == "thread/goal/set")
        );
        runtime.shutdown().await;
    }

    #[tokio::test]
    async fn locked_startup_keeps_the_preferred_chat_and_background_retry_cannot_steal_selection() {
        let fixture = Fixture::new();
        fixture.mark("busy-session", "saved-chat");
        let mut config = fixture.config();
        config.preferred_session_id = Some("saved-chat".into());
        let (tx, _rx) = mpsc::unbounded_channel();
        let adapter = CodexAdapter::connect(config, tx).await.unwrap();
        assert_eq!(
            adapter.connection().await.unwrap().session_metadata["readOnly"],
            true
        );
        assert!(
            !fixture
                .requests()
                .iter()
                .any(|r| r["method"] == "thread/start")
        );
        adapter.open_session("another-chat").await.unwrap();
        fs::remove_file(fixture.0.join("busy-session")).unwrap();
        adapter.refresh_read_only_session().await.unwrap();
        assert_eq!(adapter.active_session_id().await.unwrap(), "another-chat");
        fixture.mark("wrong-resume-id", "1");
        assert_eq!(
            adapter.open_session("saved-chat").await.unwrap_err().code,
            "identity-mismatch"
        );
        assert_eq!(adapter.active_session_id().await.unwrap(), "another-chat");
        adapter.shutdown().await;
    }

    #[tokio::test]
    async fn recovered_runtime_events_keep_increasing_sequences() {
        let fixture = Fixture::new();
        let (runtime, mut events) = fixture.connect().await;
        hold_turn(&runtime, "/workspace").await;
        let before = event(&mut events, "turn.started").await.sequence;
        fixture.mark("exit-pid", fixture.pids()[0]);
        let stopped = event(&mut events, "turn.completed").await.sequence;
        let recovered = event(&mut events, "runtime.recovered").await.sequence;
        assert!(stopped > before && recovered > stopped);
        runtime.shutdown().await;
    }

    #[tokio::test]
    async fn crashed_runtime_resumes_exact_chat_and_settings_without_replaying_turn() {
        let fixture = Fixture::new();
        let (runtime, mut events) = fixture.connect().await;
        hold_turn(&runtime, "/chosen/workspace").await;
        fixture.mark("exit-pid", fixture.pids()[0]);
        let stopped = event(&mut events, "turn.completed").await;
        assert_eq!(stopped.payload["status"], "unknown");
        assert!(stopped.payload["error"].as_str().unwrap().contains("26"));
        assert!(!stopped.payload.to_string().contains("fixture-private"));
        let recovered = event(&mut events, "runtime.recovered").await;
        assert_eq!(recovered.payload["previousSessionId"], "saved-chat");
        let connection = runtime.ready().await.unwrap().connection().await.unwrap();
        assert_eq!(connection.session_id, "saved-chat");
        assert_eq!(connection.session_metadata["activeModel"], "chosen-model");
        assert_eq!(connection.session_metadata["activeEffort"], "high");
        assert_eq!(connection.session_metadata["cwd"], "/chosen/workspace");
        assert_eq!(fixture.pids().len(), 2);
        assert_eq!(fixture.count("turn/start"), 1);
        assert_eq!(fixture.count("thread/start"), 1);
        runtime.shutdown().await;
    }

    #[tokio::test]
    async fn empty_chats_switch_without_unsupported_history_then_read_the_first_turn() {
        let fixture = Fixture::new();
        fixture.mark("unique-threads", "1");
        fixture.mark("reject-empty-history", "1");
        let (runtime, _events) = fixture.connect().await;
        let adapter = runtime.ready().await.unwrap();
        let first = adapter.active_session_id().await.unwrap();
        assert_eq!(
            adapter.read_session(&first).await.unwrap()["thread"]["turns"],
            json!([])
        );
        let second = adapter
            .create_session(Some("second-model"), None, None)
            .await
            .unwrap()
            .session_id;
        assert_ne!(first, second);
        for id in [&first, &second, &first] {
            let connection = adapter.open_session(id).await.unwrap();
            assert_eq!(&connection.session_id, id);
            assert_eq!(
                connection.session_metadata["activeModel"],
                if id == &first {
                    "fixture-default"
                } else {
                    "second-model"
                }
            );
            assert_eq!(connection.history.unwrap()["thread"]["turns"], json!([]));
        }
        assert_eq!(fixture.count("thread/resume"), 0);
        assert_eq!(fixture.count("thread/read"), 0);
        adapter
            .start_turn(CodexTurnRequest {
                slash_command: false,
                session_id: &first,
                message: "hold-for-interrupt",
                snapshots: &[],
                images: &[],
                client_operation_id: "test:first-turn",
                model: None,
                effort: None,
                cwd: None,
            })
            .await
            .unwrap();
        let history = adapter.read_session(&first).await.unwrap();
        assert_eq!(history["thread"]["turns"].as_array().unwrap().len(), 1);
        assert_eq!(fixture.count("thread/read"), 1);
        adapter.open_session(&second).await.unwrap();
        assert_eq!(
            adapter.open_session(&first).await.unwrap().session_id,
            first
        );
        assert_eq!(fixture.count("thread/resume"), 0);
        // One metadata probe accompanies the initial pagination capability
        // check. This legacy server then falls back to complete history.
        assert_eq!(fixture.count("thread/read"), 3);
        adapter.open_session(&first).await.unwrap();
        assert_eq!(fixture.count("thread/read"), 4);
        drop(adapter);
        runtime.shutdown().await;
    }

    #[tokio::test]
    async fn unsupported_saved_history_is_never_replaced_with_an_empty_transcript() {
        let fixture = Fixture::new();
        let (runtime, _events) = fixture.connect().await;
        fixture.mark("reject-history", "1");
        let adapter = runtime.ready().await.unwrap();
        let original = adapter.active_session_id().await.unwrap();
        assert!(
            adapter
                .open_session("saved-chat")
                .await
                .unwrap_err()
                .message
                .contains("list_turns")
        );
        assert!(
            adapter
                .read_session("saved-chat")
                .await
                .unwrap_err()
                .message
                .contains("list_turns")
        );
        assert_eq!(adapter.active_session_id().await.unwrap(), original);
        drop(adapter);
        runtime.shutdown().await;
    }

    #[tokio::test]
    async fn delayed_probes_do_not_restart_a_streaming_runtime_but_a_real_stall_does() {
        let fixture = Fixture::new();
        let (runtime, mut events) = fixture.connect().await;
        hold_turn(&runtime, "/chosen/workspace").await;
        fixture.mark("stream-while-stalled", "1");
        fixture.mark("stall-probe-pid", fixture.pids()[0]);
        timeout(Duration::from_secs(5), async {
            while fixture.count("thread/loaded/list") < 4 {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap();
        assert_eq!(fixture.pids().len(), 1);
        while let Ok(e) = events.try_recv() {
            assert_ne!(e.name, "runtime.recovered");
            assert!(!(e.name == "turn.completed" && e.payload["status"] == "unknown"));
        }
        fs::remove_file(fixture.0.join("stream-while-stalled")).unwrap();
        event(&mut events, "runtime.recovered").await;
        assert_eq!(fixture.pids().len(), 2);
        assert_eq!(fixture.count("turn/start"), 1);
        runtime.shutdown().await;
    }

    #[tokio::test]
    async fn two_missed_probes_restart_a_live_but_unresponsive_connection() {
        let fixture = Fixture::new();
        let (runtime, mut events) = fixture.connect().await;
        hold_turn(&runtime, "/chosen/workspace").await;
        fixture.mark("stall-probe-pid", fixture.pids()[0]);
        let interrupted = event(&mut events, "turn.completed").await;
        assert_eq!(interrupted.payload["status"], "unknown");
        event(&mut events, "runtime.recovered").await;
        assert_eq!(fixture.pids().len(), 2);
        assert!(fixture.count("thread/loaded/list") >= 2);
        assert_eq!(fixture.count("turn/start"), 1);
        runtime.shutdown().await;
    }

    #[tokio::test]
    async fn failed_resume_backs_off_and_never_creates_a_replacement_for_a_saved_chat() {
        let fixture = Fixture::new();
        let (runtime, mut events) = fixture.connect().await;
        hold_turn(&runtime, "/chosen/workspace").await;
        fixture.mark("reject-history", "1");
        fixture.mark("exit-pid", fixture.pids()[0]);
        timeout(Duration::from_secs(5), async {
            while fixture.pids().len() < 4 {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap();
        let starts = fixture
            .requests()
            .iter()
            .filter_map(|r| r["startedAt"].as_f64())
            .collect::<Vec<_>>();
        assert!(starts[2] - starts[1] >= 0.05);
        assert!(starts[3] - starts[2] >= 0.10);
        assert_eq!(fixture.count("thread/start"), 1);
        fs::remove_file(fixture.0.join("reject-history")).unwrap();
        event(&mut events, "runtime.recovered").await;
        assert_eq!(
            runtime
                .ready()
                .await
                .unwrap()
                .active_session_id()
                .await
                .unwrap(),
            "saved-chat"
        );
        assert_eq!(fixture.count("turn/start"), 1);
        runtime.shutdown().await;
    }

    #[tokio::test]
    async fn goal_mutation_prevents_empty_chat_replacement_and_replay_on_recovery() {
        let fixture = Fixture::new();
        let (runtime, mut events) = fixture.connect().await;
        let session_id = {
            let adapter = runtime.ready().await.unwrap();
            let id = adapter.active_session_id().await.unwrap();
            adapter.goal_command(&id, &serde_json::json!({
                "action": "set", "objective": "Finish this goal", "model": "goal-model", "effort": "high"
            })).await.unwrap();
            id
        };
        fixture.mark("reject-history", "1");
        fixture.mark("exit-pid", fixture.pids()[0]);
        timeout(Duration::from_secs(5), async {
            while fixture.pids().len() < 3 {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap();
        assert_eq!(fixture.count("thread/start"), 1);
        fs::remove_file(fixture.0.join("reject-history")).unwrap();
        event(&mut events, "runtime.recovered").await;
        let connection = runtime.ready().await.unwrap().connection().await.unwrap();
        assert_eq!(connection.session_id, session_id);
        assert_eq!(connection.session_metadata["activeModel"], "goal-model");
        assert_eq!(connection.session_metadata["activeEffort"], "high");
        assert_eq!(fixture.count("thread/goal/set"), 1);
        assert_eq!(fixture.count("turn/start"), 0);
        runtime.shutdown().await;
    }

    #[tokio::test]
    async fn closing_during_restart_cancels_startup_and_never_respawns() {
        let fixture = Fixture::new();
        let (runtime, _events) = fixture.connect().await;
        fixture.mark("stall-initialize", "1");
        fixture.mark("exit-pid", fixture.pids()[0]);
        timeout(Duration::from_secs(5), async {
            while fixture.pids().len() < 2 {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap();
        timeout(Duration::from_secs(1), runtime.shutdown())
            .await
            .unwrap();
        tokio::time::sleep(Duration::from_millis(300)).await;
        assert_eq!(fixture.pids().len(), 2);
        assert!(!runtime.is_running().await);
        assert!(runtime.ready().await.is_err());
    }

    #[tokio::test]
    async fn a_stalled_restart_does_not_block_a_different_runtime() {
        let broken_fixture = Fixture::new();
        let good_fixture = Fixture::new();
        let (broken, _events) = broken_fixture.connect().await;
        let (good, _) = good_fixture.connect().await;
        broken_fixture.mark("stall-initialize", "1");
        broken_fixture.mark("exit-pid", broken_fixture.pids()[0]);
        timeout(Duration::from_secs(5), async {
            while broken_fixture.pids().len() < 2 {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap();
        timeout(Duration::from_secs(1), async {
            good.ready()
                .await
                .unwrap()
                .health_check(Duration::from_millis(100))
                .await
                .unwrap();
        })
        .await
        .unwrap();
        assert_eq!(good_fixture.pids().len(), 1);
        broken.shutdown().await;
        good.shutdown().await;
    }
}
