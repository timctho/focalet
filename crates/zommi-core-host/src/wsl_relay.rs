use std::{
    env, fs,
    fs::OpenOptions,
    io::{self, BufRead, BufReader, Read, Write},
    net::{IpAddr, Shutdown, TcpStream},
    path::{Path, PathBuf},
    process::{Command, Stdio},
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    thread,
    time::{Duration, Instant},
};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use uuid::Uuid;
use wait_timeout::ChildExt;
use zommi_core::{
    RuntimeCommand, RuntimeTarget, runtime_targets_from_wsl_probe, wsl_runtime_probe_script,
};

const TRANSPORT_VERSION: u32 = 3;
const ENDPOINT_SCHEMA_VERSION: u32 = 1;
const MAX_FRAME_BYTES: usize = 16 * 1024 * 1024;
const CHANNEL_STDOUT: u8 = 1;
const CHANNEL_STDERR: u8 = 2;
const CHANNEL_EXIT: u8 = 3;
const RELAY_SOURCE: &str = include_str!("../../../scripts/zommi-wsl-relay.js");
const LAUNCHER_SOURCE: &str = include_str!("../../../scripts/launch-wsl-relay.sh");

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RelayEndpoint {
    schema_version: u32,
    transport_version: u32,
    distribution: String,
    host: String,
    port: u16,
    token: String,
    pid: u32,
    heartbeat_ms: u64,
}

pub fn wrap_wsl_command(
    target: &RuntimeTarget,
    direct: RuntimeCommand,
) -> io::Result<RuntimeCommand> {
    if target.execution_host.kind != "wsl" {
        return Ok(direct);
    }
    let distribution = target
        .execution_host
        .name
        .as_deref()
        .filter(|value| valid_distribution(value))
        .ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidInput,
                "WSL target has no valid distribution.",
            )
        })?;
    let exec_index = direct
        .args
        .iter()
        .position(|argument| argument == "-e")
        .ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidInput,
                "WSL command has no exec boundary.",
            )
        })?;
    let inner = direct.args.get(exec_index + 1..).unwrap_or_default();
    if inner
        .first()
        .is_none_or(|command| !command.starts_with('/'))
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "WSL relay commands must use an absolute executable path.",
        ));
    }
    let proxy = env::current_exe()?;
    let mut args = vec![
        "--wsl-proxy".into(),
        "--distribution".into(),
        distribution.into(),
        "--cwd".into(),
        target.runtime_home.clone().unwrap_or_else(|| "/".into()),
        "--".into(),
    ];
    args.extend(inner.iter().cloned());
    Ok(RuntimeCommand {
        command: proxy.to_string_lossy().into_owned(),
        args,
        working_directory: None,
    })
}

pub fn run_proxy(arguments: &[String]) -> io::Result<i32> {
    let invocation = ProxyInvocation::parse(arguments)?;
    let endpoint_path = endpoint_path(&invocation.distribution)?;
    let endpoint = ensure_relay(&invocation.distribution, &endpoint_path)?;
    if env::var("ZOMMI_WSL_RELAY_TRANSPORT").as_deref() == Ok("tcp") {
        proxy_runtime(endpoint, invocation)
    } else {
        proxy_runtime_spool(endpoint, &endpoint_path, invocation)
    }
}

pub fn cached_default_relay_available(targets: &[RuntimeTarget]) -> bool {
    targets
        .iter()
        .filter(|target| target.execution_host.kind == "wsl" && target.execution_host.is_default)
        .filter_map(|target| target.execution_host.name.as_deref())
        .any(|distribution| {
            endpoint_path(distribution)
                .and_then(|path| load_endpoint(&path))
                .is_ok_and(|endpoint| {
                    endpoint_matches(&endpoint, distribution) && relay_is_alive(&endpoint)
                })
        })
}

