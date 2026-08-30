use std::{
    path::PathBuf,
    process::Stdio,
    sync::{
        Arc, Weak,
        atomic::{AtomicU64, Ordering},
    },
};

use regex::Regex;
use serde_json::{Value, json};
use tokio::{
    io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader},
    process::{ChildStdin, Command},
    sync::{Mutex, Notify},
    task::JoinHandle,
    time::{Duration, timeout},
};
use uuid::Uuid;

use crate::{
    RuntimeCommand, RuntimeTarget, build_context_handoff,
    codex_adapter::{CodexError, CoreEvent, EventSender, TurnReceipt},
    sanitize_diagnostic, validate_turn_input,
};

const STARTUP_TIMEOUT: Duration = Duration::from_secs(20);
const COMPLETION_SETTLE: Duration = Duration::from_millis(650);

#[derive(Debug, Clone)]
pub struct PtyConfig {
    pub target: RuntimeTarget,
    pub command: RuntimeCommand,
    pub cwd: PathBuf,
}

pub struct PtyTurnRequest<'a> {
    pub session_id: &'a str,
    pub message: &'a str,
    pub snapshots: &'a [Value],
    pub images: &'a [String],
    pub client_operation_id: &'a str,
}

#[derive(Clone)]
pub struct PtyAdapter {
    inner: Arc<Inner>,
}

struct Inner {
    target: RuntimeTarget,
    thread_id: String,
    stdin: Mutex<ChildStdin>,
    state: Mutex<State>,
    ready: Notify,
    next_event_sequence: AtomicU64,
    event_tx: EventSender,
    wait_task: Mutex<Option<JoinHandle<()>>>,
    stdout_task: Mutex<Option<JoinHandle<()>>>,
    stderr_task: Mutex<Option<JoinHandle<()>>>,
}

#[derive(Default)]
struct State {
    ready: bool,
    startup_error: Option<String>,
    output_window: String,
    active_turn: Option<ActiveTurn>,
    stderr: String,
    stopping: bool,
}

#[derive(Clone)]
struct ActiveTurn {
    turn_id: String,
    operation_id: String,
    saw_output: bool,
}

impl PtyAdapter {
    pub async fn connect(config: PtyConfig, event_tx: EventSender) -> Result<Self, CodexError> {
        let launch = pty_launch(&config)?;
        let mut command = Command::new(&launch.command);
        command
            .args(&launch.args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true);
        if let Some(cwd) = &launch.cwd
            && cwd.is_dir()
        {
            command.current_dir(cwd);
        }
        let mut child = command.spawn().map_err(|error| {
            pty_error(
                "runtime-unavailable",
                format!("Could not start terminal compatibility: {error}"),
            )
        })?;
        let stdin = child.stdin.take().ok_or_else(|| {
            pty_error(
                "runtime-unavailable",
                "Terminal compatibility has no stdin.",
            )
        })?;
        let stdout = child.stdout.take().ok_or_else(|| {
            pty_error(
                "runtime-unavailable",
                "Terminal compatibility has no stdout.",
            )
        })?;
        let stderr = child.stderr.take().ok_or_else(|| {
            pty_error(
                "runtime-unavailable",
                "Terminal compatibility has no stderr.",
            )
        })?;
        let adapter = Self {
            inner: Arc::new(Inner {
                target: config.target,
                thread_id: format!("compat-{}", Uuid::new_v4()),
                stdin: Mutex::new(stdin),
                state: Mutex::new(State::default()),
                ready: Notify::new(),
                next_event_sequence: AtomicU64::new(0),
                event_tx,
                wait_task: Mutex::new(None),
                stdout_task: Mutex::new(None),
                stderr_task: Mutex::new(None),
            }),
        };
        adapter.inner.emit_status(
            "Starting Claude CLI in Compatible terminal mode…",
            "connecting",
            None,
            None,
        );
        let weak = Arc::downgrade(&adapter.inner);
        *adapter.inner.stdout_task.lock().await =
            Some(tokio::spawn(async move { read_stdout(weak, stdout).await }));
        let weak = Arc::downgrade(&adapter.inner);
        *adapter.inner.stderr_task.lock().await =
            Some(tokio::spawn(async move { read_stderr(weak, stderr).await }));
        let weak = Arc::downgrade(&adapter.inner);
        *adapter.inner.wait_task.lock().await = Some(tokio::spawn(async move {
            let status = child.wait().await;
            if let Some(inner) = weak.upgrade() {
                if let Some(task) = inner.stdout_task.lock().await.take() {
                    let _ = task.await;
                }
                if let Some(task) = inner.stderr_task.lock().await.take() {
                    let _ = task.await;
                }
                inner.handle_exit(status).await;
            }
        }));

        match timeout(STARTUP_TIMEOUT, wait_for_terminal_ready(&adapter.inner)).await {
            Ok(Ok(())) => {}
            Ok(Err(message)) => {
                adapter.shutdown().await;
                return Err(pty_error("runtime-setup-required", message));
            }
            Err(_) => {
                adapter.shutdown().await;
                return Err(pty_error(
                    "runtime-timeout",
                    "Claude CLI did not expose its configured terminal prompt within 20 seconds.",
                ));
            }
        }
        adapter.inner.emit_status(
            "Claude CLI ready · Compatible mode, best-effort output",
            "degraded",
            Some(&adapter.inner.thread_id),
            None,
        );
        Ok(adapter)
    }

