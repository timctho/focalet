use crate::{
    AppResult,
    geometry::{Bounds, accessibility_origin},
};
use atspi::proxy::{
    accessible::ObjectRefExt, application::ApplicationProxy, component::ComponentProxy,
    text::TextProxy,
};
use atspi::{AccessibilityConnection, CoordType, Interface, Role, State};
use serde_json::{Value, json};
use std::collections::HashSet;
use std::time::{Duration, Instant};

pub(crate) async fn read_accessibility(source: &Value, region: Bounds) -> Value {
    match tokio::time::timeout(
        Duration::from_millis(1200),
        accessible_region(source, region),
    )
    .await
    {
        Ok(Ok(value)) => value,
        Ok(Err(error)) => {
            eprintln!("Wayland accessibility unavailable: {error}");
            json!({"limitation": "AT-SPI accessibility is unavailable for this application. Enable accessibility support and retry."})
        }
        Err(_) => {
            json!({"limitation": "The application's accessibility provider timed out. The image is still available."})
        }
    }
}

async fn accessible_region(source: &Value, region: Bounds) -> AppResult<Value> {
    let started = Instant::now();
    let connection = AccessibilityConnection::new().await?;
    let bus = connection.connection();
    let dbus = atspi::zbus::fdo::DBusProxy::new(bus).await?;
    let root = connection.root_accessible_on_registry().await?;
    let mut matching = Vec::new();
    let buffer: Bounds = serde_json::from_value(source["bufferBounds"].clone())?;
    let frame: Bounds = serde_json::from_value(source["bounds"].clone())?;
    for app in root.get_children().await?.into_iter().take(128) {
        let Some(name) = app.name() else {
            continue;
        };
        let accessible = app.as_accessible_proxy(bus).await?;
        let bus_pid = dbus
            .get_connection_unix_process_id(name.clone().into())
            .await
            .ok()
            .map(u64::from);
        let raw =
            atspi::zbus::Proxy::new(bus, name.clone(), app.path(), "org.a11y.atspi.Accessible")
                .await?;
        let app_pid = raw
            .call::<_, _, u32>("GetProcessId", &())
            .await
            .ok()
            .map(u64::from);
        if bus_pid != source["processId"].as_u64() && app_pid != source["processId"].as_u64() {
            continue;
        }
        let application = ApplicationProxy::builder(bus)
            .destination(name.clone())?
            .path(app.path())?
            .build()
            .await?;
        let toolkit = application.toolkit_name().await.unwrap_or_default();
        let version = application.version().await.unwrap_or_default();
        let gtk4 = toolkit.eq_ignore_ascii_case("gtk") && version.starts_with("4.");
        for window in accessible.get_children().await?.into_iter().take(128) {
            let accessible = window.as_accessible_proxy(bus).await?;
            let component = ComponentProxy::builder(bus)
                .destination(window.name().ok_or("missing bus name")?.clone())?
                .path(window.path())?
                .build()
                .await?;
            let Ok((x, y, w, h)) = component.get_extents(CoordType::Window).await else {
                continue;
            };
            let bounds = Bounds {
                x: x.into(),
                y: y.into(),
                width: w.into(),
                height: h.into(),
            };
            // GTK 3 includes the shadow buffer; GTK 4 uses the window frame.
            // Bind only a unique matching geometry, never AT-SPI's fake screen origin.
            if let Some(native) = accessibility_origin(bounds, frame, buffer)
                && accessible.name().await.unwrap_or_default()
                    == source["windowTitle"].as_str().unwrap_or("")
            {
                let guard_text = gtk4
                    || ((toolkit.is_empty() || version.is_empty())
                        && native == frame
                        && frame != buffer);
                matching.push((window, native, guard_text));
            }
        }
    }
    if matching.len() != 1 {
        return Err("No unique accessibility window matches the native window".into());
    }
    let (window, native, guard_text) = matching.remove(0);
    let mut stack = vec![(window, None::<String>, 0usize)];
    let mut seen = HashSet::new();
    let mut elements = Vec::new();
    let mut viewport = None;
    let mut text_budget = 24_000usize;
    let mut truncated = false;
    let mut omitted_text = false;
    while let Some((object, parent, depth)) = stack.pop() {
        if seen.len() >= 800
            || elements.len() >= 128
            || started.elapsed() > Duration::from_millis(900)
            || text_budget == 0
        {
            truncated = true;
            break;
        }
        if object.is_null() || !seen.insert(object.clone()) || depth > 40 {
            continue;
        }
        let accessible = object.as_accessible_proxy(bus).await?;
        let role = accessible.get_role().await?;
        // GTK 4 exposes legacy masked GtkEntry controls as ordinary Text and
        // GetText returns their raw value without a protected attribute. The
        // same interface cannot distinguish those controls from visible inputs.
        if guard_text && role == Role::Text {
            omitted_text = true;
            continue;
        }
        let state = accessible.get_state().await?;
        if role == Role::PasswordText
            || state.contains(State::Defunct)
            || !state.contains(State::Showing)
            || !state.contains(State::Visible)
        {
            continue;
        }
        let interfaces = accessible.get_interfaces().await?;
        let mut retained_parent = parent.clone();
        if interfaces.contains(Interface::Component) {
            let component = ComponentProxy::builder(bus)
                .destination(object.name().ok_or("missing bus name")?.clone())?
                .path(object.path())?
                .build()
                .await?;
            if let Ok((x, y, w, h)) = component.get_extents(CoordType::Window).await {
                let bounds = Bounds {
                    x: native.x + f64::from(x),
                    y: native.y + f64::from(y),
                    width: w.into(),
                    height: h.into(),
                };
                if role == Role::DocumentWeb && bounds.contains(region) {
                    viewport = Some(bounds);
                }
                if w > 0 && h > 0 && bounds.intersects(region) {
                    let name = accessible.name().await.unwrap_or_default();
                    let description = accessible.description().await.unwrap_or_default();
                    let id = format!("atspi-{}", elements.len());
                    let mut text = String::new();
                    if interfaces.contains(Interface::Text)
                        && !matches!(
                            role,
                            Role::DocumentWeb
                                | Role::Frame
                                | Role::Panel
                                | Role::ScrollPane
                                | Role::RootPane
                        )
                    {
                        let proxy = TextProxy::builder(bus)
                            .destination(object.name().ok_or("missing bus name")?.clone())?
                            .path(object.path())?
                            .build()
                            .await?;
                        text = proxy
                            .get_text(0, (text_budget.min(4000)) as i32)
                            .await
                            .unwrap_or_default();
                    }
                    let mut clip = |value: String| {
                        let text: String = value.chars().take(text_budget.min(4000)).collect();
                        if text.len() < value.len() {
                            truncated = true;
                        }
                        text_budget = text_budget.saturating_sub(text.chars().count());
                        text
                    };
                    let name = clip(name);
                    let description = clip(description);
                    let text = clip(text);
                    let mut native_ids = json!({"objectPath": object.path().as_str()});
                    if let Ok(value) = accessible.accessible_id().await
                        && !value.is_empty()
                        && value.len() <= 256
                    {
                        native_ids["accessibleId"] = json!(value);
                    }
                    elements.push(json!({"id": id, "parentId": parent, "provider": "atspi", "nativeIds": native_ids,
                        "role": format!("{role:?}"), "name": name, "text": text, "description": description,
                        "state": {"enabled": state.contains(State::Enabled), "focused": state.contains(State::Focused),
                          "selected": state.contains(State::Selected), "editable": state.contains(State::Editable),
                          "toggle": if state.contains(State::Checkable) || matches!(role, Role::CheckBox | Role::RadioButton | Role::ToggleButton) { Some(if state.contains(State::Indeterminate) { "mixed" } else if state.contains(State::Checked) { "on" } else { "off" }) } else { None },
                          "expanded": if state.contains(State::Expandable) { Some(if state.contains(State::Expanded) { "expanded" } else { "collapsed" }) } else { None }},
                        "bounds": bounds.relative_to(region), "visibleBounds": bounds.intersect(region).relative_to(region),
                        "relation": if region.contains(bounds) {"inside"} else {"intersects"}}));
                    retained_parent = Some(id);
                }
            }
        }
        let children = accessible.get_children().await?;
        if children.len() > 800 {
            truncated = true;
        }
        for child in children.into_iter().take(800).rev() {
            stack.push((child, retained_parent.clone(), depth + 1));
        }
    }
    Ok(
        json!({"regionContext": {"version": 1, "selectionKind": "bbox", "coordinateSpace": "region-logical", "elements": elements, "truncated": truncated},
        "browserViewport": viewport, "limitation": if omitted_text {
            "Text input values were omitted because this accessibility provider cannot reliably distinguish masked fields. Labels, controls and the original image remain available."
        } else { "Captured AT-SPI accessibility. Intersecting elements may expose labels beyond the crop; the image is the selected content." }}),
    )
}