/// Refreshes every runtime in the cached WSL hosts through the authenticated
/// spool transport. A healthy relay means we do not need to start another
/// `wsl.exe` process merely to rediscover Pi, Hermes, OpenClaw, or Claude.
pub fn discover_targets_via_cached_relays(
    cached_targets: &[RuntimeTarget],
) -> io::Result<Vec<RuntimeTarget>> {
    let mut hosts = Vec::<(String, bool, String)>::new();
    for target in cached_targets {
        if target.execution_host.kind != "wsl" {
            continue;
        }
        let Some(distribution) = target.execution_host.name.as_deref() else {
            continue;
        };
        if !valid_distribution(distribution)
            || hosts
                .iter()
                .any(|(existing, _, _)| existing.eq_ignore_ascii_case(distribution))
        {
            continue;
        }
        let endpoint = endpoint_path(distribution).and_then(|path| load_endpoint(&path));
        if endpoint.is_ok_and(|endpoint| {
            endpoint_matches(&endpoint, distribution) && relay_is_alive(&endpoint)
        }) {
            hosts.push((
                distribution.to_owned(),
                target.execution_host.is_default,
                target.runtime_home.clone().unwrap_or_else(|| "/".into()),
            ));
        }
    }
    if hosts.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            "No healthy cached WSL relay is available for discovery.",
        ));
    }

    let mut discovered = Vec::new();
    for (distribution, is_default, cwd) in hosts {
        let endpoint_path = endpoint_path(&distribution)?;
        let endpoint = load_endpoint(&endpoint_path)?;
        let invocation = ProxyInvocation {
            distribution: distribution.clone(),
            cwd,
            command: "/bin/sh".into(),
            args: vec!["-lc".into(), wsl_runtime_probe_script()],
        };
        let mut stdout = Vec::new();
        let mut stderr = Vec::new();
        let status = proxy_runtime_spool_to(
            endpoint,
            &endpoint_path,
            invocation,
            false,
            &mut stdout,
            &mut stderr,
        )?;
        if status != 0 {
            return Err(io::Error::other(format!(
                "WSL relay discovery failed in {distribution}: {}",
                bounded_text(&stderr)
            )));
        }
        discovered.extend(runtime_targets_from_wsl_probe(
            &distribution,
            is_default,
            &stdout,
        ));
    }
    Ok(discovered)
}

struct ProxyInvocation {
    distribution: String,
    cwd: String,
    command: String,
    args: Vec<String>,
}

impl ProxyInvocation {
    fn parse(arguments: &[String]) -> io::Result<Self> {
        let mut distribution = None;
        let mut cwd = None;
        let mut index = 0;
        while index < arguments.len() {
            match arguments[index].as_str() {
                "--distribution" if index + 1 < arguments.len() => {
                    distribution = Some(arguments[index + 1].clone());
                    index += 2;
                }
                "--cwd" if index + 1 < arguments.len() => {
                    cwd = Some(arguments[index + 1].clone());
                    index += 2;
                }
                "--" => {
                    index += 1;
                    break;
                }
                other => {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        format!("Unknown WSL proxy argument '{other}'."),
                    ));
                }
            }
        }
        let distribution = distribution
            .filter(|value| valid_distribution(value))
            .ok_or_else(|| {
                io::Error::new(io::ErrorKind::InvalidInput, "WSL distribution is required.")
            })?;
        let cwd = cwd
            .filter(|value| value.starts_with('/') && !value.contains('\0'))
            .ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "WSL working directory is invalid.",
                )
            })?;
        let command = arguments
            .get(index)
            .filter(|value| value.starts_with('/') && !value.contains('\0'))
            .cloned()
            .ok_or_else(|| {
                io::Error::new(io::ErrorKind::InvalidInput, "WSL executable is required.")
            })?;
        let args = arguments.get(index + 1..).unwrap_or_default().to_vec();
        if args.iter().any(|value| value.contains('\0')) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "WSL runtime argument contains a null byte.",
            ));
        }
        Ok(Self {
            distribution,
            cwd,
            command,
            args,
        })
    }
}

