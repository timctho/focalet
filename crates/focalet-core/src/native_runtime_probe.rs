//! Desktop launchers often lack the PATH configured by a terminal shell.
use std::{collections::HashMap, path::PathBuf};

#[derive(Default)]
pub(crate) struct ShellRuntimes {
    pub executables: HashMap<String, PathBuf>,
    pub path: Option<String>,
}

#[cfg(unix)]
pub(crate) fn default_shell() -> Option<String> {
    // NSS on Linux and Directory Services on macOS also cover accounts that
    // do not appear as a local /etc/passwd entry.
    let mut account = std::mem::MaybeUninit::<libc::passwd>::uninit();
    let mut buffer = vec![0u8; 16384];
    let mut result = std::ptr::null_mut();
    let status = unsafe {
        libc::getpwuid_r(
            libc::geteuid(),
            account.as_mut_ptr(),
            buffer.as_mut_ptr().cast(),
            buffer.len(),
            &mut result,
        )
    };
    if status != 0 || result.is_null() {
        return None;
    }
    let shell = unsafe { (*result).pw_shell };
    if shell.is_null() {
        return None;
    }
    unsafe { std::ffi::CStr::from_ptr(shell) }
        .to_str()
        .ok()
        .map(str::to_owned)
}

#[cfg(unix)]
pub(crate) fn discover(environment: &HashMap<String, String>, names: &[&str]) -> ShellRuntimes {
    use std::{
        fs,
        io::{Read, Seek, SeekFrom},
        os::unix::{
            fs::{OpenOptionsExt, PermissionsExt},
            process::CommandExt,
        },
        process::{Command, Stdio},
        time::Duration,
    };
    use wait_timeout::ChildExt;

    fn probe(environment: &HashMap<String, String>, names: &[&str]) -> Option<ShellRuntimes> {
        let shell = PathBuf::from(environment.get("SHELL")?);
        if !shell.is_absolute() || !shell.is_file() {
            return None;
        }
        let shell_name = shell.file_name()?.to_str()?;
        let commands = names.join(" ");
        let script = match shell_name {
            "bash" | "zsh" | "ksh" | "sh" | "dash" => format!(
                "printf '__FOCALET_SHELL_PATH__%s\\n' \"$PATH\"; for focalet_command in {commands}; do focalet_path=$(command -v -- \"$focalet_command\" 2>/dev/null) || continue; case \"$focalet_path\" in /*) printf '__FOCALET_EXECUTABLE__%s\\t%s\\n' \"$focalet_command\" \"$focalet_path\" ;; esac; done"
            ),
            "fish" => format!(
                "printf '__FOCALET_SHELL_PATH__%s\\n' (string join : $PATH); for focalet_command in {commands}; set focalet_path (command -s $focalet_command); test -n \"$focalet_path\"; and printf '__FOCALET_EXECUTABLE__%s\\t%s\\n' $focalet_command $focalet_path; end"
            ),
            _ => return None,
        };
        // A file avoids pipe deadlocks from verbose shell startup scripts or
        // background jobs inheriting stdout. Unlink it before the child runs.
        let temporary =
            std::env::temp_dir().join(format!("focalet-shell-{}", uuid::Uuid::new_v4()));
        let mut output = fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&temporary)
            .ok()?;
        fs::remove_file(temporary).ok()?;
        let mut command = Command::new(&shell);
        command
            .args([
                if matches!(shell_name, "sh" | "dash") {
                    "-lc"
                } else {
                    "-lic"
                },
                &script,
            ])
            .env_clear()
            .envs(environment)
            .stdin(Stdio::null())
            .stdout(Stdio::from(output.try_clone().ok()?))
            .stderr(Stdio::null())
            .process_group(0);
        let mut child = command.spawn().ok()?;
        match child.wait_timeout(Duration::from_secs(4)) {
            Ok(Some(status)) if status.success() => {}
            _ => {
                // This is the process group created solely for this probe.
                unsafe {
                    libc::kill(-(child.id() as i32), libc::SIGKILL);
                }
                let _ = child.wait();
                return None;
            }
        }
        if output.metadata().ok()?.len() > 262144 {
            return None;
        }
        output.seek(SeekFrom::Start(0)).ok()?;
        let mut text = String::new();
        output.take(262145).read_to_string(&mut text).ok()?;
        let mut result = ShellRuntimes::default();
        for line in text.lines() {
            if let Some(path) = line.strip_prefix("__FOCALET_SHELL_PATH__") {
                result.path = Some(path.to_owned());
            }
            if let Some((name, path)) = line
                .strip_prefix("__FOCALET_EXECUTABLE__")
                .and_then(|line| line.split_once('\t'))
            {
                let path = PathBuf::from(path);
                if names.contains(&name)
                    && path.is_absolute()
                    && fs::metadata(&path)
                        .is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
                {
                    result.executables.insert(name.to_owned(), path);
                }
            }
        }
        Some(result)
    }
    probe(environment, names).unwrap_or_default()
}

#[cfg(not(unix))]
pub(crate) fn discover(_: &HashMap<String, String>, _: &[&str]) -> ShellRuntimes {
    ShellRuntimes::default()
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::{
        fs,
        os::unix::fs::PermissionsExt,
        time::{Duration, Instant},
    };

    #[test]
    fn noisy_and_stalled_shells_cannot_hang_discovery() {
        let root =
            std::env::temp_dir().join(format!("focalet-shell-limit-{}", uuid::Uuid::new_v4()));
        fs::create_dir(&root).unwrap();
        let shell = root.join("bash");
        let environment = HashMap::from([("SHELL".into(), shell.to_string_lossy().into_owned())]);
        fs::write(&shell, "#!/bin/sh\n/usr/bin/head -c 300000 /dev/zero\n").unwrap();
        fs::set_permissions(&shell, fs::Permissions::from_mode(0o755)).unwrap();
        assert!(discover(&environment, &["codex"]).executables.is_empty());
        fs::write(&shell, "#!/bin/sh\n/bin/sleep 30\n").unwrap();
        let started = Instant::now();
        assert!(discover(&environment, &["codex"]).executables.is_empty());
        assert!(started.elapsed() < Duration::from_secs(7));
        fs::remove_dir_all(root).unwrap();
    }
}
