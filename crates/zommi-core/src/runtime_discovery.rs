use std::{
    collections::{HashMap, HashSet},
    env, fs,
    io::{self, Read},
    path::{Path, PathBuf},
    process::{Command, Stdio},
    time::Duration,
};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use wait_timeout::ChildExt;

const PROBE_TIMEOUT: Duration = Duration::from_secs(4);

const CODEX_CAPABILITY_HINTS: &[&str] = &[
    "session.list.v1",
    "session.create.v1",
    "session.resume.v1",
    "history.read.v1",
    "turn.stream.v1",
    "turn.interrupt.v1",
    "input.image.v1",
    "model.select.v1",
    "reasoning.select.v1",
];

const PI_CAPABILITY_HINTS: &[&str] = &[
    "session.create.v1",
    "session.resume.v1",
    "history.read.v1",
    "turn.stream.v1",
    "turn.interrupt.v1",
    "turn.steer.v1",
    "input.image.v1",
    "model.select.v1",
    "reasoning.select.v1",
    "question.resolve.v1",
];

const ACP_CAPABILITY_HINTS: &[&str] = &[
    "session.list.v1",
    "session.create.v1",
    "session.resume.v1",
    "history.read.v1",
    "turn.stream.v1",
    "turn.interrupt.v1",
    "input.image.v1",
    "approval.resolve.v1",
    "question.resolve.v1",
    "model.select.v1",
];

const HERMES_GATEWAY_CAPABILITY_HINTS: &[&str] = &[
    "session.list.v1",
    "session.create.v1",
    "session.resume.v1",
    "history.read.v1",
    "turn.stream.v1",
    "turn.interrupt.v1",
    "input.image.v1",
    "approval.resolve.v1",
    "question.resolve.v1",
    "model.select.v1",
    "reasoning.select.v1",
];

const OPENCLAW_GATEWAY_CAPABILITY_HINTS: &[&str] = &[
    "session.list.v1",
    "session.create.v1",
    "session.resume.v1",
    "history.read.v1",
    "turn.stream.v1",
    "turn.interrupt.v1",
    "input.image.v1",
    "approval.resolve.v1",
    "question.resolve.v1",
    "operation.idempotency.v1",
];

#[derive(Clone, Copy)]
struct CatalogEntry {
    executable: &'static str,
    runtime_id: &'static str,
    adapter_id: &'static str,
    display_name: &'static str,
    protocol_name: &'static str,
    priority: u32,
    capability_hints: &'static [&'static str],
}