fn valid_distribution(value: &str) -> bool {
    !value.trim().is_empty()
        && value.len() <= 128
        && !value
            .chars()
            .any(|character| matches!(character, '\u{0000}'..='\u{001f}' | '\u{007f}'))
}

fn endpoint_path(distribution: &str) -> io::Result<PathBuf> {
    if let Some(configured) = env::var_os("ZOMMI_WSL_RELAY_ENDPOINT") {
        return Ok(PathBuf::from(configured));
    }
    let root = env::var_os("LOCALAPPDATA")
        .map(PathBuf::from)
        .unwrap_or_else(env::temp_dir)
        .join("Zommi")
        .join("wsl-relay")
        .join(format!("v{TRANSPORT_VERSION}"));
    Ok(root
        .join("endpoints")
        .join(format!("{}.json", hex_name(distribution))))
}

fn hex_name(value: &str) -> String {
    value
        .as_bytes()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn ensure_relay(distribution: &str, endpoint_path: &Path) -> io::Result<RelayEndpoint> {
    if let Ok(endpoint) = load_endpoint(endpoint_path)
        && endpoint_matches(&endpoint, distribution)
        && relay_is_alive(&endpoint)
    {
        return Ok(endpoint);
    }
    if env::var_os("ZOMMI_WSL_RELAY_ENDPOINT").is_some() {
        return Err(io::Error::new(
            io::ErrorKind::ConnectionRefused,
            "Configured WSL relay is not available.",
        ));
    }
    start_relay(distribution, endpoint_path)?;
    let deadline = Instant::now() + Duration::from_secs(6);
    let mut last_error = None;
    while Instant::now() < deadline {
        match load_endpoint(endpoint_path).and_then(|endpoint| {
            if !endpoint_matches(&endpoint, distribution) {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "WSL relay endpoint identity does not match.",
                ));
            }
            if relay_is_alive(&endpoint) {
                Ok(endpoint)
            } else {
                Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    "WSL relay heartbeat is stale.",
                ))
            }
        }) {
            Ok(endpoint) => return Ok(endpoint),
            Err(error) => last_error = Some(error),
        }
        thread::sleep(Duration::from_millis(100));
    }
    Err(last_error.unwrap_or_else(|| {
        io::Error::new(io::ErrorKind::TimedOut, "WSL relay did not become ready.")
    }))
}

fn load_endpoint(path: &Path) -> io::Result<RelayEndpoint> {
    let bytes = fs::read(path)?;
    serde_json::from_slice(&bytes)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))
}

fn endpoint_matches(endpoint: &RelayEndpoint, distribution: &str) -> bool {
    let private_host = endpoint
        .host
        .parse::<IpAddr>()
        .is_ok_and(|address| match address {
            IpAddr::V4(address) => address.is_loopback() || address.is_private(),
            IpAddr::V6(address) => address.is_loopback() || address.is_unique_local(),
        });
    endpoint.schema_version == ENDPOINT_SCHEMA_VERSION
        && endpoint.transport_version == TRANSPORT_VERSION
        && endpoint.distribution.eq_ignore_ascii_case(distribution)
        && private_host
        && endpoint.port > 0
        && endpoint.token.len() >= 32
}

fn relay_is_alive(endpoint: &RelayEndpoint) -> bool {
    now_ms().saturating_sub(endpoint.heartbeat_ms) <= 5_000
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .try_into()
        .unwrap_or(u64::MAX)
}

fn connect(endpoint: &RelayEndpoint) -> io::Result<TcpStream> {
    let address = format!("{}:{}", endpoint.host, endpoint.port)
        .parse()
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
    let stream = TcpStream::connect_timeout(&address, Duration::from_secs(2))?;
    stream.set_nodelay(true)?;
    stream.set_read_timeout(Some(Duration::from_secs(5)))?;
    stream.set_write_timeout(Some(Duration::from_secs(5)))?;
    Ok(stream)
}

