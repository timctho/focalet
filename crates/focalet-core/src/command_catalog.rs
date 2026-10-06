//! Runtime-owned command metadata. Discovery never grants arbitrary RPC access.
use std::collections::HashSet;

use serde_json::{Value, json};

use crate::codex_adapter::CodexError;

pub fn command_name(text: &str) -> Option<&str> {
    let name = text
        .trim_start()
        .strip_prefix('/')?
        .split_whitespace()
        .next()?;
    valid_name(name).then_some(name)
}

fn valid_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 200
        && name
            .chars()
            .all(|c| c.is_alphanumeric() || "-_:./".contains(c))
}

pub fn normalize(commands: &[Value]) -> Vec<Value> {
    let mut seen = HashSet::new();
    commands.iter().filter_map(|command| {
        let name = command.get("name")?.as_str()?.trim_start_matches('/');
        if !valid_name(name) || !seen.insert(name.to_owned()) { return None; }
        let mut result = json!({
            "name": name,
            "description": command.get("description").and_then(Value::as_str).unwrap_or("").chars().take(500).collect::<String>(),
            "inputHint": command.get("inputHint").or_else(|| command.pointer("/input/hint")).and_then(Value::as_str).unwrap_or("").chars().take(200).collect::<String>(),
        });
        for key in ["source", "path", "disabledReason"] {
            if let Some(value) = command.get(key).and_then(Value::as_str) {
                result[key] = json!(value);
            }
        }
        if let Some(subcommands) = command.get("subcommands").and_then(Value::as_array) {
            result["subcommands"] = json!(subcommands.iter().filter_map(Value::as_str).filter(|name| valid_name(name)).take(40).collect::<Vec<_>>());
        }
        Some(result)
    }).take(500).collect()
}

pub fn require_command<'a>(commands: &'a [Value], text: &str) -> Result<&'a Value, CodexError> {
    let command = command_name(text)
        .and_then(|name| commands.iter().find(|c| c["name"] == name))
        .ok_or_else(|| {
            unavailable(
                "This command is no longer advertised by the runtime. Refresh the command menu.",
            )
        })?;
    if let Some(reason) = command.get("disabledReason").and_then(Value::as_str) {
        return Err(unavailable(reason));
    }
    Ok(command)
}

fn unavailable(message: &str) -> CodexError {
    CodexError {
        code: "command-unavailable".into(),
        ..error(message)
    }
}

pub fn error(message: &str) -> CodexError {
    CodexError {
        code: "capability-unavailable".into(),
        message: message.into(),
        retryable: false,
    }
}

/// These commands change settings which Focalet otherwise sends on the next
/// prompt. Until the protocol provides authoritative post-command settings,
/// allowing them would silently undo the user's choice on that next prompt.
pub fn with_client_limits(mut commands: Vec<Value>) -> Vec<Value> {
    for command in &mut commands {
        if matches!(
            command["name"]
                .as_str()
                .map(|name| name.trim_start_matches('/')),
            Some(
                "model"
                    | "provider"
                    | "profile"
                    | "cd"
                    | "cwd"
                    | "effort"
                    | "reasoning"
                    | "think"
                    | "thinking"
            )
        ) {
            command["disabledReason"] =
                json!("Use Focalet's model, reasoning, or workspace settings for this command.");
        }
    }
    commands
}

pub fn hermes_catalog(value: &Value) -> Vec<Value> {
    let terminal: HashSet<&str> = value
        .get("categories")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter(|c| c["name"] == "TUI")
        .flat_map(|c| c["pairs"].as_array().into_iter().flatten())
        .filter_map(|p| p[0].as_str())
        .collect();
    let quick: HashSet<&str> = value
        .get("categories")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter(|c| c["name"] == "User commands")
        .flat_map(|c| c["pairs"].as_array().into_iter().flatten())
        .filter_map(|p| p[0].as_str())
        .collect();
    let mut commands: Vec<Value> = value["pairs"].as_array().into_iter().flatten().filter_map(|pair| {
        let name = pair[0].as_str()?;
        let mut command = json!({"name": name, "description": pair[1], "source": "runtime"});
        if value["skills"].get(name).is_some() { command["source"] = json!("skill"); }
        if quick.contains(name) { command["source"] = json!("quick"); }
        if let Some(subcommands) = value["sub"].get(name).or_else(|| value["sub"].get(name.trim_start_matches('/'))) {
            command["subcommands"] = subcommands.clone();
        }
        if terminal.contains(name) || ["/quit", "/exit", "/new", "/reset", "/clear", "/resume", "/snapshot", "/snap"].contains(&name) {
            command["disabledReason"] = json!("This command requires the Hermes terminal interface. Use Focalet's chat controls where available.");
        }
        Some(command)
    }).collect();
    commands = with_client_limits(commands);
    // Aliases inherit their canonical command's dispatch and availability.
    if let Some(aliases) = value["canon"].as_object() {
        for (alias, target) in aliases {
            if alias == target.as_str().unwrap_or_default() {
                continue;
            }
            if let Some(mut command) = commands.iter().find(|c| c["name"] == *target).cloned() {
                command["name"] = json!(alias);
                commands.push(command);
            }
        }
    }
    with_client_limits(normalize(&commands))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn catalogs_are_bounded_and_invalid_names_cannot_be_executed() {
        let commands = normalize(&[
            json!({"name":"/skill:test", "input":{"hint":"task"}}),
            json!({"name":"skill:test"}),
            json!({"name":"bad command"}),
            json!({"name":"quit", "disabledReason":"terminal only"}),
        ]);
        assert_eq!(commands.len(), 2);
        assert_eq!(commands[0]["inputHint"], "task");
        assert!(require_command(&commands, "/skill:test some arguments").is_ok());
        assert!(require_command(&commands, "/missing").is_err());
        assert!(require_command(&commands, "/quit").is_err());
    }
    #[test]
    fn settings_aliases_do_not_bypass_client_state_limits() {
        let commands = hermes_catalog(
            &json!({"pairs":[["/model","Model"]], "canon":{"/m":"/model"}, "sub":{"model":["list"]}}),
        );
        assert!(require_command(&commands, "/model other").is_err());
        assert!(require_command(&commands, "/m other").is_err());
        assert_eq!(commands[0]["subcommands"], json!(["list"]));
    }

    #[test]
    fn hermes_aliases_preserve_terminal_limits_and_skill_dispatch() {
        let commands = hermes_catalog(
            &json!({"pairs":[["/quit","Exit"],["/inspect","Inspect"]], "skills":{"/inspect":{}}, "canon":{"/q":"/quit", "/i":"/inspect"}}),
        );
        assert!(require_command(&commands, "/q").is_err());
        assert_eq!(require_command(&commands, "/i").unwrap()["source"], "skill");
    }
}