    pub fn target_id(&self) -> &str {
        &self.inner.target.id
    }

    pub fn active_session_id(&self) -> String {
        self.inner.thread_id.clone()
    }

    pub async fn connection_value(&self) -> Value {
        json!({
            "runtimeTargetId": self.inner.target.id,
            "sessionId": self.inner.thread_id,
            "protocolVersion": Value::Null,
            "runtimeVersion": Value::Null,
            "capabilities": ["turn.stream.v1"],
            "models": [],
            "sessions": [{
                "id": self.inner.thread_id,
                "name": "Claude CLI Compatible",
                "preview": "Non-canonical terminal session"
            }],
            "historyAuthority": "none"
        })
    }

    pub async fn read_session(&self, session_id: &str) -> Result<Value, CodexError> {
        if session_id != self.inner.thread_id {
            return Err(pty_error(
                "identity-mismatch",
                "Terminal compatibility has no canonical history for another session.",
            ));
        }
        Ok(json!({
            "thread": {"id": session_id, "turns": []},
            "historyAuthority": "none"
        }))
    }

    pub async fn start_turn(&self, request: PtyTurnRequest<'_>) -> Result<TurnReceipt, CodexError> {
        let input = validate_turn_input(request.message, request.snapshots, request.images)?;
        if !input.images.is_empty() {
            return Err(pty_error(
                "capability-unavailable",
                "This terminal compatibility profile does not support image attachments.",
            ));
        }
        if request.session_id != self.inner.thread_id {
            return Err(pty_error(
                "identity-mismatch",
                "The requested session is not the exact compatibility session.",
            ));
        }
        let turn_id = Uuid::new_v4().to_string();
        {
            let mut state = self.inner.state.lock().await;
            if state.active_turn.is_some() {
                return Err(pty_error(
                    "session-busy",
                    "This terminal compatibility session already has active input.",
                ));
            }
            state.active_turn = Some(ActiveTurn {
                turn_id: turn_id.clone(),
                operation_id: request.client_operation_id.into(),
                saw_output: false,
            });
            state.output_window.clear();
        }
        let prompt = build_context_handoff(&input.message, &input.snapshots, 0)
            .replace(['\0', '\u{001b}'], "");
        let encoded = format!("\u{001b}[200~{prompt}\u{001b}[201~\r");
        let mut stdin = self.inner.stdin.lock().await;
        if let Err(error) = stdin.write_all(encoded.as_bytes()).await {
            self.inner.state.lock().await.active_turn = None;
            return Err(pty_error("runtime-exited", error.to_string()));
        }
        stdin
            .flush()
            .await
            .map_err(|error| pty_error("runtime-exited", error.to_string()))?;
        drop(stdin);
        self.inner.emit(
            "turn.started",
            Some(&self.inner.thread_id),
            Some(&turn_id),
            Some(request.client_operation_id),
            json!({"status": "inProgress", "acknowledgement": "transport-only"}),
        );
        self.inner.emit_status(
            "Claude CLI input sent · terminal compatibility cannot prove runtime acknowledgement",
            "degraded",
            Some(&self.inner.thread_id),
            Some(&turn_id),
        );
        Ok(TurnReceipt {
            accepted: true,
            runtime_target_id: self.inner.target.id.clone(),
            session_id: self.inner.thread_id.clone(),
            turn_id,
            client_operation_id: request.client_operation_id.into(),
        })
    }

    pub async fn shutdown(&self) {
        self.inner.state.lock().await.stopping = true;
        for task in [
            self.inner.wait_task.lock().await.take(),
            self.inner.stdout_task.lock().await.take(),
            self.inner.stderr_task.lock().await.take(),
        ]
        .into_iter()
        .flatten()
        {
            task.abort();
        }
    }
}