fn start_relay(distribution: &str, endpoint_path: &Path) -> io::Result<()> {
    let root = endpoint_path
        .parent()
        .and_then(Path::parent)
        .ok_or_else(|| {
            io::Error::new(io::ErrorKind::InvalidInput, "WSL relay path has no root.")
        })?;
    fs::create_dir_all(root.join("endpoints"))?;
    let relay = root.join("zommi-wsl-relay.js");
    let launcher = root.join("launch-wsl-relay.sh");
    let relay_source = RELAY_SOURCE.replace("\r\n", "\n");
    let launcher_source = LAUNCHER_SOURCE.replace("\r\n", "\n");
    write_if_changed(&relay, relay_source.as_bytes())?;
    write_if_changed(&launcher, launcher_source.as_bytes())?;
    match fs::remove_file(endpoint_path) {
        Ok(()) => {}
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => return Err(error),
    }

    let linux_root = wsl_path(distribution, root)?;
    let linux_relay = format!("{linux_root}/zommi-wsl-relay.js");
    let linux_launcher = format!("{linux_root}/launch-wsl-relay.sh");
    let endpoint_name = endpoint_path
        .file_name()
        .and_then(|value| value.to_str())
        .ok_or_else(|| {
            io::Error::new(io::ErrorKind::InvalidInput, "WSL endpoint name is invalid.")
        })?;
    let linux_endpoint = format!("{linux_root}/endpoints/{endpoint_name}");
    let token = Uuid::new_v4().simple().to_string() + &Uuid::new_v4().simple().to_string();
    let version = TRANSPORT_VERSION.to_string();
    let output = run_wsl(
        &[
            "-d",
            distribution,
            "-e",
            "sh",
            &linux_launcher,
            &linux_relay,
            &linux_endpoint,
            &token,
            &version,
            distribution,
        ],
        Duration::from_secs(5),
    )?;
    if !output.status.success() {
        return Err(io::Error::other(format!(
            "Could not launch persistent WSL relay: {}",
            bounded_text(&output.stderr)
        )));
    }
    Ok(())
}

fn write_if_changed(path: &Path, bytes: &[u8]) -> io::Result<()> {
    if fs::read(path).is_ok_and(|current| current == bytes) {
        return Ok(());
    }
    let temporary = path.with_extension(format!("{}.tmp", Uuid::new_v4().simple()));
    fs::write(&temporary, bytes)?;
    #[cfg(target_os = "windows")]
    if path.exists() {
        fs::remove_file(path)?;
    }
    fs::rename(temporary, path)
}

fn wsl_path(distribution: &str, windows_path: &Path) -> io::Result<String> {
    let value = windows_path.to_string_lossy();
    let output = run_wsl(
        &["-d", distribution, "-e", "wslpath", "-a", "-u", &value],
        Duration::from_secs(5),
    )?;
    if !output.status.success() {
        return Err(io::Error::other(format!(
            "Could not map the WSL relay path: {}",
            bounded_text(&output.stderr)
        )));
    }
    let mapped = String::from_utf8_lossy(&output.stdout).trim().to_owned();
    if !mapped.starts_with('/') || mapped.contains('\0') {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "wslpath returned an invalid relay path.",
        ));
    }
    Ok(mapped)
}

fn run_wsl(arguments: &[&str], timeout: Duration) -> io::Result<std::process::Output> {
    let mut child = Command::new("wsl.exe")
        .args(arguments)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;
    if child.wait_timeout(timeout)?.is_none() {
        let _ = child.kill();
        let _ = child.wait();
        return Err(io::Error::new(
            io::ErrorKind::TimedOut,
            "WSL relay bootstrap timed out.",
        ));
    }
    child.wait_with_output()
}

fn bounded_text(bytes: &[u8]) -> String {
    let text = String::from_utf8_lossy(bytes).replace('\0', "");
    text.chars()
        .take(1000)
        .collect::<String>()
        .trim()
        .to_owned()
}

