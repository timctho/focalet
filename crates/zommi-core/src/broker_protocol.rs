use std::{collections::HashSet, fmt::Display};

use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use regex::Regex;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use thiserror::Error;
use uuid::Uuid;

pub const BROKER_PROTOCOL_VERSION: u64 = 1;
pub const MAX_TURN_MESSAGE_BYTES: usize = 256 * 1024;
pub const MAX_CONTEXT_SNAPSHOTS: usize = 16;
pub const MAX_IMAGE_ATTACHMENTS: usize = 8;
pub const MAX_IMAGE_BYTES: usize = 20 * 1024 * 1024;
pub const MAX_TOTAL_IMAGE_BYTES: usize = 50 * 1024 * 1024;

pub const BROKER_OPERATIONS: &[&str] = &[
    "runtime.listTargets",
    "runtime.refreshTargets",
    "runtime.getStatus",
    "session.list",
    "session.catalog",
    "session.create",
    "session.open",
    "session.read",
    "session.commands",
    "session.goal",
    "command.execute",
    "turn.start",
    "turn.steer",
    "turn.interrupt",
    "approval.resolve",
    "question.resolve",
    "events.subscribe",
];

const SESSION_ID_OPERATIONS: &[&str] = &[
    "session.goal",
    "command.execute",
    "session.open",
    "session.read",
    "session.commands",
    "turn.start",
    "turn.steer",
    "turn.interrupt",
    "approval.resolve",
    "question.resolve",
];
const TURN_ID_OPERATIONS: &[&str] = &["turn.steer", "turn.interrupt"];
const MUTATING_OPERATIONS: &[&str] = &[
    "session.goal",
    "command.execute",
    "session.create",
    "session.open",
    "turn.start",
    "turn.steer",
    "turn.interrupt",
    "approval.resolve",
    "question.resolve",
];

#[derive(Debug, Clone, Error, PartialEq, Eq)]
#[error("{message}")]
pub struct BrokerError {
    pub code: String,
    pub message: String,
    pub outcome: String,
    pub retryable: bool,
}

