#![cfg(target_os = "linux")]

use std::{
    fs,
    io::{BufRead, BufReader, Write},
    os::{fd::OwnedFd, unix::net::UnixStream},
    process::{Child, Command, Stdio},
    thread,
    time::{Duration, Instant},
};

struct ProcessCleanup {
    parent: Child,
    core_pid: Option<i32>,
}

impl Drop for ProcessCleanup {
    fn drop(&mut self) {
        let _ = self.parent.kill();
        let _ = self.parent.wait();
        if let Some(core_pid) = self.core_pid.filter(|core_pid| is_running(*core_pid)) {
            unsafe { libc::kill(core_pid, libc::SIGKILL) };
        }
    }
}

fn is_running(process_id: i32) -> bool {
    fs::read_to_string(format!("/proc/{process_id}/stat"))
        .ok()
        .and_then(|status| status.rsplit_once(") ").map(|(_, rest)| rest.to_owned()))
        .is_some_and(|status| !matches!(status.chars().next(), Some('Z' | 'X' | 'x')))
}

#[test]
fn core_stops_with_its_parent_even_when_another_process_keeps_stdin_open() {
    let (mut input, core_input) = UnixStream::pair().unwrap();
    let (output, core_output) = UnixStream::pair().unwrap();
    output
        .set_read_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    let parent = Command::new("sh")
        .args([
            "-c",
            "exec 3<&0; \"$1\" <&3 & core_pid=$!; printf '%s\\n' \"$core_pid\"; wait \"$core_pid\"",
            "focalet-core-parent",
            env!("CARGO_BIN_EXE_focalet-core-host"),
        ])
        .stdin(Stdio::from(OwnedFd::from(core_input)))
        .stdout(Stdio::from(OwnedFd::from(core_output)))
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let mut cleanup = ProcessCleanup {
        parent,
        core_pid: None,
    };
    let mut reader = BufReader::new(output);
    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    let core_pid = line.trim().parse::<i32>().unwrap();
    cleanup.core_pid = Some(core_pid);
    writeln!(
        input,
        "{}",
        serde_json::json!({"id": "ready", "protocolVersion": 1, "operation": "core.initialize"})
    )
    .unwrap();
    line.clear();
    reader.read_line(&mut line).unwrap();
    let response: serde_json::Value = serde_json::from_str(&line).unwrap();
    assert_eq!(response["ok"], true);
    assert!(is_running(core_pid));
    cleanup.parent.kill().unwrap();
    cleanup.parent.wait().unwrap();
    let deadline = Instant::now() + Duration::from_secs(3);
    while is_running(core_pid) && Instant::now() < deadline {
        thread::sleep(Duration::from_millis(20));
    }
    assert!(!is_running(core_pid), "Core outlived its terminated parent");
    drop(input);
}