fn proxy_runtime(endpoint: RelayEndpoint, invocation: ProxyInvocation) -> io::Result<i32> {
    let mut stream = connect(&endpoint)?;
    write_json_line(
        &mut stream,
        &json!({
            "op": "spawn",
            "token": endpoint.token,
            "transportVersion": TRANSPORT_VERSION,
            "command": invocation.command,
            "args": invocation.args,
            "cwd": invocation.cwd,
        }),
    )?;
    let mut reader = BufReader::new(stream.try_clone()?);
    let response = read_json_line(&mut reader)?;
    if response.get("ok").and_then(Value::as_bool) != Some(true) {
        let message = response
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or("WSL relay rejected the runtime request.");
        return Err(io::Error::new(io::ErrorKind::ConnectionRefused, message));
    }
    stream.set_read_timeout(None)?;
    stream.set_write_timeout(None)?;
    let mut input_stream = stream.try_clone()?;
    thread::spawn(move || {
        let mut input = io::stdin().lock();
        let _ = io::copy(&mut input, &mut input_stream);
        let _ = input_stream.shutdown(Shutdown::Write);
    });

    let mut stdout = io::stdout().lock();
    let mut stderr = io::stderr().lock();
    loop {
        let mut header = [0_u8; 5];
        reader.read_exact(&mut header)?;
        let length = u32::from_be_bytes(header[1..5].try_into().expect("frame length")) as usize;
        if length > MAX_FRAME_BYTES {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "WSL relay frame is too large.",
            ));
        }
        let mut payload = vec![0_u8; length];
        reader.read_exact(&mut payload)?;
        match header[0] {
            CHANNEL_STDOUT => {
                stdout.write_all(&payload)?;
                stdout.flush()?;
            }
            CHANNEL_STDERR => {
                stderr.write_all(&payload)?;
                stderr.flush()?;
            }
            CHANNEL_EXIT if payload.len() == 4 => {
                let code = i32::from_be_bytes(payload.try_into().expect("exit code"));
                return Ok(code.clamp(0, 255));
            }
            _ => {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "WSL relay returned an unknown frame.",
                ));
            }
        }
    }
}

fn proxy_runtime_spool(
    endpoint: RelayEndpoint,
    endpoint_path: &Path,
    invocation: ProxyInvocation,
) -> io::Result<i32> {
    let mut stdout = io::stdout().lock();
    let mut stderr = io::stderr().lock();
    proxy_runtime_spool_to(
        endpoint,
        endpoint_path,
        invocation,
        true,
        &mut stdout,
        &mut stderr,
    )
}