const RUNTIME_CATALOG: &[CatalogEntry] = &[
    CatalogEntry {
        executable: "codex",
        runtime_id: "codex",
        adapter_id: "codex-app-server",
        display_name: "Codex",
        protocol_name: "Codex app-server",
        priority: 10,
        capability_hints: CODEX_CAPABILITY_HINTS,
    },
    CatalogEntry {
        executable: "pi",
        runtime_id: "pi",
        adapter_id: "pi-rpc",
        display_name: "Pi",
        protocol_name: "Pi RPC",
        priority: 20,
        capability_hints: PI_CAPABILITY_HINTS,
    },
    CatalogEntry {
        executable: "hermes",
        runtime_id: "hermes",
        adapter_id: "hermes-acp",
        display_name: "Hermes",
        protocol_name: "ACP",
        priority: 30,
        capability_hints: ACP_CAPABILITY_HINTS,
    },
    CatalogEntry {
        executable: "hermes",
        runtime_id: "hermes",
        adapter_id: "hermes-gateway",
        display_name: "Hermes",
        protocol_name: "Gateway",
        priority: 31,
        capability_hints: HERMES_GATEWAY_CAPABILITY_HINTS,
    },
    CatalogEntry {
        executable: "openclaw",
        runtime_id: "openclaw",
        adapter_id: "openclaw-acp",
        display_name: "OpenClaw",
        protocol_name: "ACP",
        priority: 40,
        capability_hints: ACP_CAPABILITY_HINTS,
    },
    CatalogEntry {
        executable: "claude",
        runtime_id: "claude",
        adapter_id: "pty-compatibility",
        display_name: "Claude CLI",
        protocol_name: "Terminal compatibility",
        priority: 1_000,
        capability_hints: &["turn.stream.v1"],
    },
];

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ExecutionHost {
    pub id: String,
    pub kind: String,
    pub platform: String,
    pub display_name: String,
    pub is_default: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RuntimeTarget {
    pub id: String,
    pub runtime_id: String,
    pub adapter_id: String,
    pub display_name: String,
    pub protocol_name: String,
    pub executable_path: String,
    pub execution_host: ExecutionHost,
    pub status: String,
    pub priority: u32,
    pub capability_hints: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub runtime_home: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub endpoint: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub profile_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RuntimeCommand {
    pub command: String,
    pub args: Vec<String>,
    pub working_directory: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ConfiguredRuntimeOverride {
    pub id: String,
    pub adapter_id: String,
    pub execution_host: ExecutionHost,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub executable_path: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub endpoint: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub profile_id: Option<String>,
}

#[derive(Debug, Clone)]
pub struct RuntimeOverrideStore {
    path: PathBuf,
}

impl RuntimeOverrideStore {
    pub fn platform_default() -> Self {
        if let Some(path) = env::var_os("ZOMMI_RUNTIME_OVERRIDES_PATH") {
            return Self { path: path.into() };
        }
        let path = if cfg!(target_os = "windows") {
            env::var_os("LOCALAPPDATA")
                .map(PathBuf::from)
                .unwrap_or_else(env::temp_dir)
                .join("Zommi")
                .join("runtime-overrides.json")
        } else if cfg!(target_os = "macos") {
            env::var_os("HOME")
                .map(PathBuf::from)
                .unwrap_or_else(env::temp_dir)
                .join("Library")
                .join("Application Support")
                .join("Zommi")
                .join("runtime-overrides.json")
        } else {
            env::var_os("XDG_CONFIG_HOME")
                .map(PathBuf::from)
                .or_else(|| env::var_os("HOME").map(|home| PathBuf::from(home).join(".config")))
                .unwrap_or_else(env::temp_dir)
                .join("zommi")
                .join("runtime-overrides.json")
        };
        Self { path }
    }

    pub fn at(path: PathBuf) -> Self {
        Self { path }
    }

    pub fn load(&self) -> io::Result<Vec<ConfiguredRuntimeOverride>> {
        let bytes = match fs::read(&self.path) {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
            Err(error) => return Err(error),
        };
        serde_json::from_slice(&bytes)
            .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))
    }

    pub fn save(&self, overrides: &[ConfiguredRuntimeOverride]) -> io::Result<()> {
        if let Some(parent) = self.path.parent() {
            fs::create_dir_all(parent)?;
        }
        let bytes = serde_json::to_vec_pretty(overrides).map_err(io::Error::other)?;
        fs::write(&self.path, bytes)
    }
}

pub fn discover_runtime_targets() -> Vec<RuntimeTarget> {
    discover_runtime_targets_with(&env::vars().collect(), env::consts::OS)
}

pub fn discover_runtime_targets_with_overrides(
    overrides: &[ConfiguredRuntimeOverride],
) -> Vec<RuntimeTarget> {
    let mut targets = discover_runtime_targets();
    targets.extend(
        overrides
            .iter()
            .filter_map(|configured| target_from_override(configured, env::consts::OS).ok()),
    );
    deduplicate_targets(targets)
}

pub fn target_from_override(
    configured: &ConfiguredRuntimeOverride,
    platform: &str,
) -> Result<RuntimeTarget, String> {
    if configured.id.trim().is_empty() || configured.id.len() > 256 {
        return Err("Runtime override id is invalid.".into());
    }
    if configured.adapter_id == "openclaw-gateway" {
        let endpoint = configured
            .endpoint
            .as_deref()
            .ok_or_else(|| "Direct Gateway override requires an endpoint.".to_owned())?;
        let endpoint = validate_gateway_endpoint(endpoint).map_err(|_| {
            "Gateway endpoint must be a credential-free ws:// or wss:// URL.".to_owned()
        })?;
        if configured
            .profile_id
            .as_deref()
            .is_some_and(|value| !valid_profile_id(value))
        {
            return Err("Gateway profile id is invalid.".into());
        }
        let mut target = openclaw_gateway_target(endpoint, platform, configured.profile_id.clone());
        target.source = Some("configured-ui".into());
        return Ok(target);
    }

    let entry = RUNTIME_CATALOG
        .iter()
        .find(|entry| entry.adapter_id == configured.adapter_id)
        .ok_or_else(|| "Runtime adapter is not supported.".to_owned())?;
    let path = configured
        .executable_path
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty() && value.len() <= 4096 && !value.contains('\0'))
        .ok_or_else(|| "Runtime override requires an executable path.".to_owned())?;
    match configured.execution_host.kind.as_str() {
        "native" => {
            if configured.execution_host.platform != platform || !Path::new(path).is_absolute() {
                return Err(
                    "Native runtime override requires an absolute path on this platform.".into(),
                );
            }
        }
        "wsl" => {
            if platform != "windows"
                || !path.starts_with('/')
                || configured
                    .execution_host
                    .name
                    .as_deref()
                    .is_none_or(|name| !valid_profile_id(name))
            {
                return Err(
                    "WSL runtime override requires a distribution and absolute Linux path.".into(),
                );
            }
        }
        _ => return Err("Runtime override host must be native or WSL.".into()),
    }
    Ok(target_for(
        &configured.execution_host,
        path,
        entry,
        None,
        Some("configured-ui"),
    ))
}

