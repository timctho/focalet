use atspi::zbus::Connection;
use futures_util::StreamExt;
use serde_json::{Value, json};
use std::{
    error::Error,
    io::{BufRead, Write},
    time::Duration,
};
mod accessibility;
mod geometry;
mod gnome;
mod screencast;
type AppResult<T> = Result<T, Box<dyn Error>>;
fn emit(value: &Value) -> AppResult<()> {
    let mut output = std::io::stdout().lock();
    serde_json::to_writer(&mut output, value)?;
    writeln!(output)?;
    output.flush()?;
    Ok(())
}
#[tokio::main]
async fn main() {
    if let Err(error) = run().await {
        eprintln!("Ubuntu capture failed: {error}");
        std::process::exit(1);
    }
}
async fn run() -> AppResult<()> {
    let command = std::env::args().nth(1).unwrap_or_default();
    if command == "probe" {
        return emit(&json!({"ok":true,"providers":["gnome-wayland","atspi","screencast"]}));
    }
    let connection = Connection::session().await?;
    match command.as_str() {
        "status" => emit(&gnome::status(&connection).await),
        "enable-extension" => emit(&gnome::enable(&connection).await?),
        "present" => {
            let pid: u32 = std::env::args().nth(2).ok_or("Missing process ID")?.parse()?;
            let shown: bool = gnome::proxy(&connection).await?.call("Present", &(pid,)).await?;
            emit(&json!({"shown":shown}))
        }
        "shortcuts" => shortcuts(&connection).await,
        "--capture-host" => host(connection).await,
        _ => Err("usage: zommi-linux-capture <probe|status|enable-extension|present PID|shortcuts|--capture-host>".into()),
    }
}
async fn shortcuts(connection: &Connection) -> AppResult<()> {
    let proxy = gnome::proxy(connection).await?;
    let mut events = proxy.receive_signal("SelectContent").await?;
    let mut timer = tokio::time::interval(Duration::from_secs(3));
    let mut ready = None;
    loop {
        tokio::select! {
            _ = timer.tick() => {
                let status = gnome::status(connection).await;
                let active = status["ready"] == true;
                if ready != Some(active) {
                    emit(&json!({"event":"ready","contextShortcut":active,"message":status["message"]}))?;
                    ready = Some(active);
                }
            }
            event = events.next() => {
                if event.is_none() { return Err("GNOME desktop connection closed; restart Zommi to reconnect.".into()); }
                emit(&json!({"event":"activated","shortcutId":"context"}))?;
            }
        }
    }
}
async fn host(connection: Connection) -> AppResult<()> {
    let mut capture: Option<screencast::Capture> = None;
    // EOF must cancel authorization too, so closing the app never leaves a share dialog.
    let (sender, mut receiver) = tokio::sync::mpsc::channel(8);
    let (closed_sender, mut closed) = tokio::sync::oneshot::channel::<()>();
    // A detached stdin reader avoids Tokio's uncancellable blocking stdin task
    // keeping the helper alive after an explicit shutdown request.
    std::thread::spawn(move || {
        for line in std::io::stdin().lock().lines() {
            let Ok(line) = line else {
                break;
            };
            if line.len() > 65536 || sender.blocking_send(line).is_err() {
                break;
            }
        }
        let _ = closed_sender.send(());
    });
    while let Some(line) = receiver.recv().await {
        let request: Value = match serde_json::from_str(&line) {
            Ok(value) => value,
            Err(error) => {
                emit(&json!({"ok":false,"error":error.to_string()}))?;
                continue;
            }
        };
        let method = request["method"].as_str().unwrap_or("");
        let operation = async {
            match method {
                "ping" => Ok(json!({"ready":true})),
                "selectContent" => {
                    if let Some(active) = capture.take() {
                        active.close().await;
                    }
                    let status = gnome::status(&connection).await;
                    if status["ready"] != true {
                        return Err(status["message"]
                            .as_str()
                            .unwrap_or(gnome::SETUP_HINT)
                            .into());
                    }
                    let _ = atspi::connection::set_session_accessibility(true).await;
                    let Some(mut active) = screencast::Capture::open(connection.clone()).await?
                    else {
                        return Ok(json!({"frames":[],"cancelled":true}));
                    };
                    let result = active.snapshot().await?;
                    capture = Some(active);
                    Ok(result)
                }
                "observe" => {
                    let active = capture
                        .as_mut()
                        .ok_or("Screen sharing ended. Keep the image or select again.")?;
                    active
                        .observe(serde_json::from_value(request["params"]["bounds"].clone())?)
                        .await
                }
                "release" | "shutdown" => {
                    if let Some(active) = capture.take() {
                        active.close().await;
                    }
                    Ok(json!({"released":true}))
                }
                _ => Err("Unknown Ubuntu capture request".into()),
            }
        };
        let timeout = if method == "selectContent" { 180 } else { 15 };
        let result: AppResult<Value> = tokio::select! {
            _ = &mut closed => break,
            result = tokio::time::timeout(Duration::from_secs(timeout), operation) =>
                result.unwrap_or_else(|_| Err("Capture timed out. Select again to reconnect and authorize screen sharing.".into())),
        };
        match result {
            Ok(value) => emit(&json!({"id":request["id"],"ok":true,"result":value}))?,
            Err(error) => {
                capture = None;
                emit(&json!({"id":request["id"],"ok":false,"error":error.to_string()}))?;
                // Disconnect any portal request still waiting on authorization.
                // The desktop client starts a fresh helper on the next attempt.
                if method == "selectContent" {
                    break;
                }
            }
        }
        if method == "shutdown" {
            break;
        }
    }
    if let Some(active) = capture {
        active.close().await;
    }
    Ok(())
}
