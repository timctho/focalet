use base64::Engine as _;
use regex::Regex;
use serde_json::{Value, json};

const MAX_INLINE_IMAGE_CHARS: usize = 36 * 1024 * 1024;
const MAX_INLINE_HTML_CHARS: usize = 5 * 1024 * 1024;
const MAX_ARTIFACTS: usize = 50;

pub fn artifacts_from_thread_item(item: &Value, cwd: Option<&str>) -> Vec<Value> {
    let mut artifacts = Vec::new();
    for artifact in item
        .get("artifacts")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        add_artifact(&mut artifacts, artifact.clone(), cwd);
    }

    let item_type = item.get("type").and_then(Value::as_str).unwrap_or_default();
    if item_type == "imageGeneration"
        && item
            .get("failure")
            .is_none_or(|failure| failure.is_null() || failure.as_bool() == Some(false))
    {
        let path = path_text(item.get("savedPath"));
        let data_url = item.get("result").and_then(|value| {
            normalize_image_data_url(value_string(value), mime_type_for_path(&path))
        });
        if data_url.is_some() || !path.is_empty() {
            add_artifact(
                &mut artifacts,
                json!({
                    "id": format!("{}:image", item_id(item, "image-generation")),
                    "kind": "image",
                    "title": "Generated image",
                    "dataUrl": data_url,
                    "path": nonempty_value(path)
                }),
                cwd,
            );
        }
    }

    if item_type == "fileChange"
        && !item
            .get("status")
            .and_then(Value::as_str)
            .is_some_and(|status| {
                let lower = status.to_ascii_lowercase();
                ["failed", "declined", "cancelled", "canceled"]
                    .iter()
                    .any(|value| lower.contains(value))
            })
    {
        for change in item
            .get("changes")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
        {
            if change
                .get("kind")
                .and_then(Value::as_str)
                .is_some_and(|kind| {
                    let lower = kind.to_ascii_lowercase();
                    lower.contains("delete") || lower.contains("remove")
                })
            {
                continue;
            }
            let path = path_text(change.get("path"));
            if let Some(kind) = artifact_kind_from_path(&path) {
                add_artifact(
                    &mut artifacts,
                    json!({
                        "id": format!("{}:{path}", value_string(item.get("id").unwrap_or(&Value::Null))),
                        "kind": kind,
                        "title": artifact_title(kind),
                        "path": path
                    }),
                    cwd,
                );
            }
        }
    }

    if item_type == "dynamicToolCall" {
        collect_content_artifacts(
            item.get("contentItems"),
            &mut artifacts,
            cwd,
            &format!("{}:content", item_id(item, "dynamic-tool")),
            0,
        );
    }
    if item_type == "mcpToolCall" {
        collect_content_artifacts(
            item.pointer("/result/content"),
            &mut artifacts,
            cwd,
            &format!("{}:content", item_id(item, "mcp-tool")),
            0,
        );
        collect_structured_artifacts(
            item.pointer("/result/structuredContent"),
            &mut artifacts,
            cwd,
            &format!("{}:structured", item_id(item, "mcp-tool")),
            0,
        );
    }
    if item_type == "agentMessage" {
        for artifact in artifacts_from_text(
            item.get("text").and_then(Value::as_str).unwrap_or_default(),
            cwd,
        ) {
            add_artifact(&mut artifacts, artifact, cwd);
        }
    }
    artifacts
}

pub fn artifacts_from_content(content: Option<&Value>, cwd: Option<&str>) -> Vec<Value> {
    let mut artifacts = Vec::new();
    collect_content_artifacts(content, &mut artifacts, cwd, "content", 0);
    artifacts
}

pub fn artifacts_from_text(text: &str, cwd: Option<&str>) -> Vec<Value> {
    let mut artifacts = Vec::new();
    let markdown = Regex::new(
        r#"(?i)(!?)\[([^\]]*)\]\(\s*(?:<([^>]+)>|([^\s)]+))(?:\s+["'][^"']*["'])?\s*\)"#,
    )
    .expect("artifact markdown regex");
    for captures in markdown.captures_iter(text) {
        let path = captures
            .get(3)
            .or_else(|| captures.get(4))
            .map(|value| value.as_str())
            .unwrap_or_default();
        let title = captures
            .get(2)
            .map(|value| value.as_str())
            .unwrap_or_default();
        add_path_artifact(&mut artifacts, path, title, cwd);
    }
    let bare_path = Regex::new(
        r#"(?i)(?:^|[\s("'`])((?:file:///[^\s"'<>]+|[a-z]:[\\/][^\s"'<>]+|/[^\s"'<>]+)\.(?:png|jpe?g|gif|webp|bmp|svg|html?))(?:$|[\s),.;])"#,
    )
    .expect("artifact path regex");
    for captures in bare_path.captures_iter(text) {
        if let Some(path) = captures.get(1) {
            add_path_artifact(&mut artifacts, path.as_str(), "", cwd);
        }
    }
    artifacts
}