struct PtyLaunch {
    command: String,
    args: Vec<String>,
    cwd: Option<PathBuf>,
}

fn pty_launch(config: &PtyConfig) -> Result<PtyLaunch, CodexError> {
    let agent = std::iter::once(config.command.command.as_str())
        .chain(config.command.args.iter().map(String::as_str))
        .map(quote_posix)
        .collect::<Vec<_>>()
        .join(" ");
    if config.target.execution_host.kind == "wsl" {
        let name = config
            .target
            .execution_host
            .name
            .as_deref()
            .ok_or_else(|| pty_error("invalid-configuration", "WSL target has no name."))?;
        let mut args = vec!["-d".into(), name.into()];
        if let Some(home) = &config.target.runtime_home {
            args.extend(["--cd".into(), home.clone()]);
        }
        args.extend([
            "-e".into(),
            "script".into(),
            "-qefc".into(),
            format!("exec {agent}"),
            "/dev/null".into(),
        ]);
        return Ok(PtyLaunch {
            command: "wsl.exe".into(),
            args,
            cwd: None,
        });
    }
    match config.target.execution_host.platform.as_str() {
        "windows" => Err(pty_error(
            "capability-unavailable",
            "Native Windows terminal compatibility requires a packaged ConPTY backend. Install this CLI in WSL or use a protocol target.",
        )),
        "macos" => Ok(PtyLaunch {
            command: "/usr/bin/script".into(),
            args: std::iter::once("-q".into())
                .chain(std::iter::once("/dev/null".into()))
                .chain(std::iter::once(config.command.command.clone()))
                .chain(config.command.args.clone())
                .collect(),
            cwd: Some(config.cwd.clone()),
        }),
        _ => Ok(PtyLaunch {
            command: "script".into(),
            args: vec!["-qefc".into(), format!("exec {agent}"), "/dev/null".into()],
            cwd: Some(config.cwd.clone()),
        }),
    }
}

impl Inner {
    async fn handle_output(self: &Arc<Self>, raw: &str) {
        let text = strip_terminal_controls(raw);
        if text.is_empty() {
            return;
        }
        let mut state = self.state.lock().await;
        state.output_window.push_str(&text);
        if state.output_window.len() > 8_000 {
            let mut start = state.output_window.len() - 8_000;
            while !state.output_window.is_char_boundary(start) {
                start += 1;
            }
            state.output_window.drain(..start);
        }
        if !state.ready {
            if is_setup_prompt(&state.output_window) {
                state.startup_error = Some(
                    "Claude CLI requires an interactive workspace trust or setup decision. Open Claude directly in this Execution Host and complete it before reconnecting; Zommi will not answer trust prompts."
                        .into(),
                );
                self.ready.notify_waiters();
                return;
            }
            if is_prompt(&state.output_window) {
                state.ready = true;
                self.ready.notify_waiters();
            }
        }
        let Some(turn) = state.active_turn.as_mut() else {
            return;
        };
        turn.saw_output |= !text.trim().is_empty();
        let turn = turn.clone();
        let should_complete = turn.saw_output && is_prompt(&state.output_window);
        drop(state);
        self.emit(
            "item.update",
            Some(&self.thread_id),
            Some(&turn.turn_id),
            Some(&turn.operation_id),
            json!({
                "kind": "assistant", "lifecycle": "delta", "title": "Claude CLI",
                "text": text, "itemId": format!("{}-terminal", turn.turn_id)
            }),
        );
        if should_complete {
            let weak = Arc::downgrade(self);
            tokio::spawn(async move {
                tokio::time::sleep(COMPLETION_SETTLE).await;
                let Some(inner) = weak.upgrade() else {
                    return;
                };
                let mut state = inner.state.lock().await;
                let matches = state
                    .active_turn
                    .as_ref()
                    .is_some_and(|active| active.turn_id == turn.turn_id);
                if matches {
                    state.active_turn = None;
                }
                drop(state);
                if matches {
                    inner.emit(
                        "turn.completed",
                        Some(&inner.thread_id),
                        Some(&turn.turn_id),
                        Some(&turn.operation_id),
                        json!({
                            "status": "completed", "evidence": "terminal-prompt-heuristic"
                        }),
                    );
                }
            });
        }
    }

