use serde_json::Value;

use crate::codex_adapter::CodexError;

pub(crate) fn error(message: impl Into<String>) -> CodexError {
    CodexError {
        code: "history-changed".into(),
        message: message.into(),
        retryable: false,
    }
}

pub(crate) fn turns(history: &Value) -> Result<&Vec<Value>, CodexError> {
    history
        .pointer("/thread/turns")
        .and_then(Value::as_array)
        .ok_or_else(|| error("The runtime did not return authoritative chat history."))
}

pub(crate) fn target(history: &Value, turn_id: &str, last_id: &str) -> Result<usize, CodexError> {
    let turns = turns(history)?;
    if turns.last().and_then(|turn| turn["id"].as_str()) != Some(last_id) {
        return Err(error(
            "The chat changed. Reopen it before editing an earlier message.",
        ));
    }
    turns
        .iter()
        .position(|turn| turn["id"].as_str() == Some(turn_id))
        .ok_or_else(|| error("The edited message is no longer in this chat."))
}

pub(crate) fn verify_prefix(before: &Value, after: &Value, index: usize) -> Result<(), CodexError> {
    let before = turns(before)?;
    let after = turns(after)?;
    if after.len() != index
        || after
            .iter()
            .zip(&before[..index])
            .any(|(a, b)| a["id"] != b["id"])
    {
        return Err(error(
            "Could not verify the rewound history. Reopen the chat before resending.",
        ));
    }
    Ok(())
}