pub fn runtime_discovery_settings(
    targets: &[RuntimeTarget],
    overrides: &[ConfiguredRuntimeOverride],
) -> Value {
    let mut adapters = Vec::new();
    let mut seen_adapters = HashSet::new();
    for entry in RUNTIME_CATALOG {
        if seen_adapters.insert(entry.adapter_id) {
            adapters.push(json!({
                "adapterId": entry.adapter_id,
                "displayName": entry.display_name,
                "protocolName": entry.protocol_name,
                "acceptsEndpoint": false,
                "hostKinds": ["native", "wsl"]
            }));
        }
    }
    adapters.push(json!({
        "adapterId": "openclaw-gateway",
        "displayName": "OpenClaw",
        "protocolName": "Direct Gateway",
        "acceptsEndpoint": true,
        "hostKinds": ["remote"]
    }));
    let mut hosts = Vec::new();
    let mut seen_hosts = HashSet::new();
    for target in targets {
        if seen_hosts.insert(target.execution_host.id.clone()) {
            hosts.push(target.execution_host.clone());
        }
    }
    if hosts.is_empty() {
        hosts.push(ExecutionHost {
            id: format!("native:{}", env::consts::OS),
            kind: "native".into(),
            platform: env::consts::OS.into(),
            display_name: match env::consts::OS {
                "windows" => "Windows".into(),
                "macos" => "macOS".into(),
                other => other.into(),
            },
            is_default: true,
            name: None,
        });
    }
    json!({"hosts": hosts, "adapters": adapters, "overrides": overrides})
}

pub fn discover_runtime_targets_with(
    environment: &HashMap<String, String>,
    platform: &str,
) -> Vec<RuntimeTarget> {
    let mut targets = Vec::new();
    let native_host = ExecutionHost {
        id: format!("native:{platform}"),
        kind: "native".into(),
        platform: platform.into(),
        display_name: match platform {
            "windows" => "Windows".into(),
            "macos" => "macOS".into(),
            other => other.into(),
        },
        is_default: platform != "windows",
        name: None,
    };

    for entry in RUNTIME_CATALOG {
        let override_name = format!("ZOMMI_{}_COMMAND", entry.executable.to_ascii_uppercase());
        if let Some(configured) = environment
            .get(&override_name)
            .filter(|value| !value.trim().is_empty())
        {
            targets.push(target_for(
                &native_host,
                configured.trim(),
                entry,
                environment.get("HOME").map(String::as_str),
                Some("configured"),
            ));
        } else if let Some(executable) =
            resolve_native_command(entry.executable, environment, platform)
        {
            targets.push(target_for(
                &native_host,
                &executable.to_string_lossy(),
                entry,
                environment.get("HOME").map(String::as_str),
                None,
            ));
        }
    }

    if let Some(endpoint) = environment
        .get("ZOMMI_OPENCLAW_GATEWAY_URL")
        .filter(|value| !value.trim().is_empty())
        .and_then(|value| validate_gateway_endpoint(value).ok())
    {
        let profile_id = environment
            .get("ZOMMI_OPENCLAW_GATEWAY_AGENT_ID")
            .filter(|value| valid_profile_id(value))
            .map(|value| value.trim().to_owned());
        targets.push(openclaw_gateway_target(endpoint, platform, profile_id));
    }

    if platform == "windows" {
        targets.extend(discover_wsl_targets(environment));
    }
    deduplicate_targets(targets)
}