pub fn artifact_kind_from_path(value: &str) -> Option<&'static str> {
    let clean = value
        .split(['?', '#'])
        .next()
        .unwrap_or_default()
        .to_ascii_lowercase();
    let extension = clean.rsplit_once('.').map(|(_, value)| value)?;
    match extension {
        "png" | "jpg" | "jpeg" | "gif" | "webp" | "bmp" | "svg" => Some("image"),
        "html" | "htm" => Some("html"),
        _ => None,
    }
}

fn collect_content_artifacts(
    content: Option<&Value>,
    artifacts: &mut Vec<Value>,
    cwd: Option<&str>,
    prefix: &str,
    depth: usize,
) {
    if depth > 4 || artifacts.len() >= MAX_ARTIFACTS {
        return;
    }
    let Some(content) = content else { return };
    let values: Vec<&Value> = match content {
        Value::Array(values) => values.iter().take(MAX_ARTIFACTS).collect(),
        Value::Object(_) => vec![content],
        _ => return,
    };
    for (index, block) in values.into_iter().enumerate() {
        if artifacts.len() >= MAX_ARTIFACTS {
            return;
        }
        if block.get("content").is_some_and(Value::is_object) {
            collect_content_artifacts(
                block.get("content"),
                artifacts,
                cwd,
                &format!("{prefix}:{index}:nested"),
                depth + 1,
            );
        }
        let kind = block
            .get("type")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_ascii_lowercase();
        let image_value = block
            .get("imageUrl")
            .or_else(|| block.get("image_url"))
            .and_then(Value::as_str);
        if matches!(kind.as_str(), "inputimage" | "input_image") {
            if let Some(image_value) = image_value {
                if let Some(data_url) = normalize_image_data_url(image_value, "image/png") {
                    add_artifact(
                        artifacts,
                        json!({"id": format!("{prefix}:{index}"), "kind": "image", "title": "Generated image", "dataUrl": data_url}),
                        cwd,
                    );
                } else if artifact_kind_from_path(image_value) == Some("image") {
                    add_artifact(
                        artifacts,
                        json!({"id": format!("{prefix}:{index}"), "kind": "image", "title": "Generated image", "path": image_value}),
                        cwd,
                    );
                }
            }
            continue;
        }
        if kind == "image" {
            if let Some(data) = block.get("data").and_then(Value::as_str) {
                let mime = block
                    .get("mimeType")
                    .or_else(|| block.get("mime_type"))
                    .and_then(Value::as_str)
                    .unwrap_or("image/png");
                if let Some(data_url) = normalize_image_data_url(data, mime) {
                    add_artifact(
                        artifacts,
                        json!({"id": format!("{prefix}:{index}"), "kind": "image", "title": "Generated image", "dataUrl": data_url}),
                        cwd,
                    );
                }
            }
            continue;
        }
        if kind == "resource_link" {
            let path = path_text(block.get("uri"));
            if let Some(artifact_kind) = artifact_kind_from_path(&path) {
                add_artifact(
                    artifacts,
                    json!({
                        "id": format!("{prefix}:{index}"), "kind": artifact_kind,
                        "title": block.get("title").or_else(|| block.get("name")), "path": path
                    }),
                    cwd,
                );
            }
            continue;
        }
        if kind == "resource"
            && let Some(resource) = block.get("resource")
        {
            let mime = resource
                .get("mimeType")
                .or_else(|| resource.get("mime_type"))
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_ascii_lowercase();
            let path = path_text(resource.get("uri"));
            if mime == "text/html" {
                if let Some(html) = resource
                    .get("text")
                    .and_then(Value::as_str)
                    .filter(|html| html.len() <= MAX_INLINE_HTML_CHARS)
                {
                    add_artifact(
                        artifacts,
                        json!({"id": format!("{prefix}:{index}"), "kind": "html", "title": "HTML preview", "html": html, "path": nonempty_value(path)}),
                        cwd,
                    );
                }
            } else if mime.starts_with("image/")
                && let Some(blob) = resource.get("blob").and_then(Value::as_str)
                && let Some(data_url) = normalize_image_data_url(blob, &mime)
            {
                add_artifact(
                    artifacts,
                    json!({"id": format!("{prefix}:{index}"), "kind": "image", "title": "Generated image", "dataUrl": data_url, "path": nonempty_value(path)}),
                    cwd,
                );
            }
        }
    }
}