fn proxy_runtime_spool_to(
    endpoint: RelayEndpoint,
    endpoint_path: &Path,
    invocation: ProxyInvocation,
    interactive_stdin: bool,
    stdout: &mut dyn Write,
    stderr: &mut dyn Write,
) -> io::Result<i32> {
    let relay_root = endpoint_path
        .parent()
        .and_then(Path::parent)
        .ok_or_else(|| {
            io::Error::new(io::ErrorKind::InvalidInput, "WSL relay path has no root.")
        })?;
    let session_directory = relay_root
        .join("spool")
        .join(format!("session-{}", Uuid::new_v4().simple()));
    fs::create_dir_all(&session_directory)?;
    let running = Arc::new(AtomicBool::new(true));
    let _session = SpoolSession {
        directory: session_directory.clone(),
        running: Arc::clone(&running),
    };
    let input_path = session_directory.join("stdin.bin");
    let input_closed_path = session_directory.join("stdin.closed");
    let heartbeat_path = session_directory.join("client-heartbeat");
    let output_path = session_directory.join("output.bin");
    fs::write(&input_path, [])?;
    fs::write(&output_path, [])?;
    fs::write(&heartbeat_path, now_ms().to_string())?;
    let request = serde_json::to_vec_pretty(&json!({
        "op": "spawn",
        "token": endpoint.token,
        "transportVersion": TRANSPORT_VERSION,
        "command": invocation.command,
        "args": invocation.args,
        "cwd": invocation.cwd,
    }))
    .map_err(io::Error::other)?;
    let request_temporary = session_directory.join("request.tmp");
    fs::write(&request_temporary, request)?;
    fs::rename(request_temporary, session_directory.join("request.json"))?;

    let heartbeat_running = Arc::clone(&running);
    let heartbeat_file = heartbeat_path.clone();
    thread::spawn(move || {
        while heartbeat_running.load(Ordering::Relaxed) {
            let _ = fs::write(&heartbeat_file, now_ms().to_string());
            thread::sleep(Duration::from_millis(500));
        }
    });
    if interactive_stdin {
        let input_running = Arc::clone(&running);
        thread::spawn(move || {
            let mut input = io::stdin().lock();
            let mut chunk = [0_u8; 64 * 1024];
            while input_running.load(Ordering::Relaxed) {
                let bytes = match input.read(&mut chunk) {
                    Ok(0) => break,
                    Ok(bytes) => bytes,
                    Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                    Err(_) => break,
                };
                let appended =
                    OpenOptions::new()
                        .append(true)
                        .open(&input_path)
                        .and_then(|mut output| {
                            output.write_all(&chunk[..bytes])?;
                            output.flush()
                        });
                if appended.is_err() {
                    break;
                }
            }
            if input_running.load(Ordering::Relaxed) {
                let committed_length = fs::metadata(&input_path).map(|metadata| metadata.len());
                if let Ok(committed_length) = committed_length {
                    let _ = fs::write(input_closed_path, committed_length.to_string());
                }
            }
        });
    } else {
        fs::write(input_closed_path, "0")?;
    }

    let mut output = OpenOptions::new().read(true).open(&output_path)?;
    let claim_path = session_directory.join("request.claimed.json");
    let claim_deadline = Instant::now() + Duration::from_secs(10);
    let mut claimed = false;
    let mut relay_seen = Instant::now();
    let mut relay_check = Instant::now();
    let mut buffered = Vec::new();
    let result = 'output: loop {
        let mut chunk = [0_u8; 64 * 1024];
        let bytes = output.read(&mut chunk)?;
        if bytes > 0 {
            buffered.extend_from_slice(&chunk[..bytes]);
        }
        let mut consumed = 0;
        while buffered.len().saturating_sub(consumed) >= 5 {
            let channel = buffered[consumed];
            let length = u32::from_be_bytes(
                buffered[consumed + 1..consumed + 5]
                    .try_into()
                    .expect("frame length"),
            ) as usize;
            if length > MAX_FRAME_BYTES {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "WSL relay frame is too large.",
                ));
            }
            if buffered.len().saturating_sub(consumed) < 5 + length {
                break;
            }
            let payload_start = consumed + 5;
            let payload_end = payload_start + length;
            let payload = &buffered[payload_start..payload_end];
            match channel {
                CHANNEL_STDOUT => {
                    stdout.write_all(payload)?;
                    stdout.flush()?;
                }
                CHANNEL_STDERR => {
                    stderr.write_all(payload)?;
                    stderr.flush()?;
                }
                CHANNEL_EXIT if payload.len() == 4 => {
                    break 'output i32::from_be_bytes(payload.try_into().expect("exit code"))
                        .clamp(0, 255);
                }
                _ => {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        "WSL relay returned an unknown frame.",
                    ));
                }
            }
            consumed = payload_end;
        }
        if consumed > 0 {
            buffered.drain(..consumed);
        }
        claimed = claimed || claim_path.exists();
        if !claimed && Instant::now() >= claim_deadline {
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "WSL relay did not claim the runtime request.",
            ));
        }
        if relay_check.elapsed() >= Duration::from_secs(1) {
            relay_check = Instant::now();
            if load_endpoint(endpoint_path).is_ok_and(|current| {
                endpoint_matches(&current, &invocation.distribution) && relay_is_alive(&current)
            }) {
                relay_seen = Instant::now();
            } else if relay_seen.elapsed() > Duration::from_secs(6) {
                return Err(io::Error::new(
                    io::ErrorKind::ConnectionAborted,
                    "WSL relay stopped while the runtime was active.",
                ));
            }
        }
        thread::sleep(Duration::from_millis(5));
    };
    Ok(result)
}

