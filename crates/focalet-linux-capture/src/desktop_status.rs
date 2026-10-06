//! Diagnose the running compositor rather than trusting a launcher's environment.
use crate::{AppResult, gnome};
use atspi::zbus::{Connection, Proxy, zvariant::OwnedValue};
use serde_json::{Value, json};
use std::{collections::HashMap, env, fs, path::PathBuf, time::Duration};

fn environment() -> Value {
    let setting = |name| {
        env::var(name)
            .unwrap_or_default()
            .chars()
            .take(256)
            .collect::<String>()
    };
    json!({
        "reportedSession": setting("XDG_SESSION_TYPE"),
        "reportedDesktop": setting("XDG_CURRENT_DESKTOP"),
        "waylandDisplayPresent": env::var_os("WAYLAND_DISPLAY").is_some(),
        "wsl": env::var_os("WSL_DISTRO_NAME").is_some()
            || fs::read_to_string("/proc/sys/kernel/osrelease")
                .is_ok_and(|value| value.to_ascii_lowercase().contains("microsoft")),
    })
}

fn response(reason: &str, message: &str, can_enable: bool, diagnostics: Value) -> Value {
    let wayland = diagnostics["compositorSession"]
        .as_str()
        .map(|value| value == "wayland");
    json!({"ready":reason == "ready", "reason":reason, "wayland":wayland,
        "message":message, "canEnable":can_enable,
        "enableLabel":if reason == "extension-disabled" {"Enable desktop integration"} else {"Repair desktop integration"},
        "diagnostics":diagnostics})
}

pub(crate) fn connection_unavailable(error: &str) -> Value {
    let mut details = environment();
    details["error"] = json!(error.chars().take(2048).collect::<String>());
    response(
        "session-bus-unavailable",
        "Focalet cannot reach your desktop session. Open it from the Ubuntu app menu as your normal user, without sudo, then retry.",
        false,
        details,
    )
}

fn without_gnome(details: Value) -> Value {
    if details["wsl"] == true {
        response(
            "wslg-without-gnome",
            "This WSL session has no GNOME desktop. WSLg app windows do not provide GNOME desktop capture. Use Focalet for Windows to capture your Windows desktop, or run Ubuntu 24.04 with GNOME Wayland in a desktop or VM.",
            false,
            details,
        )
    } else if details["reportedSession"] == "x11" {
        response(
            "x11-session",
            "GNOME is not reachable and this app reports an X11 session. Capture supports GNOME Wayland. Open Focalet from the GNOME app menu. If you use Xorg, select Ubuntu instead of Ubuntu on Xorg at the login screen; if that choice is unavailable, check your system's Wayland configuration.",
            false,
            details,
        )
    } else {
        response(
            "gnome-unavailable",
            "GNOME Shell is not reachable from this app. Open Focalet inside your Ubuntu 24.04 GNOME desktop as your normal user, without sudo. A terminal, SSH session or another desktop does not provide this integration.",
            false,
            details,
        )
    }
}

fn compositor_status(value: Value, mut details: Value) -> Value {
    if value["schemaVersion"] != 1
        || !value["available"].is_boolean()
        || !matches!(value["sessionType"].as_str(), Some("wayland" | "x11"))
    {
        return extension_update_needed(details);
    }
    details["compositorSession"] = value["sessionType"].clone();
    details["loadedIntegrationVersion"] = value["integrationVersion"].clone();
    if value["sessionType"] == "x11" {
        return response(
            "x11-session",
            "GNOME is running on Xorg (X11). Capture supports Wayland. At Ubuntu's login screen, select your user and choose Ubuntu from the gear menu instead of Ubuntu on Xorg. If that choice is unavailable, Wayland must be enabled in your system first.",
            false,
            details,
        );
    }
    if value["available"] != true {
        return response(
            "desktop-busy",
            "Desktop integration is connected. Close the GNOME overview or system dialog, or unlock the desktop, then retry capture.",
            false,
            details,
        );
    }
    response(
        "ready",
        "Desktop integration is ready. Screen sharing is requested when you select content.",
        false,
        details,
    )
}

fn extension_update_needed(details: Value) -> Value {
    // GNOME 46 caches imported ES modules. Toggling an extension cannot replace
    // its JavaScript with upgraded code, and ReloadExtension is unsupported.
    response(
        "extension-update-needed",
        "GNOME is still running an older Focalet desktop integration. Sign out of the Ubuntu desktop once to load the installed update. If this persists after signing in, check the extension path in these diagnostics for an older user-installed copy.",
        false,
        details,
    )
}

async fn extensions(connection: &Connection) -> AppResult<Proxy<'_>> {
    Ok(Proxy::new(
        connection,
        "org.gnome.Shell",
        "/org/gnome/Shell",
        "org.gnome.Shell.Extensions",
    )
    .await?)
}