fn collect_structured_artifacts(
    value: Option<&Value>,
    artifacts: &mut Vec<Value>,
    cwd: Option<&str>,
    prefix: &str,
    depth: usize,
) {
    if depth > 3 || artifacts.len() >= MAX_ARTIFACTS {
        return;
    }
    let Some(value) = value else { return };
    if let Some(values) = value.as_array() {
        for (index, entry) in values.iter().take(MAX_ARTIFACTS).enumerate() {
            collect_structured_artifacts(
                Some(entry),
                artifacts,
                cwd,
                &format!("{prefix}:{index}"),
                depth + 1,
            );
        }
        return;
    }
    let Some(object) = value.as_object() else {
        return;
    };
    if let Some(image) = object
        .get("image_url")
        .or_else(|| object.get("imageUrl"))
        .and_then(Value::as_str)
        .and_then(|value| normalize_image_data_url(value, "image/png"))
    {
        add_artifact(
            artifacts,
            json!({"id": format!("{prefix}:image"), "kind": "image", "title": "Generated image", "dataUrl": image}),
            cwd,
        );
    }
    let path = ["output_hint", "outputHint", "path", "uri"]
        .into_iter()
        .find_map(|name| object.get(name).and_then(Value::as_str))
        .unwrap_or_default();
    if let Some(kind) = artifact_kind_from_path(path) {
        add_artifact(
            artifacts,
            json!({"id": format!("{prefix}:path"), "kind": kind, "title": artifact_title(kind), "path": path}),
            cwd,
        );
    }
    for (key, entry) in object.iter().take(MAX_ARTIFACTS) {
        if [
            "image_url",
            "imageUrl",
            "output_hint",
            "outputHint",
            "path",
            "uri",
        ]
        .contains(&key.as_str())
        {
            continue;
        }
        collect_structured_artifacts(
            Some(entry),
            artifacts,
            cwd,
            &format!("{prefix}:{key}"),
            depth + 1,
        );
    }
}

fn add_path_artifact(artifacts: &mut Vec<Value>, path: &str, title: &str, cwd: Option<&str>) {
    let path = path.trim();
    if path.is_empty() {
        return;
    }
    if let Some(data_url) = normalize_image_data_url(path, "image/png") {
        add_artifact(
            artifacts,
            json!({"id": format!("message:{path}"), "kind": "image", "title": if title.is_empty() { "Generated image" } else { title }, "dataUrl": data_url}),
            cwd,
        );
        return;
    }
    if path.to_ascii_lowercase().starts_with("http:")
        || path.to_ascii_lowercase().starts_with("https:")
    {
        return;
    }
    if let Some(kind) = artifact_kind_from_path(path) {
        add_artifact(
            artifacts,
            json!({"id": format!("message:{path}"), "kind": kind, "title": if title.is_empty() { artifact_title(kind) } else { title }, "path": path}),
            cwd,
        );
    }
}

fn add_artifact(artifacts: &mut Vec<Value>, artifact: Value, cwd: Option<&str>) {
    if artifacts.len() >= MAX_ARTIFACTS {
        return;
    }
    let Some(mut object) = artifact.as_object().cloned() else {
        return;
    };
    let Some(kind) = object.get("kind").and_then(Value::as_str) else {
        return;
    };
    if !matches!(kind, "image" | "html")
        || !["dataUrl", "path", "html"].iter().any(|name| {
            object
                .get(*name)
                .and_then(Value::as_str)
                .is_some_and(|value| !value.is_empty())
        })
    {
        return;
    }
    if object
        .get("path")
        .and_then(Value::as_str)
        .is_some_and(|path| path.len() > 4_096)
    {
        return;
    }
    let title = object
        .get("title")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| artifact_title(kind));
    object.insert("title".into(), Value::String(truncate_chars(title, 160)));
    if !object.contains_key("cwd")
        && let Some(cwd) = cwd.filter(|value| !value.is_empty())
    {
        object.insert("cwd".into(), Value::String(cwd.into()));
    }
    object.retain(|_, value| !value.is_null());
    let identity = ["path", "dataUrl", "id"]
        .into_iter()
        .find_map(|name| object.get(name).and_then(Value::as_str))
        .unwrap_or_default();
    if identity.is_empty()
        || artifacts.iter().any(|existing| {
            ["path", "dataUrl", "id"]
                .into_iter()
                .any(|name| existing.get(name).and_then(Value::as_str) == Some(identity))
        })
    {
        return;
    }
    artifacts.push(Value::Object(object));
}

