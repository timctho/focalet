use std::{
    collections::{HashMap, HashSet},
    env, fs,
    io::Read,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    time::Duration,
};

use serde::{Deserialize, Serialize};
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
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RuntimeCommand {
    pub command: String,
    pub args: Vec<String>,
    pub working_directory: Option<String>,
}

pub fn discover_codex_targets() -> Vec<RuntimeTarget> {
    discover_codex_targets_with(&env::vars().collect(), env::consts::OS)
}

pub fn discover_codex_targets_with(
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

    if let Some(configured) = environment
        .get("ZOMMI_CODEX_COMMAND")
        .filter(|value| !value.trim().is_empty())
    {
        targets.push(target_for(
            &native_host,
            configured.trim(),
            environment.get("HOME").map(String::as_str),
            Some("configured"),
        ));
    } else if let Some(executable) = resolve_native_command("codex", environment, platform) {
        targets.push(target_for(
            &native_host,
            &executable.to_string_lossy(),
            environment.get("HOME").map(String::as_str),
            None,
        ));
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
        args.extend([
            "-e".into(),
            "env".into(),
            "CODEX_INTERNAL_ORIGINATOR_OVERRIDE=codex_exec".into(),
            target.executable_path.clone(),
            "app-server".into(),
        ]);
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
        return RuntimeCommand {
            command: "cmd.exe".into(),
            args: vec![
                "/d".into(),
                "/v:off".into(),
                "/s".into(),
                "/c".into(),
                target.executable_path.clone(),
                "app-server".into(),
            ],
            working_directory: target.runtime_home.clone(),
        };
    }

    RuntimeCommand {
        command: target.executable_path.clone(),
        args: vec!["app-server".into()],
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
                scope.spawn(move || detect_wsl_codex(distribution, default_name, environment))
            })
            .collect::<Vec<_>>()
            .into_iter()
            .filter_map(|probe| probe.join().ok().flatten())
            .collect()
    })
}

fn detect_wsl_codex(
    distribution: &str,
    default_name: Option<&str>,
    environment: &HashMap<String, String>,
) -> Option<RuntimeTarget> {
    let script = concat!(
        "zommi_shell=$(getent passwd $(id -un) 2>/dev/null | cut -d: -f7); ",
        "[ -x \"$zommi_shell\" ] || zommi_shell=\"${SHELL:-/bin/sh}\"; ",
        "exec \"$zommi_shell\" -lc '",
        "printf \"__ZOMMI_RUNTIME_HOME__%s\\n\" \"$HOME\"; ",
        "zommi_path=$(command -v -- codex 2>/dev/null || true); ",
        "case \"$zommi_path\" in /*) printf \"__ZOMMI_RUNTIME_PATH__codex\\t%s\\n\" \"$zommi_path\" ;; esac'"
    );
    let output = run_command(
        "wsl.exe",
        &["-d", distribution, "-e", "sh", "-lc", script],
        Some(environment),
    )?;
    let output = normalize_command_output(&output);
    let home = output
        .lines()
        .find_map(|line| line.strip_prefix("__ZOMMI_RUNTIME_HOME__"));
    let executable = output.lines().find_map(|line| {
        line.strip_prefix("__ZOMMI_RUNTIME_PATH__codex\t")
            .filter(|path| path.starts_with('/'))
    })?;
    let host = ExecutionHost {
        id: format!("wsl:{}", distribution.to_ascii_lowercase()),
        kind: "wsl".into(),
        platform: "linux".into(),
        display_name: format!("WSL · {distribution}"),
        is_default: default_name.is_some_and(|name| name.eq_ignore_ascii_case(distribution)),
        name: Some(distribution.into()),
    };
    Some(target_for(&host, executable, home, None))
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
    runtime_home: Option<&str>,
    source: Option<&str>,
) -> RuntimeTarget {
    let identity = format!("{}\0codex-app-server\0{executable_path}\0default", host.id);
    let hash = format!("{:x}", Sha256::digest(identity.as_bytes()));
    RuntimeTarget {
        id: format!("runtime-{}", &hash[..20]),
        runtime_id: "codex".into(),
        adapter_id: "codex-app-server".into(),
        display_name: "Codex".into(),
        protocol_name: "Codex app-server".into(),
        executable_path: executable_path.into(),
        execution_host: host.clone(),
        status: "detected".into(),
        priority: 10,
        capability_hints: CODEX_CAPABILITY_HINTS
            .iter()
            .map(|value| (*value).into())
            .collect(),
        runtime_home: runtime_home
            .filter(|value| !value.is_empty())
            .map(str::to_owned),
        source: source.map(str::to_owned),
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
        ExecutionHost, RuntimeTarget, command_for_target, discover_codex_targets_with,
        select_default_target,
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
        let first = discover_codex_targets_with(&environment, "linux");
        let second = discover_codex_targets_with(&environment, "linux");
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
}
