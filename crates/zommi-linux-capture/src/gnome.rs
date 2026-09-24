use crate::{AppResult, geometry::Bounds};
use atspi::zbus::{Connection, Proxy};
use serde_json::{Value, json};
use std::{fs, time::Duration};

pub(crate) const EXTENSION_UUID: &str = "zommi@zommi";
pub(crate) const SETUP_HINT: &str = "Enable Zommi Desktop Integration in App settings. If it was just installed, sign out of Ubuntu and sign in again, then retry.";

pub(crate) async fn proxy(connection: &Connection) -> AppResult<Proxy<'_>> {
    Ok(Proxy::new(
        connection,
        "com.zommi.Desktop",
        "/com/zommi/Desktop",
        "com.zommi.Desktop",
    )
    .await?)
}

pub(crate) async fn snapshot(connection: &Connection) -> AppResult<Value> {
    let response: String = tokio::time::timeout(Duration::from_secs(3), async {
        proxy(connection)
            .await?
            .call("Snapshot", &())
            .await
            .map_err(Into::into)
    })
    .await
    .map_err(|_| format!("GNOME desktop integration did not respond. {SETUP_HINT}"))?
    .map_err(|error: Box<dyn std::error::Error>| {
        format!("GNOME desktop integration is unavailable. {SETUP_HINT} ({error})")
    })?;
    if response.len() > 2_000_000 {
        return Err("GNOME desktop response is too large".into());
    }
    let mut value: Value = serde_json::from_str(&response)?;
    if value["schemaVersion"] != 1 || value["available"] != true {
        return Err("Close the GNOME overview or unlock the desktop, then select again.".into());
    }
    let windows = value["windows"]
        .as_array_mut()
        .ok_or("Missing GNOME windows")?;
    if windows.len() > 512 {
        return Err("Too many desktop windows".into());
    }
    for window in windows {
        let bounds: Bounds = serde_json::from_value(window["bounds"].clone())?;
        if !bounds.valid() {
            return Err("Invalid GNOME window bounds".into());
        }
        if let Some(pid) = window["processId"].as_u64().filter(|pid| *pid > 0) {
            let (Ok(stat), Ok(name)) = (
                fs::read_to_string(format!("/proc/{pid}/stat")),
                fs::read_to_string(format!("/proc/{pid}/comm")),
            ) else {
                // A disappearing or inaccessible process is still an occluder,
                // but must not break capture of other applications.
                window["processId"] = Value::Null;
                window["obstruction"] = json!(true);
                continue;
            };
            let started = stat
                .rsplit_once(") ")
                .and_then(|(_, s)| s.split_whitespace().nth(19))
                .ok_or("Cannot identify source process lifetime")?;
            window["processStartToken"] = json!(started);
            window["processName"] = json!(name.trim());
            window["platform"] = json!("linux");
            window["provider"] = json!("wayland-atspi");
        }
    }
    Ok(value)
}

pub(crate) async fn status(connection: &Connection) -> Value {
    let session = std::env::var("XDG_SESSION_TYPE").unwrap_or_default();
    let wayland = session == "wayland"
        || (session.is_empty() && std::env::var_os("WAYLAND_DISPLAY").is_some());
    match snapshot(connection).await {
        Ok(_) if wayland => {
            json!({"ready":true,"wayland":true,"message":"Desktop integration is ready. Screen sharing is requested when you select content."})
        }
        _ if !wayland => {
            json!({"ready":false,"wayland":false,"message":"Capture requires Ubuntu 24.04's GNOME Wayland session. Sign out and choose Ubuntu at the login screen."})
        }
        Err(error) => json!({"ready":false,"wayland":true,"message":error.to_string()}),
        _ => unreachable!(),
    }
}

pub(crate) async fn enable(connection: &Connection) -> AppResult<Value> {
    let extensions = Proxy::new(
        connection,
        "org.gnome.Shell",
        "/org/gnome/Shell",
        "org.gnome.Shell.Extensions",
    )
    .await?;
    if !extensions
        .get_property::<bool>("UserExtensionsEnabled")
        .await?
    {
        return Err("GNOME extensions are disabled globally. Turn them on in the Extensions app, then retry.".into());
    }
    let enabled: bool = extensions
        .call("EnableExtension", &(EXTENSION_UUID,))
        .await?;
    if !enabled {
        return Err(format!("GNOME has not loaded the bundled extension. {SETUP_HINT}").into());
    }
    for _ in 0..10 {
        tokio::time::sleep(Duration::from_millis(200)).await;
        let status = status(connection).await;
        if status["ready"] == true {
            return Ok(status);
        }
    }
    Ok(status(connection).await)
}