impl BrokerError {
    pub fn rejected(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            message: sanitize_diagnostic(message.into()),
            outcome: "rejected".into(),
            retryable: false,
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct NormalizedBrokerRequest {
    pub protocol_version: u64,
    pub operation: String,
    pub client_operation_id: String,
    pub runtime_target_id: Option<String>,
    pub session_id: Option<String>,
    pub turn_id: Option<String>,
    pub payload: Value,
}

#[derive(Debug, Clone, PartialEq)]
pub struct ValidatedTurnInput {
    pub message: String,
    pub snapshots: Vec<Value>,
    pub images: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BoundedPage<T> {
    pub data: Vec<T>,
    pub next_cursor: Option<String>,
}

pub fn validate_broker_request(request: &Value) -> Result<NormalizedBrokerRequest, BrokerError> {
    let object = request.as_object().ok_or_else(|| {
        BrokerError::rejected("invalid-request", "Broker request must be an object.")
    })?;
    let protocol_version = object
        .get("protocolVersion")
        .and_then(Value::as_u64)
        .unwrap_or_default();
    if protocol_version != BROKER_PROTOCOL_VERSION {
        return Err(BrokerError::rejected(
            "unsupported-version",
            format!("Unsupported broker protocol version {protocol_version}."),
        ));
    }

    let operation = object
        .get("operation")
        .and_then(Value::as_str)
        .unwrap_or_default();
    if !BROKER_OPERATIONS.contains(&operation) {
        return Err(BrokerError::rejected(
            "unsupported-operation",
            format!(
                "Unsupported broker operation '{}'.",
                if operation.is_empty() {
                    "<missing>"
                } else {
                    operation
                }
            ),
        ));
    }

    let client_operation_id = normalize_client_operation_id(
        object.get("clientOperationId"),
        MUTATING_OPERATIONS.contains(&operation),
    )?;
    let payload = object.get("payload").cloned().unwrap_or_else(empty_object);
    if !payload.is_object() {
        return Err(BrokerError::rejected(
            "invalid-request",
            "Broker request payload must be an object.",
        ));
    }
    let runtime_target_id = optional_opaque_id(object.get("runtimeTargetId"), "runtimeTargetId")?;
    let session_id = optional_opaque_id(object.get("sessionId"), "sessionId")?;
    let turn_id = optional_opaque_id(object.get("turnId"), "turnId")?;
    let needs_target = ![
        "runtime.listTargets",
        "runtime.refreshTargets",
        "runtime.getStatus",
    ]
    .contains(&operation);
    if needs_target && runtime_target_id.is_none() {
        return Err(BrokerError::rejected(
            "invalid-request",
            format!("{operation} requires runtimeTargetId."),
        ));
    }
    if SESSION_ID_OPERATIONS.contains(&operation) && session_id.is_none() {
        return Err(BrokerError::rejected(
            "invalid-request",
            format!("{operation} requires sessionId."),
        ));
    }
    if TURN_ID_OPERATIONS.contains(&operation) && turn_id.is_none() {
        return Err(BrokerError::rejected(
            "invalid-request",
            format!("{operation} requires turnId."),
        ));
    }

    Ok(NormalizedBrokerRequest {
        protocol_version: BROKER_PROTOCOL_VERSION,
        operation: operation.into(),
        client_operation_id,
        runtime_target_id,
        session_id,
        turn_id,
        payload,
    })
}

pub fn validate_capabilities(values: &Value) -> Result<Vec<String>, BrokerError> {
    let capabilities = values.as_array().ok_or_else(|| {
        BrokerError::rejected("invalid-response", "Runtime capabilities must be an array.")
    })?;
    let pattern = Regex::new(r"^[a-z][a-z0-9]*(?:\.[a-z][a-z0-9]*)*\.v[1-9][0-9]*$")
        .expect("capability regex is valid");
    let mut seen = HashSet::new();
    let mut normalized = Vec::new();
    for capability in capabilities {
        let capability = js_string(capability);
        if !pattern.is_match(&capability) {
            return Err(BrokerError::rejected(
                "invalid-response",
                format!("Runtime emitted invalid capability '{capability}'."),
            ));
        }
        if seen.insert(capability.clone()) {
            normalized.push(capability);
        }
    }
    Ok(normalized)
}

pub fn validate_turn_input(
    message: &str,
    snapshots: &[Value],
    images: &[String],
) -> Result<ValidatedTurnInput, BrokerError> {
    let message = message.trim();
    if message.is_empty() {
        return Err(BrokerError::rejected(
            "invalid-request",
            "A message is required.",
        ));
    }
    if message.len() > MAX_TURN_MESSAGE_BYTES {
        return Err(BrokerError::rejected(
            "input-too-large",
            format!("Message exceeds {MAX_TURN_MESSAGE_BYTES} bytes."),
        ));
    }
    if snapshots.len() > MAX_CONTEXT_SNAPSHOTS {
        return Err(BrokerError::rejected(
            "input-too-large",
            format!("At most {MAX_CONTEXT_SNAPSHOTS} context snapshots may be sent."),
        ));
    }
    if images.len() > MAX_IMAGE_ATTACHMENTS {
        return Err(BrokerError::rejected(
            "input-too-large",
            format!("At most {MAX_IMAGE_ATTACHMENTS} images may be sent."),
        ));
    }

    let image_pattern = Regex::new(r"(?i)^data:image/[a-z0-9.+-]+;base64,([a-z0-9+/=\s]+)$")
        .expect("image data URL regex is valid");
    let mut total_image_bytes = 0;
    for image in images {
        let encoded = image_pattern
            .captures(image)
            .and_then(|captures| captures.get(1))
            .ok_or_else(|| {
                BrokerError::rejected(
                    "invalid-request",
                    "Image inputs must be base64 image data URLs.",
                )
            })?
            .as_str()
            .chars()
            .filter(|character| !character.is_whitespace())
            .collect::<String>();
        let image_bytes = base64::engine::general_purpose::STANDARD
            .decode(encoded)
            .map_err(|_| {
                BrokerError::rejected(
                    "invalid-request",
                    "Image inputs must be valid base64 image data URLs.",
                )
            })?
            .len();
        if image_bytes > MAX_IMAGE_BYTES {
            return Err(BrokerError::rejected(
                "input-too-large",
                format!("One image exceeds {MAX_IMAGE_BYTES} bytes."),
            ));
        }
        total_image_bytes += image_bytes;
    }
    if total_image_bytes > MAX_TOTAL_IMAGE_BYTES {
        return Err(BrokerError::rejected(
            "input-too-large",
            format!("Image inputs exceed {MAX_TOTAL_IMAGE_BYTES} bytes in total."),
        ));
    }

    Ok(ValidatedTurnInput {
        message: message.into(),
        snapshots: snapshots.to_vec(),
        images: images.to_vec(),
    })
}

pub fn operation_fingerprint(value: &Value) -> String {
    let encoded = serde_json::to_vec(value).expect("JSON values always serialize");
    format!("{:x}", Sha256::digest(encoded))
}

pub fn bounded_page<T: Clone>(
    values: &[T],
    cursor: Option<&str>,
    limit: usize,
    maximum: usize,
) -> Result<BoundedPage<T>, BrokerError> {
    let size = limit.clamp(1, maximum.max(1));
    let offset = decode_cursor(cursor)?;
    let data = values
        .iter()
        .skip(offset)
        .take(size)
        .cloned()
        .collect::<Vec<_>>();
    let next_cursor = (offset + data.len() < values.len())
        .then(|| URL_SAFE_NO_PAD.encode((offset + data.len()).to_string()));
    Ok(BoundedPage { data, next_cursor })
}

pub fn sanitize_diagnostic(value: impl Display) -> String {
    let mut message = value.to_string();
    let context = Regex::new(r"(?is)<zommi_invocation_context>.*?</zommi_invocation_context>")
        .expect("context regex is valid");
    message = context
        .replace_all(&message, "[context redacted]")
        .into_owned();
    let bearer = Regex::new(r"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]+").expect("bearer regex is valid");
    message = bearer
        .replace_all(&message, "Bearer [redacted]")
        .into_owned();
    let secret = Regex::new(
        r"(?i)\b(token|password|secret|api[_-]?key|authorization)(\s*[:=]\s*)([^\s,;]+)",
    )
    .expect("secret regex is valid");
    message = secret.replace_all(&message, "$1$2[redacted]").into_owned();
    truncate_utf8(&message, 2_000)
}

fn normalize_client_operation_id(
    value: Option<&Value>,
    required: bool,
) -> Result<String, BrokerError> {
    let id = value.filter(|value| !value.is_null()).map(js_string);
    if id.as_deref().is_none_or(str::is_empty) {
        if required {
            return Err(BrokerError::rejected(
                "invalid-request",
                "clientOperationId is required.",
            ));
        }
        return Ok(format!("zommi:{}", Uuid::new_v4()));
    }
    let id = id.expect("checked above");
    let pattern =
        Regex::new(r"(?i)^[a-z0-9][a-z0-9._:-]{7,127}$").expect("operation ID regex is valid");
    if !pattern.is_match(&id) {
        return Err(BrokerError::rejected(
            "invalid-request",
            "clientOperationId must be 8-128 safe opaque characters.",
        ));
    }
    Ok(id)
}

fn optional_opaque_id(value: Option<&Value>, name: &str) -> Result<Option<String>, BrokerError> {
    let Some(value) = value.filter(|value| !value.is_null()) else {
        return Ok(None);
    };
    let id = js_string(value);
    if id.is_empty() {
        return Ok(None);
    }
    if id.encode_utf16().count() > 512
        || id
            .chars()
            .any(|character| matches!(character, '\u{0000}'..='\u{001f}' | '\u{007f}'))
    {
        return Err(BrokerError::rejected(
            "invalid-request",
            format!("{name} is invalid."),
        ));
    }
    Ok(Some(id))
}

fn decode_cursor(cursor: Option<&str>) -> Result<usize, BrokerError> {
    let Some(cursor) = cursor.filter(|cursor| !cursor.is_empty()) else {
        return Ok(0);
    };
    let decoded = URL_SAFE_NO_PAD
        .decode(cursor)
        .map_err(|_| invalid_cursor())?;
    let value = String::from_utf8(decoded).map_err(|_| invalid_cursor())?;
    value.parse::<usize>().map_err(|_| invalid_cursor())
}

fn invalid_cursor() -> BrokerError {
    BrokerError::rejected("invalid-request", "Pagination cursor is invalid.")
}

fn empty_object() -> Value {
    Value::Object(serde_json::Map::new())
}

fn js_string(value: &Value) -> String {
    match value {
        Value::Null => String::new(),
        Value::String(value) => value.clone(),
        Value::Bool(value) => value.to_string(),
        Value::Number(value) => value.to_string(),
        other => serde_json::to_string(other).unwrap_or_default(),
    }
}

fn truncate_utf8(value: &str, maximum_length: usize) -> String {
    if value.len() <= maximum_length {
        return value.into();
    }
    let mut boundary = maximum_length;
    while !value.is_char_boundary(boundary) {
        boundary -= 1;
    }
    value[..boundary].into()
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::{
        BROKER_PROTOCOL_VERSION, BrokerError, bounded_page, operation_fingerprint,
        sanitize_diagnostic, validate_broker_request, validate_capabilities, validate_turn_input,
    };

    #[test]
    fn requires_supported_version_operation_and_mutation_identity() {
        let unsupported = validate_broker_request(&json!({
            "protocolVersion": 99,
            "operation": "runtime.listTargets"
        }))
        .expect_err("version must be rejected");
        assert_eq!(unsupported.code, "unsupported-version");

        let missing_identity = validate_broker_request(&json!({
            "protocolVersion": BROKER_PROTOCOL_VERSION,
            "operation": "turn.start",
            "payload": {"message": "hello"}
        }))
        .expect_err("mutation identity must be rejected");
        assert_eq!(missing_identity.code, "invalid-request");

        let request = validate_broker_request(&json!({
            "protocolVersion": BROKER_PROTOCOL_VERSION,
            "operation": "turn.start",
            "clientOperationId": "client:operation-1",
            "runtimeTargetId": "target-a",
            "sessionId": "session-a",
            "payload": {"message": "hello"}
        }))
        .expect("valid turn request");
        assert_eq!(request.client_operation_id, "client:operation-1");
        assert_eq!(request.runtime_target_id.as_deref(), Some("target-a"));
        assert_eq!(request.session_id.as_deref(), Some("session-a"));
    }

    #[test]
    fn validates_context_and_image_bounds() {
        let valid = validate_turn_input(
            "hello",
            &[json!({"snapshotId": "a"})],
            &["data:image/png;base64,aGVsbG8=".into()],
        )
        .expect("valid turn input");
        assert_eq!(valid.message, "hello");
        assert_eq!(
            validate_turn_input("hello", &vec![json!({}); 17], &[])
                .expect_err("too many snapshots")
                .code,
            "input-too-large"
        );
        assert_eq!(
            validate_turn_input("hello", &[], &["https://example.test/not-an-image".into()])
                .expect_err("invalid image")
                .code,
            "invalid-request"
        );
    }

    #[test]
    fn bounds_pages_and_rejects_forged_cursors() {
        let first = bounded_page(&["a", "b", "c"], None, 2, 200).expect("first page");
        assert_eq!(first.data, ["a", "b"]);
        let second = bounded_page(&["a", "b", "c"], first.next_cursor.as_deref(), 2, 200)
            .expect("second page");
        assert_eq!(second.data, ["c"]);
        assert!(second.next_cursor.is_none());
        assert_eq!(
            bounded_page(&["a"], Some("not-a-cursor"), 2, 200)
                .expect_err("forged cursor")
                .code,
            "invalid-request"
        );
    }

    #[test]
    fn redacts_runtime_diagnostics() {
        let message = sanitize_diagnostic(
            "Bearer abc.def token=private <zommi_invocation_context>screen secret</zommi_invocation_context> failed",
        );
        assert!(!message.contains("abc.def"));
        assert!(!message.contains("private"));
        assert!(!message.contains("screen secret"));
        assert!(message.contains("Bearer [redacted]"));
    }

    #[test]
    fn validates_and_deduplicates_capabilities() {
        assert_eq!(
            validate_capabilities(&json!(["turn.stream.v1", "turn.stream.v1"]))
                .expect("valid capabilities"),
            ["turn.stream.v1"]
        );
        assert_eq!(
            validate_capabilities(&json!(["turn.stream"]))
                .expect_err("unversioned capability")
                .code,
            "invalid-response"
        );
    }

    #[test]
    fn fingerprints_are_stable() {
        assert_eq!(
            operation_fingerprint(&json!({"operation": "turn.start", "id": 1})),
            operation_fingerprint(&json!({"operation": "turn.start", "id": 1}))
        );
    }

    #[test]
    fn broker_error_is_an_error() {
        let error = BrokerError::rejected("invalid-request", "bad request");
        assert_eq!(error.to_string(), "bad request");
    }
}
