use std::io::{self, BufRead, Write};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use zommi_core::build_context_handoff;

const CORE_PROTOCOL_VERSION: u64 = 1;
const MAX_REQUEST_BYTES: usize = 1024 * 1024;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CoreRequest {
    id: Option<String>,
    protocol_version: Option<u64>,
    operation: Option<String>,
    #[serde(default = "empty_object")]
    payload: Value,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct CoreResponse {
    id: Option<String>,
    protocol_version: u64,
    ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<CoreProtocolError>,
}

#[derive(Debug, Serialize)]
struct CoreProtocolError {
    code: String,
    message: String,
}

enum HostAction {
    Continue(CoreResponse),
    Shutdown(CoreResponse),
}

fn main() -> io::Result<()> {
    let stdin = io::stdin();
    let mut stdout = io::BufWriter::new(io::stdout().lock());
    for line in stdin.lock().lines() {
        let line = line?;
        let action = process_line(&line);
        let response = match &action {
            HostAction::Continue(response) | HostAction::Shutdown(response) => response,
        };
        serde_json::to_writer(&mut stdout, response)?;
        stdout.write_all(b"\n")?;
        stdout.flush()?;
        if matches!(action, HostAction::Shutdown(_)) {
            break;
        }
    }
    Ok(())
}

fn process_line(line: &str) -> HostAction {
    if line.len() > MAX_REQUEST_BYTES {
        return HostAction::Continue(error_response(
            None,
            "input-too-large",
            "Core request exceeds 1 MiB.",
        ));
    }
    let request = match serde_json::from_str::<CoreRequest>(line) {
        Ok(request) => request,
        Err(error) => {
            return HostAction::Continue(error_response(
                None,
                "invalid-request",
                format!("Core request is not valid JSON: {error}"),
            ));
        }
    };
    let id = request.id.clone();
    if id.as_deref().is_none_or(str::is_empty) {
        return HostAction::Continue(error_response(
            id,
            "invalid-request",
            "Core request requires id.",
        ));
    }
    if request.protocol_version != Some(CORE_PROTOCOL_VERSION) {
        return HostAction::Continue(error_response(
            id,
            "unsupported-version",
            format!(
                "Unsupported core protocol version {}.",
                request
                    .protocol_version
                    .map_or_else(|| "<missing>".into(), |version| version.to_string())
            ),
        ));
    }
    let Some(operation) = request.operation.as_deref() else {
        return HostAction::Continue(error_response(
            id,
            "invalid-request",
            "Core request requires operation.",
        ));
    };
    if !request.payload.is_object() {
        return HostAction::Continue(error_response(
            id,
            "invalid-request",
            "Core request payload must be an object.",
        ));
    }

    match operation {
        "core.initialize" => HostAction::Continue(success_response(
            id,
            json!({
                "coreVersion": env!("CARGO_PKG_VERSION"),
                "protocolVersion": CORE_PROTOCOL_VERSION,
                "capabilities": ["context.handoff.v1", "protocol.validation.v1"]
            }),
        )),
        "context.buildHandoff" => {
            let message = request
                .payload
                .get("message")
                .and_then(Value::as_str)
                .unwrap_or_default();
            let snapshots = request
                .payload
                .get("snapshots")
                .and_then(Value::as_array)
                .map(Vec::as_slice)
                .unwrap_or_default();
            let image_count = request
                .payload
                .get("imageCount")
                .and_then(Value::as_u64)
                .and_then(|count| usize::try_from(count).ok())
                .unwrap_or_default();
            HostAction::Continue(success_response(
                id,
                json!({
                    "text": build_context_handoff(message, snapshots, image_count)
                }),
            ))
        }
        "core.shutdown" => HostAction::Shutdown(success_response(id, json!({"stopped": true}))),
        _ => HostAction::Continue(error_response(
            id,
            "unsupported-operation",
            format!("Unsupported core operation '{operation}'."),
        )),
    }
}

fn success_response(id: Option<String>, result: Value) -> CoreResponse {
    CoreResponse {
        id,
        protocol_version: CORE_PROTOCOL_VERSION,
        ok: true,
        result: Some(result),
        error: None,
    }
}

fn error_response(
    id: Option<String>,
    code: impl Into<String>,
    message: impl Into<String>,
) -> CoreResponse {
    CoreResponse {
        id,
        protocol_version: CORE_PROTOCOL_VERSION,
        ok: false,
        result: None,
        error: Some(CoreProtocolError {
            code: code.into(),
            message: message.into(),
        }),
    }
}

fn empty_object() -> Value {
    Value::Object(serde_json::Map::new())
}

#[cfg(test)]
mod tests {
    use serde_json::Value;

    use super::{CORE_PROTOCOL_VERSION, HostAction, process_line};

    fn response(line: &str) -> Value {
        let action = process_line(line);
        let response = match action {
            HostAction::Continue(response) | HostAction::Shutdown(response) => response,
        };
        serde_json::to_value(response).expect("serialize response")
    }

    #[test]
    fn initializes_a_versioned_rust_core() {
        let result = response(
            r#"{"id":"1","protocolVersion":1,"operation":"core.initialize","payload":{}}"#,
        );
        assert_eq!(result["ok"], true);
        assert_eq!(result["protocolVersion"], CORE_PROTOCOL_VERSION);
        assert_eq!(result["result"]["coreVersion"], env!("CARGO_PKG_VERSION"));
        assert_eq!(result["result"]["capabilities"][0], "context.handoff.v1");
    }

    #[test]
    fn builds_context_handoffs_over_the_host_protocol() {
        let result = response(
            r#"{"id":"2","protocolVersion":1,"operation":"context.buildHandoff","payload":{"message":"compare","snapshots":[{"surfaceKind":"Browser","application":"Edge","selection":["value"]}],"imageCount":1}}"#,
        );
        let text = result["result"]["text"].as_str().expect("handoff text");
        assert!(text.contains("<user_message>\ncompare"));
        assert!(text.contains("PRIMARY SURFACE SELECTION"));
        assert!(text.contains("User-selected image regions attached: 1"));
    }

    #[test]
    fn rejects_protocol_skew() {
        let result = response(
            r#"{"id":"3","protocolVersion":99,"operation":"core.initialize","payload":{}}"#,
        );
        assert_eq!(result["ok"], false);
        assert_eq!(result["error"]["code"], "unsupported-version");
    }
}
