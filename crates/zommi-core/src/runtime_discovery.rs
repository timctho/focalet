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

// Native PATH probes are fast; waking a stopped WSL distribution is not.
const WSL_PROBE_TIMEOUT: Duration = Duration::from_secs(25);
const DISCOVERY_CACHE_SCHEMA_VERSION: u32 = 1;

const CODEX_CAPABILITY_HINTS: &[&str] = &[
    "approval.resolve.v1",
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
        executable: "opencode",
        runtime_id: "opencode",
        adapter_id: "opencode-acp",
        display_name: "OpenCode",
        protocol_name: "ACP",
        priority: 25,
        capability_hints: ACP_CAPABILITY_HINTS,
    },
    CatalogEntry {
        executable: "gemini",
        runtime_id: "gemini",
        adapter_id: "gemini-acp",
        display_name: "Gemini CLI",
        protocol_name: "ACP",
        priority: 26,
        capability_hints: ACP_CAPABILITY_HINTS,
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
        adapter_id: "claude-stream-json",
        display_name: "Claude Code",
        protocol_name: "Stream JSON",
        priority: 27,
        capability_hints: crate::claude_adapter::CAPABILITIES,
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
    // Keep interpreter lookup consistent with the shell that resolved the CLI.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub launch_path: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub endpoint: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub profile_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RuntimeCommand {
    pub full_access: bool,
    pub command: String,
    pub args: Vec<String>,
    pub working_directory: Option<String>,
}

impl RuntimeCommand {
    /// Apply only to this child process; never rewrite the user's CLI config.
    /// WSL args must retain the /usr/bin/env invocation, including after relay wrapping.
    pub fn enable_full_access(&mut self, target: &RuntimeTarget) -> io::Result<()> {
        let adapter = target.adapter_id.as_str();
        self.full_access = true;
        let flags: &[&str] = match adapter {
            // Codex shares one app-server between chats. Its native thread
            // APIs apply permissions per chat; process flags would also
            // escalate chats created after Full access is turned off.
            "codex-app-server" => &[],
            "claude-stream-json" => &["--permission-mode", "bypassPermissions"],
            "gemini-acp" => &["--approval-mode", "yolo"],
            // ACP clients grant individual permission requests in full-access
            // mode. Pi has no built-in permission gate; gateways use per-chat approvals.
            _ => &[],
        };
        self.args
            .extend(flags.iter().map(|value| (*value).to_owned()));
        let environment = self.permission_environment(adapter);
        if target.execution_host.kind == "wsl" && !environment.is_empty() {
            let executable = self
                .args
                .iter()
                .position(|argument| argument == &target.executable_path)
                .filter(|index| {
                    self.args[..*index]
                        .iter()
                        .any(|argument| argument == "/usr/bin/env")
                })
                .ok_or_else(|| {
                    io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "WSL full access requires a direct /usr/bin/env runtime invocation.",
                    )
                })?;
            self.args.splice(
                executable..executable,
                environment
                    .iter()
                    .map(|(key, value)| format!("{key}={value}")),
            );
        }
        Ok(())
    }

    pub(crate) fn permission_environment(
        &self,
        adapter: &str,
    ) -> &'static [(&'static str, &'static str)] {
        if !self.full_access {
            return &[];
        }
        match adapter {
            "opencode-acp" => &[("OPENCODE_PERMISSION", "{\"*\":\"allow\"}")],
            "hermes-acp" => &[("HERMES_YOLO_MODE", "1")],
            _ => &[],
        }
    }
}

impl RuntimeTarget {
    pub(crate) fn apply_launch_environment(&self, command: &mut tokio::process::Command) {
        if self.execution_host.kind == "native"
            && let Some(path) = &self.launch_path
        {
            command.env("PATH", path);
        }
    }
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
    discover_runtime_targets_with(&discovery_environment(), env::consts::OS)
}

