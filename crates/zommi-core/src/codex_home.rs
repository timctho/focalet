use std::{fs, io, path::PathBuf};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::{RuntimeCommand, SessionBindingStore};

#[derive(Clone)]
pub(crate) struct CodexHomeStore {
    path: PathBuf,
    target_id: String,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Binding {
    runtime_target_id: String,
    codex_home: String,
}

impl CodexHomeStore {
    pub(crate) fn for_target(target_id: &str) -> Self {
        Self::at(
            SessionBindingStore::platform_default().codex_homes_directory(),
            target_id,
        )
    }

    fn at(directory: PathBuf, target_id: &str) -> Self {
        Self {
            path: directory.join(format!("{:x}.json", Sha256::digest(target_id.as_bytes()))),
            target_id: target_id.into(),
        }
    }

    pub(crate) fn load(&self) -> io::Result<Option<String>> {
        let bytes = match fs::read(&self.path) {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(error),
        };
        let binding: Binding = serde_json::from_slice(&bytes).map_err(io::Error::other)?;
        if binding.runtime_target_id != self.target_id {
            return Err(io::Error::other(
                "Codex home binding belongs to another runtime.",
            ));
        }
        validate_home(&binding.codex_home)?;
        Ok(Some(binding.codex_home))
    }

    pub(crate) fn remember(&self, home: &str) -> io::Result<()> {
        validate_home(home)?;
        let binding = Binding {
            runtime_target_id: self.target_id.clone(),
            codex_home: home.into(),
        };
        fs::create_dir_all(self.path.parent().expect("binding directory"))?;
        let temporary = self
            .path
            .with_extension(format!("tmp-{}", uuid::Uuid::new_v4()));
        fs::write(
            &temporary,
            serde_json::to_vec_pretty(&binding).map_err(io::Error::other)?,
        )?;
        // Publish a complete record without replacing another connection's binding.
        let published = fs::hard_link(&temporary, &self.path);
        let _ = fs::remove_file(&temporary);
        match published {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {
                if self.load()?.as_deref() == Some(home) {
                    Ok(())
                } else {
                    Err(io::Error::other(
                        "Codex returned a different home from this runtime's saved binding.",
                    ))
                }
            }
            Err(error) => Err(error),
        }
    }
}

fn validate_home(home: &str) -> io::Result<()> {
    // A Windows host can bind a Linux path inside WSL.
    if home.is_empty()
        || home.contains('\0')
        || !(home.starts_with('/') || PathBuf::from(home).is_absolute())
    {
        return Err(io::Error::other("Codex home must be an absolute path."));
    }
    Ok(())
}

pub(crate) fn pin_wsl_home(
    command: &mut RuntimeCommand,
    executable: &str,
    home: &str,
) -> io::Result<()> {
    validate_home(home)?;
    let position = command
        .args
        .iter()
        .rposition(|arg| arg == executable)
        .ok_or_else(|| {
            io::Error::other(
                "Cannot pin Codex home: WSL command does not contain the runtime executable.",
            )
        })?;
    if !command.args[..position]
        .iter()
        .any(|arg| arg == "/usr/bin/env")
    {
        return Err(io::Error::other(
            "Cannot pin Codex home: WSL command has no environment launcher.",
        ));
    }
    command.args.insert(position, format!("CODEX_HOME={home}"));
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn persists_exact_home_per_target_and_rejects_switches() {
        let root = std::env::temp_dir().join(format!("zommi-homes-{}", uuid::Uuid::new_v4()));
        let home = root.join("home with spaces").to_string_lossy().into_owned();
        let store = CodexHomeStore::at(root.clone(), "runtime-one");
        assert_eq!(store.load().unwrap(), None);
        store.remember(&home).unwrap();
        let reopened = CodexHomeStore::at(root.clone(), "runtime-one");
        assert_eq!(reopened.load().unwrap().as_deref(), Some(home.as_str()));
        reopened.remember(&home).unwrap();
        assert!(reopened.remember("/different-home").is_err());
        assert_eq!(
            CodexHomeStore::at(root.clone(), "runtime-two")
                .load()
                .unwrap(),
            None
        );
        fs::write(&store.path, "invalid").unwrap();
        assert!(store.load().is_err());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn pins_home_inside_direct_and_relay_wsl_commands_without_shell_parsing() {
        for prefix in [
            vec!["-d", "Ubuntu", "-e"],
            vec![
                "--wsl-proxy",
                "--distribution",
                "Ubuntu",
                "--cwd",
                "/home/u",
                "--",
            ],
        ] {
            let mut args: Vec<String> = prefix.into_iter().map(str::to_owned).collect();
            args.extend(
                [
                    "/usr/bin/env",
                    "-u",
                    "PARENT_APP_CODEX_HOME",
                    "CODEX_HOME=/old",
                    "/home/u/codex",
                    "app-server",
                ]
                .map(str::to_owned),
            );
            let mut command = RuntimeCommand {
                command: "launcher".into(),
                args,
                working_directory: None,
            };
            pin_wsl_home(
                &mut command,
                "/home/u/codex",
                "/home/u/history with $spaces",
            )
            .unwrap();
            assert_eq!(
                &command.args[command.args.len() - 3..],
                [
                    "CODEX_HOME=/home/u/history with $spaces",
                    "/home/u/codex",
                    "app-server"
                ]
            );
        }
    }

    #[test]
    fn rejects_unrecognized_wsl_launchers_and_relative_homes() {
        let mut command = RuntimeCommand {
            command: "wsl.exe".into(),
            args: vec!["codex".into()],
            working_directory: None,
        };
        assert!(pin_wsl_home(&mut command, "codex", "/home/u").is_err());
        assert!(validate_home("relative").is_err());
    }
}
