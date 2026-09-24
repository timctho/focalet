use crate::{AppResult, geometry::Bounds};
use atspi::zbus::{Connection, Proxy};
use serde_json::{Value, json};
use std::{fs, time::Duration};

pub(crate) const EXTENSION_UUID: &str = "zommi@zommi";
pub(crate) const SETUP_HINT: &str = "Open App settings > Ubuntu desktop integration to check the session and repair the connection.";

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
    crate::desktop_status::status(connection).await
}

pub(crate) async fn enable(connection: &Connection) -> AppResult<Value> {
    Ok(crate::desktop_status::enable(connection).await)
}