struct SpoolSession {
    directory: PathBuf,
    running: Arc<AtomicBool>,
}

impl Drop for SpoolSession {
    fn drop(&mut self) {
        self.running.store(false, Ordering::Relaxed);
        let _ = fs::remove_dir_all(&self.directory);
    }
}

fn write_json_line(stream: &mut TcpStream, value: &Value) -> io::Result<()> {
    serde_json::to_writer(&mut *stream, value).map_err(io::Error::other)?;
    stream.write_all(b"\n")?;
    stream.flush()
}

fn read_json_line(reader: &mut BufReader<TcpStream>) -> io::Result<Value> {
    let mut line = String::new();
    let bytes = reader.read_line(&mut line)?;
    if bytes == 0 || bytes > 64 * 1024 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "WSL relay response is missing or too large.",
        ));
    }
    serde_json::from_str(&line).map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))
}

#[cfg(test)]
mod tests {
    use super::{ProxyInvocation, hex_name, wrap_wsl_command};
    use zommi_core::{ExecutionHost, RuntimeCommand, RuntimeTarget};

    #[test]
    fn wraps_wsl_runtime_in_the_persistent_proxy() {
        let target = RuntimeTarget {
            id: "target".into(),
            runtime_id: "codex".into(),
            adapter_id: "codex-app-server".into(),
            display_name: "Codex".into(),
            protocol_name: "Codex app-server".into(),
            executable_path: "/home/u/bin/codex".into(),
            execution_host: ExecutionHost {
                id: "wsl:ubuntu".into(),
                kind: "wsl".into(),
                platform: "linux".into(),
                display_name: "WSL · Ubuntu".into(),
                is_default: true,
                name: Some("Ubuntu".into()),
            },
            status: "detected".into(),
            priority: 10,
            capability_hints: Vec::new(),
            runtime_home: Some("/home/u".into()),
            source: None,
            endpoint: None,
            profile_id: None,
        };
        let direct = RuntimeCommand {
            command: "wsl.exe".into(),
            args: vec![
                "-d".into(),
                "Ubuntu".into(),
                "-e".into(),
                "/usr/bin/env".into(),
                "ZOMMI_RUNTIME_CHILD=1".into(),
                "/home/u/bin/codex".into(),
                "app-server".into(),
            ],
            working_directory: None,
        };
        let wrapped = wrap_wsl_command(&target, direct).expect("wrap relay command");
        assert!(wrapped.command.ends_with(std::env::consts::EXE_SUFFIX));
        assert_eq!(wrapped.args[0], "--wsl-proxy");
        assert_eq!(wrapped.args[2], "Ubuntu");
        assert_eq!(wrapped.args[4], "/home/u");
        assert_eq!(wrapped.args[6], "/usr/bin/env");
    }

    #[test]
    fn validates_proxy_arguments_without_shell_parsing() {
        let parsed = ProxyInvocation::parse(&[
            "--distribution".into(),
            "Ubuntu 24.04".into(),
            "--cwd".into(),
            "/home/u".into(),
            "--".into(),
            "/usr/bin/env".into(),
            "VALUE=a b".into(),
            "/home/u/bin/codex".into(),
        ])
        .expect("valid proxy arguments");
        assert_eq!(parsed.distribution, "Ubuntu 24.04");
        assert_eq!(parsed.args[0], "VALUE=a b");
        assert!(
            ProxyInvocation::parse(&[
                "--distribution".into(),
                "Ubuntu".into(),
                "--cwd".into(),
                "/".into(),
                "--".into(),
                "relative-command".into(),
            ])
            .is_err()
        );
        assert_eq!(hex_name("Ubuntu"), "5562756e7475");
    }
}