pub fn select_default_target<'a>(
    targets: &'a [RuntimeTarget],
    bound_target_id: Option<&str>,
    last_selected_target_id: Option<&str>,
) -> Option<&'a RuntimeTarget> {
    for exact in [bound_target_id, last_selected_target_id]
        .into_iter()
        .flatten()
    {
        if let Some(target) = targets
            .iter()
            .find(|target| target.id == exact && target.status == "detected")
        {
            return Some(target);
        }
    }
    let mut usable = targets
        .iter()
        .filter(|target| target.status == "detected")
        .collect::<Vec<_>>();
    usable.sort_by_key(|target| {
        let host_rank = match (
            target.execution_host.kind.as_str(),
            target.execution_host.is_default,
        ) {
            ("wsl", true) => 0,
            ("native", true) => 1,
            ("native", false) => 2,
            _ => 3,
        };
        (host_rank, target.priority, target.id.as_str())
    });
    usable.into_iter().next()
}

pub fn command_for_target(target: &RuntimeTarget) -> RuntimeCommand {
    let launch_args = launch_args(target.adapter_id.as_str());
    if target.execution_host.kind == "wsl" {
        let name = target
            .execution_host
            .name
            .as_deref()
            .expect("WSL targets have a distribution name");
        let mut args = vec!["-d".into(), name.into()];
        if let Some(home) = &target.runtime_home {
            args.extend(["--cd".into(), home.clone()]);
        }
        args.push("-e".into());
        if target.adapter_id == "codex-app-server" {
            args.extend([
                "env".into(),
                "CODEX_INTERNAL_ORIGINATOR_OVERRIDE=codex_exec".into(),
            ]);
        }
        args.push(target.executable_path.clone());
        args.extend(launch_args.iter().map(|value| (*value).into()));
        return RuntimeCommand {
            command: "wsl.exe".into(),
            args,
            working_directory: None,
        };
    }

    if target.execution_host.platform == "windows"
        && matches!(
            Path::new(&target.executable_path)
                .extension()
                .and_then(|extension| extension.to_str())
                .map(str::to_ascii_lowercase)
                .as_deref(),
            Some("cmd" | "bat")
        )
    {
        let mut args = vec![
            "/d".into(),
            "/v:off".into(),
            "/s".into(),
            "/c".into(),
            target.executable_path.clone(),
        ];
        args.extend(launch_args.iter().map(|value| (*value).into()));
        return RuntimeCommand {
            command: "cmd.exe".into(),
            args,
            working_directory: target.runtime_home.clone(),
        };
    }

    RuntimeCommand {
        command: target.executable_path.clone(),
        args: launch_args.iter().map(|value| (*value).into()).collect(),
        working_directory: target.runtime_home.clone(),
    }
}