fn normalize_image_data_url(value: &str, fallback_mime: &str) -> Option<String> {
    let value = value.trim();
    if value.is_empty() || value.len() > MAX_INLINE_IMAGE_CHARS {
        return None;
    }
    let data_url =
        Regex::new(r"(?i)^data:image/[a-z0-9.+-]+(?:;[a-z0-9=.+-]+)*;base64,[a-z0-9+/=\s]+$")
            .expect("image data URL regex");
    if data_url.is_match(value) {
        return Some(value.into());
    }
    let compact = value
        .chars()
        .filter(|character| !character.is_whitespace())
        .collect::<String>();
    if compact.len() % 4 != 0
        || base64::engine::general_purpose::STANDARD
            .decode(&compact)
            .is_err()
    {
        return None;
    }
    Some(format!(
        "data:{};base64,{compact}",
        fallback_mime.to_ascii_lowercase()
    ))
}

fn mime_type_for_path(value: &str) -> &'static str {
    let lower = value.to_ascii_lowercase();
    if lower.ends_with(".jpg") || lower.ends_with(".jpeg") {
        "image/jpeg"
    } else if lower.ends_with(".gif") {
        "image/gif"
    } else if lower.ends_with(".webp") {
        "image/webp"
    } else if lower.ends_with(".bmp") {
        "image/bmp"
    } else if lower.ends_with(".svg") {
        "image/svg+xml"
    } else {
        "image/png"
    }
}

fn item_id<'a>(item: &'a Value, fallback: &'a str) -> &'a str {
    item.get("id")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .unwrap_or(fallback)
}

fn artifact_title(kind: &str) -> &'static str {
    if kind == "html" {
        "HTML preview"
    } else {
        "Generated image"
    }
}

fn path_text(value: Option<&Value>) -> String {
    value
        .and_then(Value::as_str)
        .map(str::trim)
        .unwrap_or_default()
        .into()
}

fn value_string(value: &Value) -> &str {
    value.as_str().unwrap_or_default()
}

fn nonempty_value(value: String) -> Value {
    if value.is_empty() {
        Value::Null
    } else {
        Value::String(value)
    }
}

fn truncate_chars(value: &str, maximum: usize) -> String {
    value.chars().take(maximum).collect()
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::{artifacts_from_content, artifacts_from_text, artifacts_from_thread_item};

    #[test]
    fn extracts_generated_images_and_previewable_file_changes() {
        let image = artifacts_from_thread_item(
            &json!({
                "id": "image-1", "type": "imageGeneration", "status": "completed",
                "savedPath": "/workspace/generated/result.webp", "result": "aGVsbG8="
            }),
            Some("/workspace"),
        );
        assert_eq!(image[0]["kind"], "image");
        assert_eq!(image[0]["path"], "/workspace/generated/result.webp");
        assert_eq!(image[0]["dataUrl"], "data:image/webp;base64,aGVsbG8=");
        assert_eq!(image[0]["cwd"], "/workspace");

        let changes = artifacts_from_thread_item(
            &json!({
                "id": "change-1", "type": "fileChange", "status": "completed",
                "changes": [
                    {"kind": "update", "path": "preview.html"},
                    {"kind": "create", "path": "chart.png"},
                    {"kind": "delete", "path": "old.png"},
                    {"kind": "update", "path": "notes.txt"}
                ]
            }),
            Some("/workspace"),
        );
        assert_eq!(changes.len(), 2);
        assert_eq!(changes[0]["kind"], "html");
        assert_eq!(changes[1]["kind"], "image");
    }

    #[test]
    fn extracts_nested_content_and_safe_local_message_links() {
        let content = artifacts_from_content(
            Some(&json!([
                {"type": "image", "mimeType": "image/png", "data": "aGVsbG8="},
                {"type": "resource", "resource": {"uri": "demo.html", "mimeType": "text/html", "text": "<h1>safe</h1>"}}
            ])),
            Some("/workspace"),
        );
        assert_eq!(content.len(), 2);
        assert_eq!(content[0]["dataUrl"], "data:image/png;base64,aGVsbG8=");
        assert_eq!(content[1]["html"], "<h1>safe</h1>");

        let links = artifacts_from_text(
            "See [demo](./demo.html), ![chart](/tmp/chart.png), and [remote](https://example.test/remote.png).",
            Some("/workspace"),
        );
        assert_eq!(links.len(), 2);
        assert_eq!(links[0]["path"], "./demo.html");
        assert_eq!(links[1]["path"], "/tmp/chart.png");
    }

    #[test]
    fn extracts_structured_mcp_output_without_duplicates() {
        let artifacts = artifacts_from_thread_item(
            &json!({
                "id": "mcp-1", "type": "mcpToolCall",
                "result": {
                    "content": [{"type": "resource_link", "uri": "report.html", "title": "Report"}],
                    "structuredContent": {"output_hint": "report.html", "image_url": "data:image/png;base64,aGVsbG8="}
                }
            }),
            None,
        );
        assert_eq!(artifacts.len(), 2);
        assert_eq!(artifacts[0]["path"], "report.html");
        assert_eq!(artifacts[1]["kind"], "image");
    }
}
