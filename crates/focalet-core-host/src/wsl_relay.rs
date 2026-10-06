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

use focalet_core::{
    RuntimeCommand, RuntimeTarget, runtime_discovery::windows_wsl_executable,
    runtime_targets_from_wsl_probe, wsl_runtime_probe_script,
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use uuid::Uuid;
use wait_timeout::ChildExt;

// Readiness challenges and session heartbeats require the matching daemon.
const TRANSPORT_VERSION: u32 = 9;
const BOOTSTRAP_TIMEOUT: Duration = Duration::from_secs(30);
const READINESS_TIMEOUT: Duration = Duration::from_secs(1);
const LOOKUP_TIMEOUT: Duration = Duration::from_secs(25);
const ENDPOINT_SCHEMA_VERSION: u32 = 1;
const MAX_FRAME_BYTES: usize = 16 * 1024 * 1024;
const CHANNEL_STDOUT: u8 = 1;
const CHANNEL_STDERR: u8 = 2;
const CHANNEL_EXIT: u8 = 3;
const RELAY_SOURCE: &str = include_str!("../../../scripts/focalet-wsl-relay.js");
const LAUNCHER_SOURCE: &str = include_str!("../../../scripts/launch-wsl-relay.sh");
const SHELL_PROBE_SOURCE: &str = include_str!("../../../scripts/probe-wsl-runtimes.sh");
const RESOLVE_EXECUTABLE_SOURCE: &str = include_str!("../../../scripts/resolve-wsl-executable.sh");

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
        full_access: direct.full_access,
        command: proxy.to_string_lossy().into_owned(),
        args,
        working_directory: None,
    })
}

pub fn run_proxy(arguments: &[String]) -> io::Result<i32> {
    let invocation = ProxyInvocation::parse(arguments)?;
    let endpoint_path = endpoint_path(&invocation.distribution)?;
    eprintln!("Focalet: preparing WSL transport.");
    let endpoint = ensure_relay(&invocation.distribution, &endpoint_path)?;
    eprintln!("Focalet: WSL transport ready; launching agent.");
    if env::var("FOCALET_WSL_RELAY_TRANSPORT").as_deref() == Ok("tcp") {
        proxy_runtime(endpoint, invocation)
    } else {
        proxy_runtime_spool(endpoint, &endpoint_path, invocation)
    }
}

/// Complete cold WSL startup before an adapter starts its protocol deadline.
pub fn prepare_transport(distribution: &str) -> io::Result<()> {
    if !valid_distribution(distribution) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "Invalid WSL distribution.",
        ));
    }
    ensure_relay(distribution, &endpoint_path(distribution)?).map(|_| ())
}