fn discover_wsl_targets(environment: &HashMap<String, String>) -> Vec<RuntimeTarget> {
    let quiet = run_command("wsl.exe", &["--list", "--quiet"], None);
    let verbose = run_command("wsl.exe", &["--list", "--verbose"], None);
    let (Some(quiet), Some(verbose)) = (quiet, verbose) else {
        return Vec::new();
    };
    let quiet = normalize_command_output(&quiet);
    let verbose = normalize_command_output(&verbose);
    let default_name = verbose.lines().find_map(|line| {
        let trimmed = line.trim_start();
        trimmed
            .strip_prefix('*')
            .and_then(|rest| rest.split_whitespace().next())
            .map(str::to_owned)
    });

    let distributions = quiet
        .lines()
        .map(|line| line.trim().trim_start_matches('*').trim())
        .filter(|line| !line.is_empty())
        .map(str::to_owned)
        .collect::<Vec<_>>();
    std::thread::scope(|scope| {
        distributions
            .iter()
            .map(|distribution| {
                let default_name = default_name.as_deref();
                scope.spawn(move || detect_wsl_runtimes(distribution, default_name, environment))
            })
            .collect::<Vec<_>>()
            .into_iter()
            .filter_map(|probe| probe.join().ok())
            .flatten()
            .collect()
    })
}

fn detect_wsl_runtimes(
    distribution: &str,
    default_name: Option<&str>,
    environment: &HashMap<String, String>,
) -> Vec<RuntimeTarget> {
    let executable_names = RUNTIME_CATALOG
        .iter()
        .map(|entry| format!("'{}'", entry.executable))
        .collect::<Vec<_>>()
        .join(" ");
    let script = format!(
        "{}{}{}{}{}{}{}",
        "zommi_shell=$(getent passwd $(id -un) 2>/dev/null | cut -d: -f7); ",
        "[ -x \"$zommi_shell\" ] || zommi_shell=\"${SHELL:-/bin/sh}\"; ",
        "exec \"$zommi_shell\" -lc '",
        "printf \"__ZOMMI_RUNTIME_HOME__%s\\n\" \"$HOME\"; ",
        "for zommi_command in ",
        executable_names,
        "; do zommi_path=$(command -v -- \"$zommi_command\" 2>/dev/null || true); case \"$zommi_path\" in /*) printf \"__ZOMMI_RUNTIME_PATH__%s\\t%s\\n\" \"$zommi_command\" \"$zommi_path\" ;; esac; done'"
    );
    let output = run_command(
        "wsl.exe",
        &["-d", distribution, "-e", "sh", "-lc", &script],
        Some(environment),
    );
    let Some(output) = output else {
        return Vec::new();
    };
    let output = normalize_command_output(&output);
    let home = output
        .lines()
        .find_map(|line| line.strip_prefix("__ZOMMI_RUNTIME_HOME__"));
    let host = ExecutionHost {
        id: format!("wsl:{}", distribution.to_ascii_lowercase()),
        kind: "wsl".into(),
        platform: "linux".into(),
        display_name: format!("WSL · {distribution}"),
        is_default: default_name.is_some_and(|name| name.eq_ignore_ascii_case(distribution)),
        name: Some(distribution.into()),
    };
    output
        .lines()
        .filter_map(|line| line.strip_prefix("__ZOMMI_RUNTIME_PATH__"))
        .filter_map(|line| line.split_once('\t'))
        .filter(|(_, path)| path.starts_with('/'))
        .flat_map(|(name, path)| {
            RUNTIME_CATALOG
                .iter()
                .filter(|entry| entry.executable == name)
                .map(|entry| target_for(&host, path, entry, home, None))
                .collect::<Vec<_>>()
        })
        .collect()
}

fn run_command(
    executable: &str,
    arguments: &[&str],
    environment: Option<&HashMap<String, String>>,
) -> Option<Vec<u8>> {
    let mut command = Command::new(executable);
    command
        .args(arguments)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    if let Some(environment) = environment {
        command.envs(environment);
    }
    let mut child = command.spawn().ok()?;
    match child.wait_timeout(PROBE_TIMEOUT).ok()? {
        Some(status) if status.success() => {
            let mut output = Vec::new();
            child.stdout.take()?.read_to_end(&mut output).ok()?;
            Some(output)
        }
        Some(_) => None,
        None => {
            let _ = child.kill();
            let _ = child.wait();
            None
        }
    }
}