    async fn handle_exit(&self, status: std::io::Result<std::process::ExitStatus>) {
        let mut state = self.state.lock().await;
        if state.stopping {
            return;
        }
        let active = state.active_turn.take();
        let code = status
            .map(|status| {
                status
                    .code()
                    .map_or_else(|| "signal".into(), |value| value.to_string())
            })
            .unwrap_or_else(|error| error.to_string());
        let message = sanitize_diagnostic(format!(
            "Claude CLI terminal exited ({code}). {}",
            state.stderr
        ));
        drop(state);
        if let Some(turn) = active {
            self.emit(
                "turn.completed",
                Some(&self.thread_id),
                Some(&turn.turn_id),
                Some(&turn.operation_id),
                json!({"status": "failed", "error": message}),
            );
        }
        self.emit_status(&message, "unavailable", Some(&self.thread_id), None);
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

async fn read_stdout(inner: Weak<Inner>, mut stdout: tokio::process::ChildStdout) {
    let mut buffer = [0_u8; 4_096];
    loop {
        match stdout.read(&mut buffer).await {
            Ok(0) | Err(_) => return,
            Ok(length) => {
                let Some(inner) = inner.upgrade() else {
                    return;
                };
                inner
                    .handle_output(&String::from_utf8_lossy(&buffer[..length]))
                    .await;
            }
        }
    }
}

async fn read_stderr(inner: Weak<Inner>, stderr: tokio::process::ChildStderr) {
    let mut lines = BufReader::new(stderr).lines();
    while let Ok(Some(line)) = lines.next_line().await {
        let Some(inner) = inner.upgrade() else {
            return;
        };
        let mut state = inner.state.lock().await;
        state.stderr.push_str(&line);
        state.stderr.push('\n');
    }
}

async fn wait_for_terminal_ready(inner: &Inner) -> Result<(), String> {
    loop {
        let notified = inner.ready.notified();
        {
            let state = inner.state.lock().await;
            if state.ready {
                return Ok(());
            }
            if let Some(error) = &state.startup_error {
                return Err(error.clone());
            }
        }
        notified.await;
    }
}

fn strip_terminal_controls(value: &str) -> String {
    let osc = Regex::new(r"\x1b\][^\x07]*(?:\x07|\x1b\\)").expect("OSC regex");
    let dcs = Regex::new(r"(?s)\x1bP.*?\x1b\\").expect("DCS regex");
    let csi = Regex::new(r"\x1b\[[0-?]*[ -/]*[@-~]").expect("CSI regex");
    let value = osc.replace_all(value, "");
    let value = dcs.replace_all(&value, "");
    let value = csi.replace_all(&value, "");
    let mut characters = value.chars().peekable();
    let mut normalized = String::with_capacity(value.len());
    while let Some(character) = characters.next() {
        if character == '\r' && characters.peek() != Some(&'\n') {
            normalized.push('\n');
        } else if !matches!(
            character,
            '\u{0000}'..='\u{0008}' | '\u{000b}' | '\u{000c}' | '\u{000e}'..='\u{001f}' | '\u{007f}'
        ) {
            normalized.push(character);
        }
    }
    normalized
}

fn is_prompt(value: &str) -> bool {
    let lower = value.to_ascii_lowercase();
    !is_setup_prompt(value)
        && ((lower.contains("claude code v") && lower.contains("? for shortcuts"))
            || Regex::new(r"(?:^|\n)\s*[>❯]\s*$")
                .expect("prompt regex")
                .is_match(value))
}

fn is_setup_prompt(value: &str) -> bool {
    let lower = value.to_ascii_lowercase();
    lower.contains("do you trust the files in this folder?")
        || (lower.contains("yes, proceed") && lower.contains("no, exit"))
}

fn quote_posix(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

fn pty_error(code: impl Into<String>, message: impl Into<String>) -> CodexError {
    CodexError {
        code: code.into(),
        message: sanitize_diagnostic(message.into()),
        retryable: false,
    }
}

#[cfg(test)]
mod tests {
    use super::{is_prompt, is_setup_prompt, quote_posix, strip_terminal_controls};

    #[test]
    fn strips_terminal_controls_without_removing_unicode() {
        assert_eq!(
            strip_terminal_controls("\u{001b}[31mhello 世界\u{001b}[0m\r\n"),
            "hello 世界\r\n"
        );
        assert_eq!(quote_posix("a'b"), "'a'\\''b'");
    }

    #[test]
    fn trust_dialog_is_never_a_ready_terminal_prompt() {
        let trust = "Do you trust the files in this folder?\n❯ 1. Yes, proceed\n  2. No, exit\n";
        assert!(is_setup_prompt(trust));
        assert!(!is_prompt(trust));
        assert!(is_prompt("> "));
        assert!(is_prompt("Claude Code v2.0.1\n? for shortcuts\n"));
    }
}