pub fn cached_default_relay_available(targets: &[RuntimeTarget]) -> bool {
    targets
        .iter()
        .filter(|target| target.execution_host.kind == "wsl" && target.execution_host.is_default)
        .filter_map(|target| target.execution_host.name.as_deref())
        .any(|distribution| {
            endpoint_path(distribution).is_ok_and(|path| {
                load_endpoint(&path).is_ok_and(|endpoint| {
                    endpoint_matches(&endpoint, distribution) && relay_responds(&endpoint, &path)
                })
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
            endpoint_matches(&endpoint, distribution)
                && endpoint_path(distribution).is_ok_and(|path| relay_responds(&endpoint, &path))
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
            args: vec!["-c".into(), wsl_runtime_probe_script()],
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
            Some(Instant::now() + LOOKUP_TIMEOUT),
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

/// Checks a directory inside the target distribution through the same
/// authenticated relay used to launch runtimes. This avoids changing WSL
/// configuration or starting a second interactive terminal.
pub fn workspace_directory_exists(target: &RuntimeTarget, path: &str) -> io::Result<bool> {
    if target.execution_host.kind != "wsl" || !path.starts_with('/') || path.contains('\0') {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "WSL workspace paths must be absolute Linux paths.",
        ));
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
    let endpoint_path = endpoint_path(distribution)?;
    let endpoint = ensure_relay(distribution, &endpoint_path)?;
    let invocation = ProxyInvocation {
        distribution: distribution.into(),
        cwd: "/".into(),
        command: "/usr/bin/test".into(),
        args: vec!["-d".into(), path.into()],
    };
    let mut stdout = Vec::new();
    let mut stderr = Vec::new();
    match proxy_runtime_spool_to(
        endpoint,
        &endpoint_path,
        invocation,
        false,
        &mut stdout,
        &mut stderr,
        Some(Instant::now() + LOOKUP_TIMEOUT),
    )? {
        0 => Ok(true),
        1 => Ok(false),
        status => Err(io::Error::other(format!(
            "WSL workspace check exited with {status}: {}",
            bounded_text(&stderr)
        ))),
    }
}

/// Resolve a configured CLI inside its distribution, never against Windows.
/// Persist the absolute result so runtime launches and sign-in use the same path.
pub fn resolve_runtime_executable(distribution: &str, path: &str) -> io::Result<String> {
    if !valid_distribution(distribution)
        || !(path.starts_with('/') || path.starts_with("~/"))
        || path.len() > 4096
        || path.contains('\0')
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "Choose a WSL distribution and an absolute Linux path or ~/path for the CLI.",
        ));
    }
    let endpoint_path = endpoint_path(distribution)?;
    let endpoint = ensure_relay(distribution, &endpoint_path)?;
    let invocation = ProxyInvocation {
        distribution: distribution.into(),
        cwd: "/".into(),
        command: "/bin/sh".into(),
        args: vec![
            "-c".into(),
            normalize_shell_script(RESOLVE_EXECUTABLE_SOURCE),
            "focalet-resolve-cli".into(),
            path.into(),
        ],
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
        Some(Instant::now() + LOOKUP_TIMEOUT),
    )?;
    let resolved = String::from_utf8(stdout).map_err(io::Error::other)?;
    if status != 0 {
        return Err(io::Error::other(format!(
            "{distribution}: {}",
            bounded_text(&stderr)
        )));
    }
    if !resolved.starts_with('/') || resolved.contains('\0') || resolved.len() > 4096 {
        return Err(io::Error::other("WSL returned an invalid CLI path."));
    }
    Ok(resolved)
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
    if let Some(configured) = env::var_os("FOCALET_WSL_RELAY_ENDPOINT") {
        return Ok(PathBuf::from(configured));
    }
    let root = env::var_os("LOCALAPPDATA")
        .map(PathBuf::from)
        .unwrap_or_else(env::temp_dir)
        .join("Focalet")
        .join("wsl-relay")
        .join(format!("v{TRANSPORT_VERSION}"));
    Ok(root.join("endpoints").join(format!(
        "{}.json",
        hex_name(&distribution.to_ascii_lowercase())
    )))
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
        && relay_responds(&endpoint, endpoint_path)
    {
        return Ok(endpoint);
    }
    if env::var_os("FOCALET_WSL_RELAY_ENDPOINT").is_some() {
        return Err(io::Error::new(
            io::ErrorKind::ConnectionRefused,
            "Configured WSL relay is not available.",
        ));
    }
    let deadline = Instant::now() + BOOTSTRAP_TIMEOUT;
    // Several core/catalog processes can connect to the same distribution.
    // The OS releases this lock even if its owner crashes; no stale PID lease.
    fs::create_dir_all(
        endpoint_path
            .parent()
            .ok_or_else(|| io::Error::other("WSL endpoint has no parent."))?,
    )?;
    let lock = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(endpoint_path.with_extension("launch.lock"))?;
    loop {
        match lock.try_lock() {
            Ok(()) => break,
            Err(std::fs::TryLockError::WouldBlock) if Instant::now() < deadline => {
                thread::sleep(Duration::from_millis(50));
            }
            Err(std::fs::TryLockError::WouldBlock) => {
                return Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    "WSL is still starting. Retry the connection.",
                ));
            }
            Err(std::fs::TryLockError::Error(error)) => return Err(error),
        }
    }
    // Another requester may have completed startup while we waited.
    if let Ok(endpoint) = load_endpoint(endpoint_path)
        && endpoint_matches(&endpoint, distribution)
        && relay_responds(&endpoint, endpoint_path)
    {
        return Ok(endpoint);
    }
    start_relay(
        distribution,
        endpoint_path,
        deadline.saturating_duration_since(Instant::now()),
    )?;
    let mut last_error = None;
    while Instant::now() < deadline {
        match load_endpoint(endpoint_path).and_then(|endpoint| {
            if !endpoint_matches(&endpoint, distribution) {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "WSL relay endpoint identity does not match.",
                ));
            }
            if relay_responds(&endpoint, endpoint_path) {
                Ok(endpoint)
            } else {
                Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    "WSL started but its transport did not answer. Retry the connection.",
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

fn relay_responds(endpoint: &RelayEndpoint, endpoint_path: &Path) -> bool {
    probe_relay(endpoint, endpoint_path).unwrap_or(false)
}

fn probe_relay(endpoint: &RelayEndpoint, endpoint_path: &Path) -> io::Result<bool> {
    let root = endpoint_path
        .parent()
        .and_then(Path::parent)
        .ok_or_else(|| io::Error::other("WSL endpoint has no root."))?;
    let directory = root
        .join("spool")
        .join(format!("probe-{}", Uuid::new_v4().simple()));
    fs::create_dir_all(&directory)?;
    let _cleanup = SpoolSession {
        directory: directory.clone(),
        running: Arc::new(AtomicBool::new(false)),
    };
    let nonce = Uuid::new_v4().simple().to_string();
    let request = json!({"op":"ping", "token":endpoint.token, "transportVersion":TRANSPORT_VERSION, "nonce":nonce});
    fs::write(directory.join("request.tmp"), serde_json::to_vec(&request)?)?;
    fs::rename(
        directory.join("request.tmp"),
        directory.join("request.json"),
    )?;
    let deadline = Instant::now() + READINESS_TIMEOUT;
    while Instant::now() < deadline {
        if let Ok(bytes) = fs::read(directory.join("ready.json"))
            && let Ok(reply) = serde_json::from_slice::<Value>(&bytes)
            && reply["nonce"] == nonce
            && reply["pid"] == endpoint.pid
            && reply["transportVersion"] == TRANSPORT_VERSION
        {
            return Ok(true);
        }
        thread::sleep(Duration::from_millis(10));
    }
    Ok(false)
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

fn start_relay(distribution: &str, endpoint_path: &Path, timeout: Duration) -> io::Result<()> {
    let root = endpoint_path
        .parent()
        .and_then(Path::parent)
        .ok_or_else(|| {
            io::Error::new(io::ErrorKind::InvalidInput, "WSL relay path has no root.")
        })?;
    fs::create_dir_all(root.join("endpoints"))?;
    // Each distribution's bootstrap is protected by its own launch lock.
    // Do not race another distribution while replacing scripts on Windows.
    let bootstrap_name = hex_name(&distribution.to_ascii_lowercase());
    let bootstrap = root.join("bootstrap").join(&bootstrap_name);
    fs::create_dir_all(&bootstrap)?;
    let relay = bootstrap.join("focalet-wsl-relay.js");
    let launcher = bootstrap.join("launch-wsl-relay.sh");
    let shell_probe = bootstrap.join("probe-wsl-runtimes.sh");
    let relay_source = RELAY_SOURCE.replace("\r\n", "\n");
    let launcher_source = normalize_shell_script(LAUNCHER_SOURCE);
    write_if_changed(&relay, relay_source.as_bytes())?;
    write_if_changed(&launcher, launcher_source.as_bytes())?;
    write_if_changed(
        &shell_probe,
        normalize_shell_script(SHELL_PROBE_SOURCE).as_bytes(),
    )?;
    match fs::remove_file(endpoint_path) {
        Ok(()) => {}
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => return Err(error),
    }

    let endpoint_name = endpoint_path
        .file_name()
        .and_then(|value| value.to_str())
        .ok_or_else(|| {
            io::Error::new(io::ErrorKind::InvalidInput, "WSL endpoint name is invalid.")
        })?;
    let token = Uuid::new_v4().simple().to_string() + &Uuid::new_v4().simple().to_string();
    let version = TRANSPORT_VERSION.to_string();
    let output = run_wsl(
        &[
            "-d",
            distribution,
            "--cd",
            "/",
            "-e",
            "/bin/sh",
            "-c",
            "set -eu; focalet_root=$(wslpath -a -u \"$1\"); exec /bin/sh \"$focalet_root/bootstrap/$6/launch-wsl-relay.sh\" \"$focalet_root/bootstrap/$6/focalet-wsl-relay.js\" \"$focalet_root/endpoints/$2\" \"$3\" \"$4\" \"$5\"",
            "focalet-relay-bootstrap",
            &root.to_string_lossy(),
            endpoint_name,
            &token,
            &version,
            distribution,
            &bootstrap_name,
        ],
        timeout,
    )?;
    if output.status.code() == Some(43) {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            "WSL needs Node.js 18 or newer to connect agent runtimes. Install Node in this distribution, then retry.",
        ));
    }
    if !output.status.success() {
        return Err(io::Error::other(format!(
            "Could not launch persistent WSL relay: {}",
            bounded_text(&output.stderr)
        )));
    }
    Ok(())
}

fn normalize_shell_script(source: &str) -> String {
    // Windows Git checkouts may use CRLF; /bin/sh must receive Unix lines.
    source.replace("\r\n", "\n")
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

fn run_wsl(arguments: &[&str], timeout: Duration) -> io::Result<std::process::Output> {
    let executable = windows_wsl_executable();
    let mut child = Command::new(&executable)
        .args(arguments)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| {
            io::Error::new(
                error.kind(),
                format!("Could not launch WSL through '{executable}': {error}"),
            )
        })?;
    if child.wait_timeout(timeout)?.is_none() {
        let _ = child.kill();
        let _ = child.wait();
        return Err(io::Error::new(
            io::ErrorKind::TimedOut,
            "WSL did not finish starting. Open this distribution in Windows Terminal, then retry the connection; your chats are preserved.",
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
        None,
    )
}

fn proxy_runtime_spool_to(
    endpoint: RelayEndpoint,
    endpoint_path: &Path,
    invocation: ProxyInvocation,
    interactive_stdin: bool,
    stdout: &mut dyn Write,
    stderr: &mut dyn Write,
    deadline: Option<Instant>,
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
    let mut heartbeat_value = String::new();
    let mut buffered = Vec::new();
    let result = 'output: loop {
        if deadline.is_some_and(|deadline| Instant::now() >= deadline) {
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "WSL lookup did not finish. Check that the distribution and its login shell respond, then retry.",
            ));
        }
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
            // Observe this session's relay with a monotonic clock. A stale
            // endpoint, clock jump, or a replacement daemon is not liveness.
            if let Ok(current) = fs::read_to_string(session_directory.join("relay-heartbeat"))
                && !current.is_empty()
                && current != heartbeat_value
            {
                heartbeat_value = current;
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
    use super::{LAUNCHER_SOURCE, ProxyInvocation, RELAY_SOURCE, hex_name, wrap_wsl_command};
    use focalet_core::{ExecutionHost, RuntimeCommand, RuntimeTarget};

    #[cfg(unix)]
    #[test]
    fn a_healthy_relay_cannot_keep_a_stalled_lookup_running_forever() {
        use std::{
            fs,
            process::{Child, Command, Stdio},
            thread,
            time::{Duration, Instant},
        };
        struct Relay {
            child: Child,
            root: std::path::PathBuf,
        }
        impl Drop for Relay {
            fn drop(&mut self) {
                let _ = self.child.kill();
                let _ = self.child.wait();
                let _ = fs::remove_dir_all(&self.root);
            }
        }
        let root = std::env::temp_dir().join(format!("focalet-lookup-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(root.join("endpoints")).unwrap();
        let endpoint_path = root.join("endpoints/test.json");
        let script = root.join("relay.js");
        fs::write(&script, RELAY_SOURCE).unwrap();
        let _relay = Relay {
            child: Command::new("node")
                .arg(&script)
                .args([
                    "--endpoint",
                    endpoint_path.to_str().unwrap(),
                    "--token",
                    "0123456789abcdef0123456789abcdef",
                    "--version",
                    &super::TRANSPORT_VERSION.to_string(),
                    "--distribution",
                    "test",
                ])
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .unwrap(),
            root,
        };
        let ready = Instant::now() + Duration::from_secs(5);
        let endpoint = loop {
            if let Ok(endpoint) = super::load_endpoint(&endpoint_path) {
                break endpoint;
            }
            assert!(Instant::now() < ready, "fixture relay did not start");
            thread::sleep(Duration::from_millis(10));
        };
        let mut output = Vec::new();
        let result = super::proxy_runtime_spool_to(
            endpoint,
            &endpoint_path,
            ProxyInvocation {
                distribution: "test".into(),
                cwd: "/".into(),
                command: "/bin/sh".into(),
                args: vec!["-c".into(), "printf waiting; sleep 2".into()],
            },
            false,
            &mut output,
            &mut Vec::new(),
            Some(Instant::now() + Duration::from_secs(1)),
        );
        assert_eq!(result.unwrap_err().kind(), std::io::ErrorKind::TimedOut);
        assert_eq!(output, b"waiting");
        // Dropping the request removes its spool and cancels the lookup child.
        thread::sleep(Duration::from_millis(100));
    }

    #[test]
    fn per_chat_permissions_apply_inside_an_already_wrapped_wsl_command() {
        let targets = focalet_core::runtime_targets_from_wsl_probe("Ubuntu", true,
            b"__FOCALET_RUNTIME_HOME__/home/u\n__FOCALET_RUNTIME_PATH__hermes\t/home/u/bin/hermes\n__FOCALET_RUNTIME_PATH__opencode\t/home/u/bin/opencode\n__FOCALET_RUNTIME_PATH__gemini\t/home/u/bin/gemini\n__FOCALET_RUNTIME_PATH__claude\t/home/u/bin/claude\n");
        let mut checked = 0;
        for target in targets {
            let expected = match target.adapter_id.as_str() {
                "hermes-acp" => "HERMES_YOLO_MODE=1",
                "opencode-acp" => "OPENCODE_PERMISSION={\"*\":\"allow\"}",
                "gemini-acp" => "yolo",
                "claude-stream-json" => "bypassPermissions",
                _ => continue,
            };
            let normal =
                wrap_wsl_command(&target, focalet_core::command_for_target(&target)).unwrap();
            let mut full = normal.clone();
            full.enable_full_access(&target).unwrap();
            let boundary = full.args.iter().position(|v| v == "--").unwrap();
            assert!(full.args[boundary + 1..].contains(&expected.to_owned()));
            assert!(!normal.args.contains(&expected.to_owned()));
            assert_eq!(full.command, normal.command);
            checked += 1;
        }
        assert_eq!(checked, 4);
    }

    #[cfg(unix)]
    #[test]
    fn resolves_wsl_cli_paths_in_the_linux_home_without_shell_interpolation() {
        use std::{fs, os::unix::fs::PermissionsExt, process::Command};

        let root = std::env::temp_dir().join(format!("focalet-cli-path-{}", uuid::Uuid::new_v4()));
        let bin = root.join(".hermes/bin");
        fs::create_dir_all(&bin).unwrap();
        let executable = bin.join("codex with spaces $(touch injected) `touch injected-too`");
        fs::write(&executable, "#!/bin/sh\nexit 0\n").unwrap();
        fs::set_permissions(&executable, fs::Permissions::from_mode(0o755)).unwrap();
        // Exercise the line endings embedded by a Windows Git checkout even
        // when the regression runs on a Unix build host.
        let windows_script = super::RESOLVE_EXECUTABLE_SOURCE
            .replace("\r\n", "\n")
            .replace('\n', "\r\n");
        let script = super::normalize_shell_script(&windows_script);
        let probe = |path: &str| {
            Command::new("/bin/sh")
                .args(["-c", &script, "focalet-resolve-cli", path])
                .env("HOME", &root)
                .current_dir(&root)
                .output()
                .unwrap()
        };
        let relative = format!(
            "~/.hermes/bin/{}",
            executable.file_name().unwrap().to_str().unwrap()
        );
        for path in [relative.as_str(), executable.to_str().unwrap()] {
            let result = probe(path);
            assert!(
                result.status.success(),
                "{}",
                String::from_utf8_lossy(&result.stderr)
            );
            assert_eq!(
                String::from_utf8(result.stdout).unwrap(),
                executable.to_str().unwrap()
            );
        }
        assert!(!root.join("injected").exists());
        assert!(!root.join("injected-too").exists());
        let missing = probe("~/.hermes/bin/missing");
        assert_eq!(missing.status.code(), Some(2));
        assert!(String::from_utf8_lossy(&missing.stderr).contains("CLI file not found in WSL:"));
        assert_eq!(probe(".hermes/bin/codex").status.code(), Some(64));
        assert_eq!(probe(bin.to_str().unwrap()).status.code(), Some(2));
        fs::set_permissions(&executable, fs::Permissions::from_mode(0o644)).unwrap();
        assert_eq!(probe(&relative).status.code(), Some(126));
        fs::remove_dir_all(root).unwrap();
    }

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
            launch_path: None,
            source: None,
            endpoint: None,
            profile_id: None,
        };
        let mut direct = RuntimeCommand {
            full_access: false,
            command: "wsl.exe".into(),
            args: vec![
                "-d".into(),
                "Ubuntu".into(),
                "-e".into(),
                "/usr/bin/env".into(),
                "-u".into(),
                "PARENT_APP_AGENT_HOOK_ENDPOINT".into(),
                "-u".into(),
                "PARENT_APP_PANE_KEY".into(),
                "FOCALET_RUNTIME_CHILD=1".into(),
                "/home/u/bin/codex".into(),
                "app-server".into(),
            ],
            working_directory: None,
        };
        direct.enable_full_access(&target).unwrap();
        let wrapped = wrap_wsl_command(&target, direct).expect("wrap relay command");
        assert!(wrapped.full_access);
        assert!(
            wrapped
                .args
                .ends_with(&["/home/u/bin/codex".into(), "app-server".into()])
        );
        assert!(wrapped.command.ends_with(std::env::consts::EXE_SUFFIX));
        assert_eq!(wrapped.args[0], "--wsl-proxy");
        assert_eq!(wrapped.args[2], "Ubuntu");
        assert_eq!(wrapped.args[4], "/home/u");
        assert_eq!(wrapped.args[6], "/usr/bin/env");
        assert!(
            wrapped
                .args
                .windows(2)
                .any(|values| values == ["-u", "PARENT_APP_AGENT_HOOK_ENDPOINT"])
        );
        assert!(
            wrapped
                .args
                .windows(2)
                .any(|values| values == ["-u", "PARENT_APP_PANE_KEY"])
        );
        assert!(wrapped.args.contains(&"FOCALET_RUNTIME_CHILD=1".into()));
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

    #[test]
    fn embedded_relay_isolates_parent_context_for_every_runtime_child() {
        assert_eq!(RELAY_SOURCE.matches("env: runtimeEnvironment()").count(), 2);
    }

    #[test]
    fn embedded_launcher_waits_for_a_proven_endpoint() {
        assert!(!LAUNCHER_SOURCE.contains("setsid -f"));
        assert!(LAUNCHER_SOURCE.contains("[ -s \"$endpoint_file\" ] && exit 0"));
        assert!(LAUNCHER_SOURCE.contains("kill -0 \"$relay_pid\""));
    }
}