fn resolve_native_command(
    command: &str,
    environment: &HashMap<String, String>,
    platform: &str,
) -> Option<PathBuf> {
    let path_value = environment
        .iter()
        .find(|(key, _)| key.eq_ignore_ascii_case("PATH"))
        .map(|(_, value)| value.as_str())
        .unwrap_or_default();
    let separator = if platform == "windows" { ';' } else { ':' };
    let mut directories = path_value
        .split(separator)
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .collect::<Vec<_>>();
    if platform == "windows" {
        for candidate in [
            environment
                .get("APPDATA")
                .map(|path| format!("{path}\\npm")),
            environment
                .get("LOCALAPPDATA")
                .map(|path| format!("{path}\\Microsoft\\WinGet\\Links")),
            environment
                .get("USERPROFILE")
                .map(|path| format!("{path}\\.local\\bin")),
        ]
        .into_iter()
        .flatten()
        {
            directories.push(PathBuf::from(candidate));
        }
    }
    let extensions = if platform == "windows" {
        environment
            .iter()
            .find(|(key, _)| key.eq_ignore_ascii_case("PATHEXT"))
            .map(|(_, value)| value.as_str())
            .unwrap_or(".EXE;.CMD;.BAT")
            .split(';')
            .map(str::to_ascii_lowercase)
            .collect::<Vec<_>>()
    } else {
        vec![String::new()]
    };
    for directory in directories {
        for extension in &extensions {
            let candidate = directory.join(format!("{command}{extension}"));
            if fs::metadata(&candidate).is_ok_and(|metadata| metadata.is_file()) {
                return Some(candidate);
            }
            if platform == "windows" {
                let upper = directory.join(format!("{command}{}", extension.to_ascii_uppercase()));
                if fs::metadata(&upper).is_ok_and(|metadata| metadata.is_file()) {
                    return Some(upper);
                }
            }
        }
    }
    None
}

fn target_for(
    host: &ExecutionHost,
    executable_path: &str,
    entry: &CatalogEntry,
    runtime_home: Option<&str>,
    source: Option<&str>,
) -> RuntimeTarget {
    let identity = format!(
        "{}\0{}\0{executable_path}\0default",
        host.id, entry.adapter_id
    );
    let hash = format!("{:x}", Sha256::digest(identity.as_bytes()));
    RuntimeTarget {
        id: format!("runtime-{}", &hash[..20]),
        runtime_id: entry.runtime_id.into(),
        adapter_id: entry.adapter_id.into(),
        display_name: entry.display_name.into(),
        protocol_name: entry.protocol_name.into(),
        executable_path: executable_path.into(),
        execution_host: host.clone(),
        status: "detected".into(),
        priority: entry.priority,
        capability_hints: entry
            .capability_hints
            .iter()
            .map(|value| (*value).into())
            .collect(),
        runtime_home: runtime_home
            .filter(|value| !value.is_empty())
            .map(str::to_owned),
        source: source.map(str::to_owned),
        endpoint: None,
        profile_id: None,
    }
}

fn openclaw_gateway_target(
    endpoint: String,
    platform: &str,
    profile_id: Option<String>,
) -> RuntimeTarget {
    let identity = format!("{endpoint}\0{}", profile_id.as_deref().unwrap_or("default"));
    let hash = format!("{:x}", Sha256::digest(identity.as_bytes()));
    RuntimeTarget {
        id: format!("runtime-openclaw-gateway-{}", &hash[..20]),
        runtime_id: "openclaw".into(),
        adapter_id: "openclaw-gateway".into(),
        display_name: "OpenClaw".into(),
        protocol_name: "Direct Gateway".into(),
        executable_path: String::new(),
        execution_host: ExecutionHost {
            id: format!("remote:{platform}"),
            kind: "remote".into(),
            platform: platform.into(),
            display_name: "Remote Gateway".into(),
            is_default: false,
            name: None,
        },
        status: "detected".into(),
        priority: 41,
        capability_hints: OPENCLAW_GATEWAY_CAPABILITY_HINTS
            .iter()
            .map(|value| (*value).into())
            .collect(),
        runtime_home: None,
        source: Some("configured".into()),
        endpoint: Some(endpoint),
        profile_id,
    }
}

