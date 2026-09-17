use std::{
    collections::{HashMap, HashSet},
    env, fs,
    io::{self, Read},
    path::{Path, PathBuf},
    process::{Command, Stdio},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use wait_timeout::ChildExt;

const PROBE_TIMEOUT: Duration = Duration::from_secs(4);
const DISCOVERY_CACHE_SCHEMA_VERSION: u32 = 1;

const CODEX_CAPABILITY_HINTS: &[&str] = &[
    "session.list.v1",
    "session.create.v1",
    "session.resume.v1",
    "session.fork.v1",
    "session.rewind.v1",
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

#[derive(Debug, Clone)]
pub struct RuntimeDiscoveryCacheStore {
    path: PathBuf,
}

#[derive(Debug, Clone)]
pub struct RuntimeDiscoveryOutcome {
    pub targets: Vec<RuntimeTarget>,
    pub wsl_probe_succeeded: bool,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RuntimeDiscoveryCacheFile {
    schema_version: u32,
    detected_at_ms: u64,
    targets: Vec<RuntimeTarget>,
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

impl RuntimeDiscoveryCacheStore {
    pub fn platform_default() -> Self {
        if let Some(path) = env::var_os("ZOMMI_RUNTIME_DISCOVERY_CACHE_PATH") {
            return Self { path: path.into() };
        }
        let path = if cfg!(target_os = "windows") {
            env::var_os("LOCALAPPDATA")
                .map(PathBuf::from)
                .unwrap_or_else(env::temp_dir)
                .join("Zommi")
                .join("runtime-targets.json")
        } else if cfg!(target_os = "macos") {
            env::var_os("HOME")
                .map(PathBuf::from)
                .unwrap_or_else(env::temp_dir)
                .join("Library")
                .join("Application Support")
                .join("Zommi")
                .join("runtime-targets.json")
        } else {
            env::var_os("XDG_CACHE_HOME")
                .map(PathBuf::from)
                .or_else(|| env::var_os("HOME").map(|home| PathBuf::from(home).join(".cache")))
                .unwrap_or_else(env::temp_dir)
                .join("zommi")
                .join("runtime-targets.json")
        };
        Self { path }
    }

    pub fn at(path: PathBuf) -> Self {
        Self { path }
    }

    pub fn load(&self) -> io::Result<Vec<RuntimeTarget>> {
        let bytes = match fs::read(&self.path) {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
            Err(error) => return Err(error),
        };
        let cache: RuntimeDiscoveryCacheFile = serde_json::from_slice(&bytes)
            .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
        if cache.schema_version != DISCOVERY_CACHE_SCHEMA_VERSION {
            return Ok(Vec::new());
        }
        Ok(cache
            .targets
            .into_iter()
            .filter(valid_cached_wsl_target)
            .map(|mut target| {
                target.source = Some("last-known-good".into());
                target.status = "detected".into();
                target
            })
            .collect())
    }

    pub fn save(&self, targets: &[RuntimeTarget]) -> io::Result<()> {
        let targets = targets
            .iter()
            .filter(|target| valid_cached_wsl_target(target))
            .cloned()
            .collect::<Vec<_>>();
        if let Some(parent) = self.path.parent() {
            fs::create_dir_all(parent)?;
        }
        let detected_at_ms = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis()
            .try_into()
            .unwrap_or(u64::MAX);
        let bytes = serde_json::to_vec_pretty(&RuntimeDiscoveryCacheFile {
            schema_version: DISCOVERY_CACHE_SCHEMA_VERSION,
            detected_at_ms,
            targets,
        })
        .map_err(io::Error::other)?;
        let temporary = self
            .path
            .with_extension(format!("{}.tmp", uuid::Uuid::new_v4().simple()));
        fs::write(&temporary, bytes)?;
        #[cfg(target_os = "windows")]
        if self.path.exists() {
            fs::remove_file(&self.path)?;
        }
        fs::rename(temporary, &self.path)
    }
}

fn valid_cached_wsl_target(target: &RuntimeTarget) -> bool {
    target.execution_host.kind == "wsl"
        && target.execution_host.platform == "linux"
        && target
            .execution_host
            .name
            .as_deref()
            .is_some_and(valid_profile_id)
        && target.executable_path.starts_with('/')
        && !target.executable_path.contains('\0')
        && target.endpoint.is_none()
        && RUNTIME_CATALOG
            .iter()
            .any(|entry| entry.adapter_id == target.adapter_id)
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

pub fn discover_runtime_targets_resilient_with_overrides(
    overrides: &[ConfiguredRuntimeOverride],
    cache: &RuntimeDiscoveryCacheStore,
    probe_wsl: bool,
) -> RuntimeDiscoveryOutcome {
    discover_runtime_targets_resilient_with(
        &env::vars().collect(),
        env::consts::OS,
        overrides,
        cache,
        probe_wsl,
    )
}

fn discover_runtime_targets_resilient_with(
    environment: &HashMap<String, String>,
    platform: &str,
    overrides: &[ConfiguredRuntimeOverride],
    cache: &RuntimeDiscoveryCacheStore,
    probe_wsl: bool,
) -> RuntimeDiscoveryOutcome {
    let (mut targets, wsl_probe_succeeded) =
        discover_runtime_targets_with_status(environment, platform, probe_wsl);
    if platform == "windows" {
        if wsl_probe_succeeded {
            let wsl_targets = targets
                .iter()
                .filter(|target| target.execution_host.kind == "wsl")
                .cloned()
                .collect::<Vec<_>>();
            let _ = cache.save(&wsl_targets);
        } else if let Ok(cached) = cache.load() {
            targets.extend(cached);
        }
    }
    targets.extend(
        overrides
            .iter()
            .filter_map(|configured| target_from_override(configured, platform).ok()),
    );
    RuntimeDiscoveryOutcome {
        targets: deduplicate_targets(targets),
        wsl_probe_succeeded,
    }
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
            if !runtime_supported_on_host(entry, &configured.execution_host) {
                return Err(
                    "Native Windows terminal compatibility requires a ConPTY backend.".into(),
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
            let host_kinds =
                if cfg!(target_os = "windows") && entry.adapter_id == "pty-compatibility" {
                    vec!["wsl"]
                } else {
                    vec!["native", "wsl"]
                };
            adapters.push(json!({
                "adapterId": entry.adapter_id,
                "displayName": entry.display_name,
                "protocolName": entry.protocol_name,
                "acceptsEndpoint": false,
                "hostKinds": host_kinds
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
    discover_runtime_targets_with_status(environment, platform, true).0
}

fn discover_runtime_targets_with_status(
    environment: &HashMap<String, String>,
    platform: &str,
    probe_wsl: bool,
) -> (Vec<RuntimeTarget>, bool) {
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
        if !runtime_supported_on_host(entry, &native_host) {
            continue;
        }
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

    let mut wsl_probe_succeeded = platform != "windows";
    if platform == "windows" && probe_wsl {
        let outcome = discover_wsl_targets(environment);
        targets.extend(outcome.targets);
        wsl_probe_succeeded = outcome.succeeded;
    }
    (deduplicate_targets(targets), wsl_probe_succeeded)
}

fn runtime_supported_on_host(entry: &CatalogEntry, host: &ExecutionHost) -> bool {
    !(entry.adapter_id == "pty-compatibility" && host.platform == "windows")
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

/// parent application injects hook routing metadata into terminals it owns. Zommi may reuse
/// the user's Codex home for authentication and canonical history, but a
/// runtime child must never impersonate the parent application pane that launched it.
pub const PARENT_APP_RUNTIME_ENVIRONMENT_KEYS: &[&str] = &[
    "PARENT_APP_AGENT_HOOK_ENDPOINT",
    "PARENT_APP_AGENT_HOOK_ENV",
    "PARENT_APP_AGENT_HOOK_PORT",
    "PARENT_APP_AGENT_HOOK_TOKEN",
    "PARENT_APP_AGENT_HOOK_TRANSPORT",
    "PARENT_APP_AGENT_HOOK_VERSION",
    "PARENT_APP_AGENT_LAUNCH_TOKEN",
    "PARENT_APP_CLI_COMMAND",
    "PARENT_APP_CODEX_HOME",
    "PARENT_APP_CODEX_LAUNCH_PREFLIGHT",
    "PARENT_APP_ORCHESTRATION_COMPATIBILITY_HOST_ID",
    "PARENT_APP_ORCHESTRATION_COMPATIBILITY_HOST_INCARNATION",
    "PARENT_APP_ORCHESTRATION_COMPATIBILITY_HOST_KIND",
    "PARENT_APP_PANE_KEY",
    "PARENT_APP_SHELL_READY_ROOT",
    "PARENT_APP_TAB_ID",
    "PARENT_APP_TERMINAL_HANDLE",
    "PARENT_APP_USER_DATA_PATH",
    "PARENT_APP_WORKTREE_ID",
];

/// GUI-launched Windows processes do not always inherit a PATH that Rust can
/// use for Win32 executable lookup. Prefer the stable System32 location and
/// retain the command-name fallback for tests and non-Windows hosts.
pub fn windows_wsl_executable() -> String {
    for variable in ["SystemRoot", "WINDIR"] {
        if let Some(root) = env::vars_os().find_map(|(key, value)| {
            key.to_string_lossy()
                .eq_ignore_ascii_case(variable)
                .then_some(value)
        }) {
            let candidate = PathBuf::from(root).join("System32").join("wsl.exe");
            if candidate.is_file() {
                return candidate.to_string_lossy().into_owned();
            }
        }
    }
    let default = PathBuf::from(r"C:\Windows\System32\wsl.exe");
    if default.is_file() {
        return default.to_string_lossy().into_owned();
    }
    "wsl.exe".into()
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
        args.extend(["-e".into(), "/usr/bin/env".into()]);
        for variable in PARENT_APP_RUNTIME_ENVIRONMENT_KEYS {
            args.extend(["-u".into(), (*variable).into()]);
        }
        args.push("ZOMMI_RUNTIME_CHILD=1".into());
        if target.adapter_id == "codex-app-server" {
            args.push("CODEX_INTERNAL_ORIGINATOR_OVERRIDE=codex_exec".into());
        }
        args.push(target.executable_path.clone());
        args.extend(launch_args.iter().map(|value| (*value).into()));
        return RuntimeCommand {
            command: windows_wsl_executable(),
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

struct WslDiscoveryOutcome {
    targets: Vec<RuntimeTarget>,
    succeeded: bool,
}

fn discover_wsl_targets(environment: &HashMap<String, String>) -> WslDiscoveryOutcome {
    let wsl = windows_wsl_executable();
    let (quiet, verbose) = std::thread::scope(|scope| {
        let quiet = scope.spawn(|| run_command(&wsl, &["--list", "--quiet"], None));
        let verbose = scope.spawn(|| run_command(&wsl, &["--list", "--verbose"], None));
        (quiet.join().ok().flatten(), verbose.join().ok().flatten())
    });
    let (Some(quiet), Some(verbose)) = (quiet, verbose) else {
        return WslDiscoveryOutcome {
            targets: Vec::new(),
            succeeded: false,
        };
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
    let probes = std::thread::scope(|scope| {
        distributions
            .iter()
            .map(|distribution| {
                let default_name = default_name.as_deref();
                scope.spawn(move || detect_wsl_runtimes(distribution, default_name, environment))
            })
            .collect::<Vec<_>>()
            .into_iter()
            .map(|probe| probe.join().ok().flatten())
            .collect::<Vec<_>>()
    });
    let succeeded = probes.iter().all(Option::is_some);
    WslDiscoveryOutcome {
        targets: probes.into_iter().flatten().flatten().collect(),
        succeeded,
    }
}

fn detect_wsl_runtimes(
    distribution: &str,
    default_name: Option<&str>,
    environment: &HashMap<String, String>,
) -> Option<Vec<RuntimeTarget>> {
    let script = wsl_runtime_probe_script();
    let wsl = windows_wsl_executable();
    let output = run_command(
        &wsl,
        &["-d", distribution, "-e", "sh", "-lc", &script],
        Some(environment),
    );
    output.map(|output| {
        runtime_targets_from_wsl_probe(
            distribution,
            default_name.is_some_and(|name| name.eq_ignore_ascii_case(distribution)),
            &output,
        )
    })
}

/// Produces the shell command used by both the direct WSL probe and the
/// persistent authenticated relay. Keeping one probe format prevents the
/// relay fallback from silently discovering a different runtime catalog.
pub fn wsl_runtime_probe_script() -> String {
    let executable_names = RUNTIME_CATALOG
        .iter()
        .map(|entry| format!("'{}'", entry.executable))
        .collect::<Vec<_>>()
        .join(" ");
    format!(
        "{}{}{}{}{}{}{}",
        "zommi_shell=$(getent passwd $(id -un) 2>/dev/null | cut -d: -f7); ",
        "[ -x \"$zommi_shell\" ] || zommi_shell=\"${SHELL:-/bin/sh}\"; ",
        "exec \"$zommi_shell\" -lc '",
        "printf \"__ZOMMI_RUNTIME_HOME__%s\\n\" \"$HOME\"; ",
        "for zommi_command in ",
        executable_names,
        "; do zommi_path=$(command -v -- \"$zommi_command\" 2>/dev/null || true); case \"$zommi_path\" in /*) printf \"__ZOMMI_RUNTIME_PATH__%s\\t%s\\n\" \"$zommi_command\" \"$zommi_path\" ;; esac; done'"
    )
}

/// Parses the stable probe protocol into all runtime targets exposed by one
/// WSL distribution. This is intentionally public so the Windows host can
/// reuse it after executing the probe through the persistent spool relay.
pub fn runtime_targets_from_wsl_probe(
    distribution: &str,
    is_default: bool,
    output: &[u8],
) -> Vec<RuntimeTarget> {
    let output = normalize_command_output(output);
    let home = output
        .lines()
        .find_map(|line| line.strip_prefix("__ZOMMI_RUNTIME_HOME__"));
    let host = ExecutionHost {
        id: format!("wsl:{}", distribution.to_ascii_lowercase()),
        kind: "wsl".into(),
        platform: "linux".into(),
        display_name: format!("WSL · {distribution}"),
        is_default,
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
        ConfiguredRuntimeOverride, ExecutionHost, PARENT_APP_RUNTIME_ENVIRONMENT_KEYS,
        RuntimeDiscoveryCacheStore, RuntimeOverrideStore, RuntimeTarget, command_for_target,
        discover_runtime_targets_resilient_with, discover_runtime_targets_with,
        runtime_discovery_settings, runtime_targets_from_wsl_probe, select_default_target,
        target_from_override, wsl_runtime_probe_script,
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
    fn shared_wsl_probe_restores_every_detected_runtime() {
        let script = wsl_runtime_probe_script();
        for executable in ["codex", "pi", "hermes", "openclaw", "claude"] {
            assert!(script.contains(&format!("'{executable}'")));
        }
        let targets = runtime_targets_from_wsl_probe(
            "Ubuntu",
            true,
            b"__ZOMMI_RUNTIME_HOME__/home/u\n\
              __ZOMMI_RUNTIME_PATH__codex\t/home/u/.local/bin/codex\n\
              __ZOMMI_RUNTIME_PATH__pi\t/home/u/.local/bin/pi\n\
              __ZOMMI_RUNTIME_PATH__hermes\t/home/u/.local/bin/hermes\n\
              __ZOMMI_RUNTIME_PATH__openclaw\t/home/u/.local/bin/openclaw\n\
              __ZOMMI_RUNTIME_PATH__claude\t/home/u/.local/bin/claude\n",
        );
        assert_eq!(targets.len(), 6, "Hermes exposes ACP and Gateway targets");
        let adapters = targets
            .iter()
            .map(|target| target.adapter_id.as_str())
            .collect::<std::collections::HashSet<_>>();
        for adapter in [
            "codex-app-server",
            "pi-rpc",
            "hermes-acp",
            "hermes-gateway",
            "openclaw-acp",
            "pty-compatibility",
        ] {
            assert!(adapters.contains(adapter), "missing {adapter}");
        }
        assert!(targets.iter().all(|target| {
            target.execution_host.is_default
                && target.execution_host.name.as_deref() == Some("Ubuntu")
                && target.runtime_home.as_deref() == Some("/home/u")
        }));
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
        let expected = ["-d", "Ubuntu", "--cd", "/home/u", "-e", "/usr/bin/env"]
            .into_iter()
            .map(str::to_owned)
            .chain(
                PARENT_APP_RUNTIME_ENVIRONMENT_KEYS
                    .iter()
                    .flat_map(|variable| ["-u".to_owned(), (*variable).to_owned()]),
            )
            .chain([
                "ZOMMI_RUNTIME_CHILD=1".into(),
                "CODEX_INTERNAL_ORIGINATOR_OVERRIDE=codex_exec".into(),
                "/home/u/bin/codex".into(),
                "app-server".into(),
            ])
            .collect::<Vec<_>>();
        assert_eq!(command.args, expected);
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

    #[test]
    fn last_known_good_wsl_target_survives_a_failed_probe() {
        let root = std::env::temp_dir().join(format!(
            "zommi-runtime-cache-{}-{}",
            std::process::id(),
            uuid::Uuid::new_v4()
        ));
        let store = RuntimeDiscoveryCacheStore::at(root.join("runtime-targets.json"));
        let cached = RuntimeTarget {
            id: "cached-codex".into(),
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
        store
            .save(std::slice::from_ref(&cached))
            .expect("save cache");

        let outcome = discover_runtime_targets_resilient_with(
            &HashMap::from([("PATH".into(), String::new())]),
            "windows",
            &[],
            &store,
            false,
        );

        assert!(!outcome.wsl_probe_succeeded);
        assert_eq!(outcome.targets.len(), 1);
        assert_eq!(outcome.targets[0].id, cached.id);
        assert_eq!(
            outcome.targets[0].source.as_deref(),
            Some("last-known-good")
        );
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn native_windows_terminal_targets_are_never_discovered_or_configured() {
        let root = std::env::temp_dir().join(format!(
            "zommi-native-pty-{}-{}",
            std::process::id(),
            uuid::Uuid::new_v4()
        ));
        fs::create_dir_all(&root).expect("create native fixture");
        fs::write(root.join("claude.exe"), "fixture").expect("write native fixture");
        let environment = HashMap::from([
            ("PATH".into(), root.to_string_lossy().into_owned()),
            ("PATHEXT".into(), ".EXE".into()),
        ]);
        assert!(
            discover_runtime_targets_resilient_with(
                &environment,
                "windows",
                &[],
                &RuntimeDiscoveryCacheStore::at(root.join("cache.json")),
                false,
            )
            .targets
            .iter()
            .all(|target| target.adapter_id != "pty-compatibility")
        );
        let configured = ConfiguredRuntimeOverride {
            id: "native-claude".into(),
            adapter_id: "pty-compatibility".into(),
            execution_host: ExecutionHost {
                id: "native:windows".into(),
                kind: "native".into(),
                platform: "windows".into(),
                display_name: "Windows".into(),
                is_default: true,
                name: None,
            },
            executable_path: Some(root.join("claude.exe").to_string_lossy().into_owned()),
            endpoint: None,
            profile_id: None,
        };
        assert!(target_from_override(&configured, "windows").is_err());
        let _ = fs::remove_dir_all(root);
    }
}