fn extension_files_present() -> bool {
    let user_data = env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .or_else(|| env::var_os("HOME").map(|home| PathBuf::from(home).join(".local/share")));
    let mut roots = vec![PathBuf::from("/usr/share")];
    roots.extend(user_data);
    roots.iter().any(|root| {
        root.join("gnome-shell/extensions/focalet@focalet/metadata.json")
            .is_file()
    })
}

async fn inspect(connection: &Connection, details: &mut Value) -> AppResult<Value> {
    let bus = Proxy::new(
        connection,
        "org.freedesktop.DBus",
        "/org/freedesktop/DBus",
        "org.freedesktop.DBus",
    )
    .await?;
    let present: bool = bus.call("NameHasOwner", &("org.gnome.Shell",)).await?;
    details["gnomeReachable"] = json!(present);
    if !present {
        return Ok(without_gnome(details.clone()));
    }
    let manager = extensions(connection).await?;
    let version: String = manager.get_property("ShellVersion").await?;
    details["gnomeVersion"] = json!(version);
    if version.split('.').next() != Some("46") {
        return Ok(response(
            "gnome-version-unsupported",
            &format!(
                "Detected GNOME {version}. This build supports GNOME 46 on Ubuntu 24.04. Install a compatible Focalet build or use the supported desktop version."
            ),
            false,
            details.clone(),
        ));
    }
    let enabled: bool = manager.get_property("UserExtensionsEnabled").await?;
    details["extensionsEnabled"] = json!(enabled);
    if !enabled {
        return Ok(response(
            "extensions-disabled",
            "GNOME extensions are disabled globally. Turn them on in the Extensions app, then check desktop integration again.",
            false,
            details.clone(),
        ));
    }
    let info: HashMap<String, OwnedValue> = manager
        .call("GetExtensionInfo", &(gnome::EXTENSION_UUID,))
        .await?;
    let state = info
        .get("state")
        .and_then(|value| f64::try_from(value).ok())
        .unwrap_or(99.0) as u32;
    details["extensionState"] = json!(state);
    details["extensionPath"] = json!(
        info.get("path")
            .and_then(|value| <&str>::try_from(value).ok())
    );
    details["registeredExtensionVersion"] = json!(
        info.get("version")
            .and_then(|value| f64::try_from(value).ok())
    );
    let error = info
        .get("error")
        .and_then(|value| <&str>::try_from(value).ok())
        .unwrap_or("");
    details["extensionError"] = json!(error.chars().take(2048).collect::<String>());
    match state {
        99 => {
            let installed = extension_files_present();
            details["extensionFilesPresent"] = json!(installed);
            return Ok(response(
                "extension-missing",
                if installed {
                    "GNOME has not registered the installed Focalet extension. Sign out of the Ubuntu desktop once and sign back in. If you already did that, reinstall the Ubuntu .deb and copy these diagnostics; repeatedly restarting Focalet will not register it."
                } else {
                    "The Focalet GNOME extension is not installed. Reinstall the Ubuntu .deb package. For a portable build, run its GNOME extension installation script."
                },
                false,
                details.clone(),
            ));
        }
        2 | 6 => {
            return Ok(response(
                "extension-disabled",
                "Focalet Desktop Integration is installed but disabled. Enable it in App settings to use capture and Alt+A.",
                true,
                details.clone(),
            ));
        }
        3 => {
            return Ok(response(
                "extension-error",
                &format!(
                    "GNOME could not load Focalet Desktop Integration: {error}. Copy the diagnostics to check its error and installation path. Correct the reported problem or reinstall the Ubuntu package before starting a new desktop session."
                ),
                false,
                details.clone(),
            ));
        }
        4 => {
            return Ok(response(
                "extension-incompatible",
                "The installed Focalet extension is incompatible with this GNOME version. Reinstall the Ubuntu 24.04 package and check for an older user-installed copy of the extension.",
                false,
                details.clone(),
            ));
        }
        _ => {}
    }
    // The compositor owns the authoritative session type. Desktop launchers,
    // SSH, systemd services and nested desktops can inherit stale XDG variables.
    let raw: String = match gnome::proxy(connection).await?.call("Status", &()).await {
        Ok(value) => value,
        Err(error) => {
            details["error"] = json!(error.to_string().chars().take(2048).collect::<String>());
            if details["registeredExtensionVersion"]
                .as_f64()
                .is_some_and(|version| version < 2.0)
                && matches!(&error, atspi::zbus::Error::MethodError(name, _, _) if name.as_str() == "org.freedesktop.DBus.Error.UnknownMethod")
            {
                return Ok(extension_update_needed(details.clone()));
            }
            return Ok(response(
                "extension-unresponsive",
                "The running Focalet desktop integration is disconnected. Choose Repair desktop integration to restart its connection.",
                true,
                details.clone(),
            ));
        }
    };
    if raw.len() > 16384 {
        return Err("GNOME status response is too large".into());
    }
    Ok(compositor_status(
        serde_json::from_str(&raw)?,
        details.clone(),
    ))
}