fn valid_profile_id(value: &str) -> bool {
    let value = value.trim();
    !value.is_empty()
        && value.len() <= 256
        && !value
            .chars()
            .any(|character| matches!(character, '\u{0000}'..='\u{001f}' | '\u{007f}'))
}

fn validate_gateway_endpoint(value: &str) -> Result<String, ()> {
    let endpoint = url::Url::parse(value.trim()).map_err(|_| ())?;
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
        return Err(());
    }
    Ok(endpoint.to_string())
}

fn launch_args(adapter_id: &str) -> &'static [&'static str] {
    match adapter_id {
        "codex-app-server" => &["app-server"],
        "pi-rpc" => &["--mode", "rpc"],
        "hermes-acp" | "openclaw-acp" => &["acp"],
        "hermes-gateway" => &[
            "serve",
            "--port",
            "0",
            "--host",
            "127.0.0.1",
            "--skip-build",
            "--isolated",
        ],
        "pty-compatibility" => &[],
        _ => &[],
    }
}

fn deduplicate_targets(targets: Vec<RuntimeTarget>) -> Vec<RuntimeTarget> {
    let mut seen = HashSet::new();
    targets
        .into_iter()
        .filter(|target| seen.insert(target.id.clone()))
        .collect()
}

fn normalize_command_output(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes).replace('\0', "")
}

#[cfg(test)]
mod tests {
    use std::{collections::HashMap, fs};

    use super::{
        ConfiguredRuntimeOverride, ExecutionHost, RuntimeOverrideStore, RuntimeTarget,
        command_for_target, discover_runtime_targets_with, runtime_discovery_settings,
        select_default_target, target_from_override,
    };