fn discovery_environment() -> HashMap<String, String> {
    #[allow(unused_mut)] // Only Unix desktop launchers need the account shell.
    let mut environment: HashMap<_, _> = env::vars().collect();
    #[cfg(unix)]
    if !environment.contains_key("SHELL")
        && let Some(shell) = crate::native_runtime_probe::default_shell()
    {
        environment.insert("SHELL".into(), shell);
    }
    environment
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
        &discovery_environment(),
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
        targets = reconcile_wsl_discovery_cache(targets, wsl_probe_succeeded, cache);
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

fn reconcile_wsl_discovery_cache(
    mut targets: Vec<RuntimeTarget>,
    probe_succeeded: bool,
    cache: &RuntimeDiscoveryCacheStore,
) -> Vec<RuntimeTarget> {
    let found_wsl_target = targets.iter().any(valid_cached_wsl_target);
    if !probe_succeeded && let Ok(cached) = cache.load() {
        targets.extend(cached);
    }
    // A failed secondary distribution must not prevent a working runtime from
    // surviving the next launch. Fresh entries take precedence over the cache.
    let targets = deduplicate_targets(targets);
    if probe_succeeded || found_wsl_target {
        let _ = cache.save(&targets);
    }
    targets
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
        .find(|entry| {
            entry.adapter_id == configured.adapter_id
                || (configured.adapter_id == "pty-compatibility"
                    && entry.adapter_id == "claude-stream-json")
        })
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
    // Manual setup must also work before any native CLI has been detected.
    // WSL-only discovery must not hide the Windows host from the picker.
    if seen_hosts.insert(format!("native:{}", env::consts::OS)) {
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
    // Contract tests and isolated automation must not discover a developer's
    // installed agents or read their WSL catalogs. Explicit runtime commands
    // and credential-free configured overrides still use the real adapters.
    let configured_only = environment
        .get("ZOMMI_RUNTIME_DISCOVERY_MODE")
        .is_some_and(|mode| mode == "configured-only");
    let mut targets = Vec::new();
    let shell_runtimes = if !configured_only && platform == env::consts::OS && platform != "windows"
    {
        let mut names: Vec<_> = RUNTIME_CATALOG
            .iter()
            .map(|entry| entry.executable)
            .collect();
        names.sort_unstable();
        names.dedup();
        crate::native_runtime_probe::discover(environment, &names)
    } else {
        crate::native_runtime_probe::ShellRuntimes::default()
    };
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
        } else if !configured_only
            && let Some(executable) = shell_runtimes
                .executables
                .get(entry.executable)
                .cloned()
                .or_else(|| resolve_native_command(entry.executable, environment, platform))
        {
            let mut target = target_for(
                &native_host,
                &executable.to_string_lossy(),
                entry,
                environment.get("HOME").map(String::as_str),
                shell_runtimes
                    .executables
                    .contains_key(entry.executable)
                    .then_some("login-shell"),
            );
            target.launch_path = shell_runtimes.path.clone();
            targets.push(target);
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

    // An intentionally empty WSL result must not restore cached personal targets.
    let mut wsl_probe_succeeded = platform != "windows" || configured_only;
    if platform == "windows" && probe_wsl && !configured_only {
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

/// Child runtimes keep their own authentication and history, but must not
/// inherit routing or launch identity from a parent desktop application.
/// Recognize the namespace by its context keys, without depending on a host.
pub fn parent_runtime_environment_keys(keys: &[String]) -> Vec<String> {
    const MARKERS: &[&str] = &[
        "_AGENT_HOOK_",
        "_AGENT_LAUNCH_",
        "_ORCHESTRATION_",
        "_PANE_",
        "_SHELL_READY_",
        "_TAB_",
        "_TERMINAL_",
        "_USER_DATA_",
        "_WORKTREE_",
    ];
    const SUFFIXES: &[&str] = &["_CLI_COMMAND", "_CODEX_HOME", "_CODEX_LAUNCH_PREFLIGHT"];
    let namespaces = keys
        .iter()
        .filter_map(|key| {
            let upper = key.to_ascii_uppercase();
            if upper.starts_with("ZOMMI_") {
                return None;
            }
            let prefix = MARKERS
                .iter()
                .filter_map(|marker| upper.find(marker))
                .min()
                .or_else(|| {
                    SUFFIXES
                        .iter()
                        .find_map(|suffix| upper.strip_suffix(suffix).map(str::len))
                })?;
            let namespace = &upper[..prefix];
            (!namespace.is_empty()).then(|| format!("{namespace}_"))
        })
        .collect::<HashSet<_>>();
    let mut removed = keys
        .iter()
        .filter(|key| {
            let upper = key.to_ascii_uppercase();
            namespaces
                .iter()
                .any(|namespace| upper.starts_with(namespace))
        })
        .cloned()
        .collect::<Vec<_>>();
    removed.sort();
    removed
}

pub fn inherited_parent_environment_keys() -> Vec<String> {
    parent_runtime_environment_keys(
        &env::vars_os()
            .filter_map(|(key, _)| key.into_string().ok())
            .collect::<Vec<_>>(),
    )
}

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
        for variable in inherited_parent_environment_keys() {
            args.extend(["-u".into(), variable]);
        }
        args.push("ZOMMI_RUNTIME_CHILD=1".into());
        if target.adapter_id == "codex-app-server" {
            args.push("CODEX_INTERNAL_ORIGINATOR_OVERRIDE=codex_exec".into());
        }
        args.push(target.executable_path.clone());
        args.extend(launch_args.iter().map(|value| (*value).into()));
        return RuntimeCommand {
            full_access: false,
            command: windows_wsl_executable(),
            args,
            working_directory: None,
        };
    }

    // Rust's Windows process API handles .cmd/.bat launchers and quoting.
    // An explicit cmd.exe /c wrapper bypasses that escaping for paths with
    // spaces and shell metacharacters.
    RuntimeCommand {
        full_access: false,
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
        let quiet = scope.spawn(|| run_wsl_probe(&wsl, &["--list", "--quiet"], None));
        let verbose = scope.spawn(|| run_wsl_probe(&wsl, &["--list", "--verbose"], None));
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
    let output = run_wsl_probe(
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

fn run_wsl_probe(
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
    match child.wait_timeout(WSL_PROBE_TIMEOUT).ok()? {
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
        let get = |name: &str| {
            environment
                .iter()
                .find(|(key, _)| key.eq_ignore_ascii_case(name))
                .map(|(_, value)| PathBuf::from(value))
        };
        for (variable, suffix) in [
            ("APPDATA", "npm"),
            ("LOCALAPPDATA", "Microsoft/WinGet/Links"),
            ("LOCALAPPDATA", "Programs/nodejs"),
            ("USERPROFILE", ".local/bin"),
            ("USERPROFILE", ".bun/bin"),
            ("USERPROFILE", ".opencode/bin"),
            ("USERPROFILE", "scoop/shims"),
            ("ProgramFiles", "nodejs"),
            ("NVM_SYMLINK", ""),
        ] {
            if let Some(root) = get(variable) {
                directories.push(root.join(suffix));
            }
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
        launch_path: None,
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
        launch_path: None,
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
        "gemini-acp" => &["--acp"],
        "hermes-acp" | "openclaw-acp" | "opencode-acp" => &["acp"],
        "hermes-gateway" => &[
            "serve",
            "--port",
            "0",
            "--host",
            "127.0.0.1",
            "--skip-build",
            "--isolated",
        ],
        "claude-stream-json" => &[
            "--print",
            "--verbose",
            "--input-format",
            "stream-json",
            "--output-format",
            "stream-json",
            "--include-partial-messages",
            "--permission-prompt-tool",
            "stdio",
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
        ConfiguredRuntimeOverride, ExecutionHost, RuntimeDiscoveryCacheStore, RuntimeOverrideStore,
        RuntimeTarget, command_for_target, discover_runtime_targets_resilient_with,
        discover_runtime_targets_with, inherited_parent_environment_keys,
        parent_runtime_environment_keys, reconcile_wsl_discovery_cache, runtime_discovery_settings,
        runtime_targets_from_wsl_probe, select_default_target, target_from_override,
        wsl_runtime_probe_script,
    };

    #[cfg(unix)]
    #[tokio::test]
    async fn desktop_discovery_uses_shell_path_and_launches_env_interpreters() {
        use std::os::unix::fs::PermissionsExt;
        let root =
            std::env::temp_dir().join(format!("zommi-shell-discovery-{}", uuid::Uuid::new_v4()));
        let bin = root.join("CLI tools ; literal");
        fs::create_dir_all(&bin).unwrap();
        let executable = |path: &std::path::Path, content: &str| {
            fs::write(path, content).unwrap();
            fs::set_permissions(path, fs::Permissions::from_mode(0o755)).unwrap();
        };
        let shell = root.join("bash");
        executable(
            &shell,
            "#!/bin/sh\nprintf 'startup banner\\n'\nexport PATH=\"$FIXTURE_BIN:/usr/bin:/bin\"\nexec /bin/sh -c \"$2\"\n",
        );
        executable(&bin.join("codex"), "#!/usr/bin/env fixture-node\n");
        executable(
            &bin.join("fixture-node"),
            "#!/bin/sh\nprintf 'interpreter-ready\\n'\n",
        );
        let mut environment = HashMap::from([
            ("SHELL".into(), shell.to_string_lossy().into_owned()),
            ("FIXTURE_BIN".into(), bin.to_string_lossy().into_owned()),
            ("HOME".into(), root.to_string_lossy().into_owned()),
            ("PATH".into(), "/usr/bin:/bin".into()),
        ]);
        let targets = discover_runtime_targets_with(&environment, std::env::consts::OS);
        let target = targets
            .iter()
            .find(|target| target.adapter_id == "codex-app-server")
            .unwrap();
        assert_eq!(target.executable_path, bin.join("codex").to_string_lossy());
        assert_eq!(target.source.as_deref(), Some("login-shell"));
        let launch = command_for_target(target);
        let mut command = tokio::process::Command::new(&launch.command);
        command.args(&launch.args).env_clear().envs(&environment);
        target.apply_launch_environment(&mut command);
        let result = command.output().await.unwrap();
        assert!(result.status.success());
        assert_eq!(result.stdout, b"interpreter-ready\n");

        executable(&bin.join("gemini"), "#!/bin/sh\nexit 0\n");
        let refreshed = discover_runtime_targets_with(&environment, std::env::consts::OS);
        assert!(
            refreshed
                .iter()
                .any(|target| target.executable_path == bin.join("gemini").to_string_lossy())
        );
        assert_eq!(
            refreshed.iter().find(|t| t.id == target.id).unwrap().id,
            target.id
        );
        environment.insert(
            "ZOMMI_RUNTIME_DISCOVERY_MODE".into(),
            "configured-only".into(),
        );
        assert!(discover_runtime_targets_with(&environment, std::env::consts::OS).is_empty());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn runtime_children_drop_parent_namespaces_but_keep_agent_configuration() {
        let keys = [
            "DESKTOP_HOST_AGENT_HOOK_ENDPOINT",
            "DESKTOP_HOST_FUTURE_ROUTING_KEY",
            "Editor_Tab_Id",
            "Editor_Secret",
            "SECOND_HOST_CODEX_HOME",
            "SECOND_HOST_PANE_KEY",
            "CODEX_HOME",
            "OPENAI_API_KEY",
            "AWS_SESSION_TOKEN",
            "PATH",
            "HOME",
            "ZOMMI_CODEX_HOME",
            "ZOMMI_FAKE_CODEX_HOME",
            "ZOMMI_FAKE_CODEX_HOME_LOG",
            "ZOMMI_RUNTIME_CHILD",
        ]
        .map(str::to_owned);
        assert_eq!(
            parent_runtime_environment_keys(&keys),
            [
                "DESKTOP_HOST_AGENT_HOOK_ENDPOINT",
                "DESKTOP_HOST_FUTURE_ROUTING_KEY",
                "Editor_Secret",
                "Editor_Tab_Id",
                "SECOND_HOST_CODEX_HOME",
                "SECOND_HOST_PANE_KEY",
            ]
        );
        assert!(
            parent_runtime_environment_keys(&["CODEX_HOME".into(), "API_KEY".into()]).is_empty()
        );
    }

    #[test]
    fn configured_only_discovery_ignores_installed_native_agents() {
        let root = std::env::temp_dir().join(format!("zommi-isolated-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&root).expect("create fixture directory");
        fs::write(root.join("pi"), "personal installation").expect("create installed CLI");
        let environment = HashMap::from([
            ("PATH".into(), root.to_string_lossy().into_owned()),
            ("HOME".into(), root.to_string_lossy().into_owned()),
            ("ZOMMI_CODEX_COMMAND".into(), "/fixtures/python".into()),
            (
                "ZOMMI_RUNTIME_DISCOVERY_MODE".into(),
                "configured-only".into(),
            ),
        ]);
        let targets = discover_runtime_targets_with(&environment, "linux");
        assert_eq!(targets.len(), 1);
        assert_eq!(targets[0].adapter_id, "codex-app-server");
        assert_eq!(targets[0].executable_path, "/fixtures/python");
        assert_eq!(targets[0].source.as_deref(), Some("configured"));
        let _ = fs::remove_dir_all(root);
    }

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
    fn opencode_discovery_launches_native_and_wsl_acp() {
        let environment = HashMap::from([
            (
                "ZOMMI_OPENCODE_COMMAND".into(),
                "/opt/OpenCode bin/opencode".into(),
            ),
            (
                "ZOMMI_RUNTIME_DISCOVERY_MODE".into(),
                "configured-only".into(),
            ),
        ]);
        let targets = discover_runtime_targets_with(&environment, "linux");
        assert_eq!(targets.len(), 1);
        let target = &targets[0];
        assert_eq!(target.runtime_id, "opencode");
        assert_eq!(target.display_name, "OpenCode");
        assert_eq!(command_for_target(target).args, ["acp"]);
        assert_eq!(
            command_for_target(target).command,
            "/opt/OpenCode bin/opencode"
        );
        let wsl = runtime_targets_from_wsl_probe("Ubuntu", true,
            b"__ZOMMI_RUNTIME_HOME__/home/u\n__ZOMMI_RUNTIME_PATH__opencode\t/home/u/.opencode/bin/opencode\n");
        let command = command_for_target(&wsl[0]);
        assert_eq!(
            &command.args[command.args.len() - 2..],
            ["/home/u/.opencode/bin/opencode", "acp"]
        );
        assert!(
            super::runtime_discovery_settings(&targets, &[])["adapters"]
                .as_array()
                .unwrap()
                .iter()
                .any(|adapter| adapter["adapterId"] == "opencode-acp")
        );
    }

    #[test]
    fn gemini_discovery_launches_acp_on_native_and_wsl_hosts() {
        for (platform, executable) in [
            ("linux", "/opt/Gemini CLI/gemini"),
            ("macos", "/opt/homebrew/bin/gemini"),
            (
                "windows",
                r"C:\Users\Test User\AppData\Roaming\npm\gemini.cmd",
            ),
        ] {
            let targets = discover_runtime_targets_with(
                &HashMap::from([
                    ("ZOMMI_GEMINI_COMMAND".into(), executable.into()),
                    (
                        "ZOMMI_RUNTIME_DISCOVERY_MODE".into(),
                        "configured-only".into(),
                    ),
                ]),
                platform,
            );
            assert_eq!(targets.len(), 1);
            let target = &targets[0];
            assert_eq!(target.adapter_id, "gemini-acp");
            assert_eq!(target.display_name, "Gemini CLI");
            assert_eq!(command_for_target(target).command, executable);
            assert_eq!(command_for_target(target).args, ["--acp"]);
            assert!(
                runtime_discovery_settings(&targets, &[])["adapters"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .any(|adapter| adapter["adapterId"] == "gemini-acp")
            );
        }
        let targets = runtime_targets_from_wsl_probe(
            "Ubuntu",
            true,
            b"__ZOMMI_RUNTIME_HOME__/home/u\n__ZOMMI_RUNTIME_PATH__gemini\t/home/u/bin/gemini\n",
        );
        assert_eq!(targets.len(), 1);
        let command = command_for_target(&targets[0]);
        assert_eq!(
            &command.args[command.args.len() - 2..],
            ["/home/u/bin/gemini", "--acp"]
        );
    }

    #[test]
    fn native_windows_discovery_finds_user_installs_without_path_entries() {
        let root = std::env::temp_dir().join(format!("zommi-native-{}", uuid::Uuid::new_v4()));
        let npm = root.join("npm");
        fs::create_dir_all(&npm).unwrap();
        fs::write(npm.join("codex.cmd"), "fixture").unwrap();
        let environment = HashMap::from([
            ("Path".into(), String::new()),
            ("AppData".into(), root.to_string_lossy().into_owned()),
        ]);
        let targets = super::discover_runtime_targets_with_status(&environment, "windows", false).0;
        assert_eq!(targets.len(), 1);
        assert_eq!(targets[0].execution_host.kind, "native");
        assert_eq!(targets[0].execution_host.platform, "windows");
        assert_eq!(
            command_for_target(&targets[0]).command,
            npm.join("codex.cmd").to_string_lossy()
        );
        let _ = fs::remove_dir_all(root);
    }

    #[cfg(windows)]
    #[test]
    fn native_windows_batch_launcher_preserves_paths_and_arguments() {
        let root =
            std::env::temp_dir().join(format!("zommi space & shim {}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&root).unwrap();
        let shim = root.join("codex.cmd");
        fs::write(&shim, "@echo off\r\necho %1\r\n").unwrap();
        let targets = super::discover_runtime_targets_with_status(
            &HashMap::from([("Path".into(), root.to_string_lossy().into_owned())]),
            "windows",
            false,
        )
        .0;
        let launch = command_for_target(&targets[0]);
        let result = std::process::Command::new(launch.command)
            .args(launch.args)
            .output()
            .unwrap();
        assert!(
            result.status.success(),
            "{}",
            String::from_utf8_lossy(&result.stderr)
        );
        assert_eq!(String::from_utf8_lossy(&result.stdout).trim(), "app-server");
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn full_access_environment_stays_inside_the_selected_native_or_wsl_child() {
        let probe = b"__ZOMMI_RUNTIME_HOME__/home/u\n__ZOMMI_RUNTIME_PATH__opencode\t/home/u/bin/opencode\n__ZOMMI_RUNTIME_PATH__hermes\t/home/u/bin/hermes\n";
        for target in runtime_targets_from_wsl_probe("Ubuntu", true, probe)
            .into_iter()
            .filter(|target| matches!(target.adapter_id.as_str(), "opencode-acp" | "hermes-acp"))
        {
            let default = command_for_target(&target);
            assert!(
                default
                    .permission_environment(&target.adapter_id)
                    .is_empty()
            );
            let mut full = default.clone();
            full.enable_full_access(&target).unwrap();
            let key = if target.adapter_id == "opencode-acp" {
                "OPENCODE_PERMISSION={\"*\":\"allow\"}"
            } else {
                "HERMES_YOLO_MODE=1"
            };
            let index = full
                .args
                .iter()
                .position(|value| value == &target.executable_path)
                .unwrap();
            assert_eq!(full.args[index - 1], key);
            assert!(!default.args.contains(&key.to_string()));
            let mut native = target.clone();
            native.execution_host.kind = "native".into();
            let mut full = command_for_target(&native);
            full.enable_full_access(&native).unwrap();
            assert!(!full.permission_environment(&native.adapter_id).is_empty());
            assert_eq!(full.args, vec!["acp"]);
        }
    }

    #[test]
    fn wsl_only_discovery_keeps_native_manual_setup_available() {
        let targets = runtime_targets_from_wsl_probe(
            "Ubuntu",
            true,
            b"__ZOMMI_RUNTIME_HOME__/home/u\n__ZOMMI_RUNTIME_PATH__codex\t/home/u/bin/codex\n",
        );
        let settings = runtime_discovery_settings(&targets, &[]);
        let hosts = settings["hosts"].as_array().unwrap();
        assert_eq!(hosts.len(), 2);
        assert!(hosts.iter().any(|host| host["kind"] == "wsl"));
        assert!(
            hosts
                .iter()
                .any(|host| host["kind"] == "native" && host["platform"] == std::env::consts::OS)
        );
    }

    #[test]
    fn shared_wsl_probe_restores_every_detected_runtime() {
        let script = wsl_runtime_probe_script();
        for executable in [
            "codex", "pi", "opencode", "gemini", "hermes", "openclaw", "claude",
        ] {
            assert!(script.contains(&format!("'{executable}'")));
        }
        let targets = runtime_targets_from_wsl_probe(
            "Ubuntu",
            true,
            b"__ZOMMI_RUNTIME_HOME__/home/u\n\
              __ZOMMI_RUNTIME_PATH__codex\t/home/u/.local/bin/codex\n\
              __ZOMMI_RUNTIME_PATH__pi\t/home/u/.local/bin/pi\n\
              __ZOMMI_RUNTIME_PATH__opencode\t/home/u/.opencode/bin/opencode\n\
              __ZOMMI_RUNTIME_PATH__gemini\t/home/u/bin/gemini\n\
              __ZOMMI_RUNTIME_PATH__hermes\t/home/u/.local/bin/hermes\n\
              __ZOMMI_RUNTIME_PATH__openclaw\t/home/u/.local/bin/openclaw\n\
              __ZOMMI_RUNTIME_PATH__claude\t/home/u/.local/bin/claude\n",
        );
        assert_eq!(targets.len(), 8, "Hermes exposes ACP and Gateway targets");
        let adapters = targets
            .iter()
            .map(|target| target.adapter_id.as_str())
            .collect::<std::collections::HashSet<_>>();
        for adapter in [
            "codex-app-server",
            "pi-rpc",
            "opencode-acp",
            "gemini-acp",
            "hermes-acp",
            "hermes-gateway",
            "openclaw-acp",
            "claude-stream-json",
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
            launch_path: None,
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
            launch_path: None,
            source: None,
            endpoint: None,
            profile_id: None,
        };
        let command = command_for_target(&target);
        assert_eq!(
            std::path::Path::new(&command.command)
                .file_name()
                .and_then(|name| name.to_str()),
            Some("wsl.exe")
        );
        if cfg!(windows) {
            assert!(std::path::Path::new(&command.command).is_absolute());
        }
        let expected = ["-d", "Ubuntu", "--cd", "/home/u", "-e", "/usr/bin/env"]
            .into_iter()
            .map(str::to_owned)
            .chain(
                inherited_parent_environment_keys()
                    .into_iter()
                    .flat_map(|variable| ["-u".to_owned(), variable]),
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
                id: format!("native:{}", std::env::consts::OS),
                kind: "native".into(),
                platform: std::env::consts::OS.into(),
                display_name: "This computer".into(),
                is_default: true,
                name: None,
            },
            executable_path: Some(root.join("codex").to_string_lossy().into_owned()),
            endpoint: None,
            profile_id: None,
        };
        let target =
            target_from_override(&configured, std::env::consts::OS).expect("valid override");
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
    fn partial_wsl_discovery_survives_a_failed_probe_on_next_launch() {
        let root =
            std::env::temp_dir().join(format!("zommi-partial-wsl-cache-{}", uuid::Uuid::new_v4()));
        let path = root.join("runtime-targets.json");
        let store = RuntimeDiscoveryCacheStore::at(path.clone());
        let detected = runtime_targets_from_wsl_probe(
            "Ubuntu",
            true,
            b"__ZOMMI_RUNTIME_HOME__/home/u\n__ZOMMI_RUNTIME_PATH__codex\t/home/u/bin/codex\n",
        );
        assert_eq!(detected.len(), 1);
        let id = detected[0].id.clone();
        let first = reconcile_wsl_discovery_cache(detected, false, &store);
        assert_eq!(first[0].id, id);
        let bytes = fs::read(&path).expect("partial discovery persisted");

        // Reopen the store as another process would, with no successful probe.
        let reopened = RuntimeDiscoveryCacheStore::at(path.clone());
        let next = reconcile_wsl_discovery_cache(Vec::new(), false, &reopened);
        assert_eq!(next.len(), 1);
        assert_eq!(next[0].id, id);
        assert_eq!(next[0].source.as_deref(), Some("last-known-good"));
        assert_eq!(fs::read(&path).unwrap(), bytes);

        // A complete successful scan can still remove an uninstalled runtime.
        assert!(reconcile_wsl_discovery_cache(Vec::new(), true, &reopened).is_empty());
        assert!(reopened.load().unwrap().is_empty());
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn partial_wsl_discovery_merges_fresh_and_cached_distributions() {
        let root =
            std::env::temp_dir().join(format!("zommi-partial-wsl-merge-{}", uuid::Uuid::new_v4()));
        let store = RuntimeDiscoveryCacheStore::at(root.join("runtime-targets.json"));
        let probe = b"__ZOMMI_RUNTIME_PATH__codex\t/home/u/bin/codex\n";
        let mut cached = runtime_targets_from_wsl_probe("Ubuntu", true, probe);
        cached.extend(runtime_targets_from_wsl_probe("Debian", false, probe));
        store.save(&cached).unwrap();

        let mut fresh = runtime_targets_from_wsl_probe("Ubuntu", true, probe);
        fresh[0].display_name = "Updated Codex".into();
        let merged = reconcile_wsl_discovery_cache(fresh, false, &store);
        assert_eq!(merged.len(), 2);
        assert_eq!(merged[0].display_name, "Updated Codex");
        assert_ne!(merged[0].source.as_deref(), Some("last-known-good"));
        assert_eq!(merged[1].execution_host.name.as_deref(), Some("Debian"));
        assert_eq!(merged[1].source.as_deref(), Some("last-known-good"));
        let persisted = store.load().unwrap();
        assert_eq!(persisted.len(), 2);
        assert_eq!(persisted[0].display_name, "Updated Codex");
        let _ = fs::remove_dir_all(root);
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
            launch_path: None,
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
        // An isolated contract run must neither probe WSL nor reuse a real
        // runtime from an earlier discovery. This also runs on Windows hosts.
        let isolated = discover_runtime_targets_resilient_with(
            &HashMap::from([
                ("PATH".into(), String::new()),
                (
                    "ZOMMI_RUNTIME_DISCOVERY_MODE".into(),
                    "configured-only".into(),
                ),
                ("ZOMMI_CODEX_COMMAND".into(), "fixture-python.exe".into()),
            ]),
            "windows",
            &[],
            &store,
            true,
        );
        assert!(isolated.wsl_probe_succeeded);
        assert_eq!(isolated.targets.len(), 1);
        assert_eq!(isolated.targets[0].executable_path, "fixture-python.exe");
        assert_eq!(isolated.targets[0].execution_host.kind, "native");
        assert!(store.load().expect("empty isolated cache").is_empty());
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn native_windows_claude_and_legacy_overrides_use_structured_protocol() {
        let root = std::env::temp_dir().join(format!(
            "zommi-native-claude-{}-{}",
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
            .any(|target| target.adapter_id == "claude-stream-json")
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
        assert_eq!(
            target_from_override(&configured, "windows")
                .unwrap()
                .adapter_id,
            "claude-stream-json"
        );
        let _ = fs::remove_dir_all(root);
    }
}