pub(crate) async fn status(connection: &Connection) -> Value {
    let mut details = environment();
    match tokio::time::timeout(Duration::from_secs(4), inspect(connection, &mut details)).await {
        Ok(Ok(value)) => value,
        result => {
            let error = match result {
                Ok(Err(error)) => error.to_string(),
                _ => "GNOME status request timed out".into(),
            };
            details["error"] = json!(error.chars().take(2048).collect::<String>());
            response(
                "gnome-unresponsive",
                "GNOME desktop integration did not respond. Check the diagnostic details and retry. If GNOME itself is unresponsive, restart the desktop session.",
                false,
                details,
            )
        }
    }
}

pub(crate) async fn enable(connection: &Connection) -> Value {
    let mut details = environment();
    let repair = async {
        let current = status(connection).await;
        details = current["diagnostics"].clone();
        if current["ready"] == true || current["canEnable"] != true {
            return Ok(current);
        }
        let manager = extensions(connection).await?;
        if current["reason"] != "extension-disabled" {
            // GNOME 46 rejects ReloadExtension. A healthy but disconnected
            // instance can recover through the supported disable/enable APIs.
            let _: bool = manager
                .call("DisableExtension", &(gnome::EXTENSION_UUID,))
                .await?;
            for _ in 0..5 {
                tokio::time::sleep(Duration::from_millis(100)).await;
                if status(connection).await["reason"] == "extension-disabled" {
                    break;
                }
            }
        }
        let _: bool = manager
            .call("EnableExtension", &(gnome::EXTENSION_UUID,))
            .await?;
        for _ in 0..5 {
            tokio::time::sleep(Duration::from_millis(200)).await;
            let current = status(connection).await;
            if current["ready"] == true || current["canEnable"] != true {
                return Ok(current);
            }
        }
        Ok::<Value, Box<dyn std::error::Error>>(status(connection).await)
    };
    // Leave room for the bounded session-bus connection inside the UI's 10s limit.
    match tokio::time::timeout(Duration::from_secs(6), repair).await {
        Ok(Ok(value)) => value,
        result => {
            let error = match result {
                Ok(Err(error)) => error.to_string(),
                _ => "Extension repair timed out".into(),
            };
            details["repairError"] = json!(error.chars().take(2048).collect::<String>());
            response(
                "extension-repair-failed",
                "GNOME could not repair Focalet Desktop Integration. Copy the diagnostic details and retry; your chat is still available.",
                true,
                details,
            )
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn running_compositor_wins_over_stale_launcher_variables() {
        for reported in ["x11", "tty", "", "wayland"] {
            let status = compositor_status(
                json!({"schemaVersion":1,"sessionType":"wayland","available":true}),
                json!({"reportedSession":reported,"wsl":true}),
            );
            assert_eq!(status["ready"], true);
            assert_eq!(status["wayland"], true);
            assert_eq!(status["diagnostics"]["reportedSession"], reported);
        }
        let status = compositor_status(
            json!({"schemaVersion":1,"sessionType":"x11","available":true}),
            json!({"reportedSession":"wayland"}),
        );
        assert_eq!(status["reason"], "x11-session");
        assert_eq!(status["canEnable"], false);
    }

    #[test]
    fn unavailable_desktops_offer_the_correct_recovery() {
        let wsl = without_gnome(json!({"wsl":true,"reportedSession":"wayland"}));
        assert_eq!(wsl["reason"], "wslg-without-gnome");
        assert!(!wsl["message"].as_str().unwrap().contains("Sign out"));
        assert_eq!(
            without_gnome(json!({"reportedSession":"x11"}))["reason"],
            "x11-session"
        );
        assert_eq!(
            without_gnome(json!({"reportedSession":"tty"}))["reason"],
            "gnome-unavailable"
        );
        let busy = compositor_status(
            json!({"schemaVersion":1,"sessionType":"wayland","available":false}),
            json!({}),
        );
        assert_eq!(busy["reason"], "desktop-busy");
        assert_eq!(busy["canEnable"], false);
        let old = compositor_status(json!({"schemaVersion":1,"available":true}), json!({}));
        assert_eq!(old["reason"], "extension-update-needed");
        assert_eq!(old["canEnable"], false);
    }
}