    #[test]
    fn discovery_produces_a_stable_native_codex_target() {
        let root = std::env::temp_dir().join(format!("zommi-discovery-{}", std::process::id()));
        fs::create_dir_all(&root).expect("create fixture directory");
        let executable = root.join("codex");
        fs::write(&executable, "fixture").expect("write fixture");
        let environment = HashMap::from([
            ("PATH".into(), root.to_string_lossy().into_owned()),
            ("HOME".into(), "/home/test".into()),
        ]);
        let first = discover_runtime_targets_with(&environment, "linux");
        let second = discover_runtime_targets_with(&environment, "linux");
        assert_eq!(first, second);
        assert_eq!(first.len(), 1);
        assert_eq!(first[0].adapter_id, "codex-app-server");
        assert_eq!(first[0].execution_host.id, "native:linux");
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn selection_preserves_an_exact_binding() {
        let target = |id: &str, is_default: bool| RuntimeTarget {
            id: id.into(),
            runtime_id: "codex".into(),
            adapter_id: "codex-app-server".into(),
            display_name: "Codex".into(),
            protocol_name: "Codex app-server".into(),
            executable_path: "/bin/codex".into(),
            execution_host: ExecutionHost {
                id: format!("host:{id}"),
                kind: "native".into(),
                platform: "linux".into(),
                display_name: "Linux".into(),
                is_default,
                name: None,
            },
            status: "detected".into(),
            priority: 10,
            capability_hints: Vec::new(),
            runtime_home: None,
            source: None,
            endpoint: None,
            profile_id: None,
        };
        let targets = vec![target("default", true), target("bound", false)];
        assert_eq!(
            select_default_target(&targets, Some("bound"), Some("default")).map(|value| &value.id),
            Some(&"bound".to_owned())
        );
    }

    #[test]
    fn wsl_launch_injects_originator_inside_linux() {
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
        let command = command_for_target(&target);
        assert_eq!(command.command, "wsl.exe");
        assert_eq!(
            command.args,
            [
                "-d",
                "Ubuntu",
                "--cd",
                "/home/u",
                "-e",
                "env",
                "CODEX_INTERNAL_ORIGINATOR_OVERRIDE=codex_exec",
                "/home/u/bin/codex",
                "app-server"
            ]
        );
    }

    #[test]
    fn discovers_credential_free_openclaw_gateway_endpoint() {
        let environment = HashMap::from([
            (
                "ZOMMI_OPENCLAW_GATEWAY_URL".into(),
                "wss://gateway.example.test/control".into(),
            ),
            ("ZOMMI_OPENCLAW_GATEWAY_AGENT_ID".into(), "main".into()),
        ]);
        let targets = discover_runtime_targets_with(&environment, "linux");
        let target = targets
            .iter()
            .find(|target| target.adapter_id == "openclaw-gateway")
            .expect("configured Gateway target");
        assert_eq!(
            target.endpoint.as_deref(),
            Some("wss://gateway.example.test/control")
        );
        assert_eq!(target.execution_host.kind, "remote");
        assert_eq!(target.source.as_deref(), Some("configured"));
        assert_eq!(target.profile_id.as_deref(), Some("main"));

        let changed_profile = HashMap::from([
            (
                "ZOMMI_OPENCLAW_GATEWAY_URL".into(),
                "wss://gateway.example.test/control".into(),
            ),
            ("ZOMMI_OPENCLAW_GATEWAY_AGENT_ID".into(), "secondary".into()),
        ]);
        let changed = discover_runtime_targets_with(&changed_profile, "linux")
            .into_iter()
            .find(|target| target.adapter_id == "openclaw-gateway")
            .expect("second configured target");
        assert_ne!(target.id, changed.id);

        let rejected = HashMap::from([(
            "ZOMMI_OPENCLAW_GATEWAY_URL".into(),
            "wss://gateway.example.test/?token=private".into(),
        )]);
        assert!(
            discover_runtime_targets_with(&rejected, "linux")
                .iter()
                .all(|target| target.adapter_id != "openclaw-gateway")
        );
    }

    #[test]
    fn validates_and_persists_credential_free_runtime_overrides() {
        let root = std::env::temp_dir().join(format!(
            "zommi-runtime-overrides-{}-{}",
            std::process::id(),
            uuid::Uuid::new_v4()
        ));
        let store = RuntimeOverrideStore::at(root.join("runtime-overrides.json"));
        let configured = ConfiguredRuntimeOverride {
            id: "override-codex".into(),
            adapter_id: "codex-app-server".into(),
            execution_host: ExecutionHost {
                id: "native:linux".into(),
                kind: "native".into(),
                platform: "linux".into(),
                display_name: "Linux".into(),
                is_default: true,
                name: None,
            },
            executable_path: Some("/opt/codex/bin/codex".into()),
            endpoint: None,
            profile_id: None,
        };
        let target = target_from_override(&configured, "linux").expect("valid override");
        assert_eq!(target.source.as_deref(), Some("configured-ui"));
        store
            .save(std::slice::from_ref(&configured))
            .expect("save override");
        assert_eq!(
            store.load().expect("load override"),
            vec![configured.clone()]
        );

        let settings = runtime_discovery_settings(&[target], &[configured]);
        assert!(
            settings["adapters"]
                .as_array()
                .is_some_and(|items| !items.is_empty())
        );
        assert_eq!(settings["overrides"][0]["id"], "override-codex");
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn rejects_credentials_and_mismatched_override_hosts() {
        let gateway = ConfiguredRuntimeOverride {
            id: "gateway".into(),
            adapter_id: "openclaw-gateway".into(),
            execution_host: ExecutionHost {
                id: "remote:linux".into(),
                kind: "remote".into(),
                platform: "linux".into(),
                display_name: "Remote".into(),
                is_default: false,
                name: None,
            },
            executable_path: None,
            endpoint: Some("wss://gateway.example/?token=secret".into()),
            profile_id: None,
        };
        assert!(target_from_override(&gateway, "linux").is_err());

        let native = ConfiguredRuntimeOverride {
            id: "native".into(),
            adapter_id: "pi-rpc".into(),
            execution_host: ExecutionHost {
                id: "native:windows".into(),
                kind: "native".into(),
                platform: "windows".into(),
                display_name: "Windows".into(),
                is_default: true,
                name: None,
            },
            executable_path: Some("relative/pi".into()),
            endpoint: None,
            profile_id: None,
        };
        assert!(target_from_override(&native, "linux").is_err());
    }
}
