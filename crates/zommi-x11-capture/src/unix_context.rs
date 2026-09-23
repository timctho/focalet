use super::*;
use atspi::proxy::{accessible::ObjectRefExt, component::ComponentProxy, text::TextProxy};
use atspi::{AccessibilityConnection, CoordType, Interface, Role, State};
use base64::{Engine, engine::general_purpose::STANDARD};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::time::Instant;
use x11rb::protocol::xproto::MapState;

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq)]
pub(super) struct Bounds {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
}
impl Bounds {
    fn intersects(self, other: Self) -> bool {
        self.x < other.x + other.width
            && other.x < self.x + self.width
            && self.y < other.y + other.height
            && other.y < self.y + self.height
    }
    fn contains(self, other: Self) -> bool {
        other.width > 0.0
            && other.height > 0.0
            && other.x >= self.x
            && other.y >= self.y
            && other.x + other.width <= self.x + self.width
            && other.y + other.height <= self.y + self.height
    }
    fn intersect(self, other: Self) -> Self {
        let x = self.x.max(other.x);
        let y = self.y.max(other.y);
        Self {
            x,
            y,
            width: (self.x + self.width).min(other.x + other.width) - x,
            height: (self.y + self.height).min(other.y + other.height) - y,
        }
    }
    fn relative_to(self, region: Self) -> Self {
        Self {
            x: self.x - region.x,
            y: self.y - region.y,
            ..self
        }
    }
}

fn capture_bytes(
    connection: &RustConnection,
    screen: &x11rb::protocol::xproto::Screen,
    bounds: Bounds,
) -> AppResult<Vec<u8>> {
    if ![bounds.x, bounds.y, bounds.width, bounds.height]
        .iter()
        .all(|value| value.is_finite() && value.fract() == 0.0)
        || !(Bounds {
            x: 0.0,
            y: 0.0,
            width: screen.width_in_pixels.into(),
            height: screen.height_in_pixels.into(),
        })
        .contains(bounds)
        || bounds.width * bounds.height > 64_000_000.0
    {
        return Err("Invalid or oversized screen region".into());
    }
    let (width, height) = (bounds.width as u16, bounds.height as u16);
    let (image, visual) = Image::get(
        connection,
        screen.root,
        bounds.x as i16,
        bounds.y as i16,
        width,
        height,
    )?;
    let layout = PixelLayout::from_visual_type(find_visual(
        connection,
        if visual == 0 {
            screen.root_visual
        } else {
            visual
        },
    )?)?;
    let mut rgb = Vec::with_capacity(width as usize * height as usize * 3);
    for y in 0..height {
        for x in 0..width {
            let (r, g, b) = layout.decode(image.get_pixel(x, y));
            rgb.extend_from_slice(&[(r >> 8) as u8, (g >> 8) as u8, (b >> 8) as u8]);
        }
    }
    let mut png = Vec::new();
    {
        let mut encoder = png::Encoder::new(&mut png, width.into(), height.into());
        encoder.set_color(png::ColorType::Rgb);
        encoder.set_depth(png::BitDepth::Eight);
        encoder.write_header()?.write_image_data(&rgb)?;
    }
    Ok(png)
}

pub(super) fn client_window(connection: &RustConnection, window: Window) -> AppResult<Window> {
    let pid_atom = atom(connection, b"_NET_WM_PID")?;
    let mut pending = vec![(window, 0)];
    let mut visited = 0;
    while let Some((candidate, depth)) = pending.pop() {
        visited += 1;
        if visited > 512 {
            break;
        }
        if property_u32(connection, candidate, pid_atom, AtomEnum::CARDINAL.into())?.is_some() {
            return Ok(candidate);
        }
        if depth >= 8 {
            continue;
        }
        // Reparenting window managers can add dozens of decoration children.
        // Search topmost children first with a total budget, rather than cutting
        // off before the real application window at the end of the child list.
        let children = connection.query_tree(candidate)?.reply()?.children;
        let available = 512_usize.saturating_sub(visited + pending.len());
        pending.extend(
            children
                .into_iter()
                .rev()
                .take(available)
                .map(|child| (child, depth + 1))
                .collect::<Vec<_>>()
                .into_iter()
                .rev(),
        );
    }
    Ok(window)
}

fn windows(connection: &RustConnection, root: Window) -> AppResult<Vec<Value>> {
    let mut result = Vec::new();
    for window in connection
        .query_tree(root)?
        .reply()?
        .children
        .into_iter()
        .rev()
        .take(512)
    {
        let read = || -> AppResult<Value> {
            if connection.get_window_attributes(window)?.reply()?.map_state != MapState::VIEWABLE {
                return Err("not visible".into());
            }
            let geometry = connection.get_geometry(window)?.reply()?;
            let origin = connection
                .translate_coordinates(window, root, 0, 0)?
                .reply()?;
            let bounds = Bounds {
                x: origin.dst_x.into(),
                y: origin.dst_y.into(),
                width: geometry.width.into(),
                height: geometry.height.into(),
            };
            let client = client_window(connection, window)?;
            let mut value = context_value(connection, client)?;
            let pid = value["processId"].as_u64();
            let started = pid
                .and_then(|id| fs::read_to_string(format!("/proc/{id}/stat")).ok())
                .and_then(|stat| {
                    stat.rsplit_once(") ").map(|(_, fields)| {
                        fields.split_whitespace().nth(19).unwrap_or("").to_owned()
                    })
                });
            value["nativeWindowId"] = json!(client.to_string());
            value["processStartToken"] = json!(started);
            value["platform"] = json!("linux");
            value["provider"] = json!("atspi");
            value["hostName"] = json!(
                fs::read_to_string("/etc/hostname")
                    .unwrap_or_default()
                    .trim()
            );
            value["bounds"] = json!(bounds);
            value["windowBounds"] = json!(bounds);
            value.as_object_mut().unwrap().remove("limitation");
            Ok(value)
        };
        if let Ok(value) = read() {
            result.push(value);
        }
    }
    Ok(result)
}

fn source_at(windows: &[Value], region: Bounds) -> Option<Value> {
    for window in windows {
        let bounds: Bounds = serde_json::from_value(window["bounds"].clone()).ok()?;
        if !bounds.intersects(region) {
            continue;
        }
        return (bounds.contains(region) && window["processId"].as_u64().is_some())
            .then(|| window.clone());
    }
    None
}

pub(super) async fn snapshot() -> AppResult<()> {
    // Activate the session accessibility bus before freezing the source. Never
    // disable it afterward: other assistive clients may depend on it.
    let _ = tokio::time::timeout(
        Duration::from_millis(500),
        atspi::connection::set_session_accessibility(true),
    )
    .await;
    let (connection, number) = connect()?;
    let screen = &connection.setup().roots[number];
    let before = windows(&connection, screen.root)?;
    let bounds = Bounds {
        x: 0.0,
        y: 0.0,
        width: screen.width_in_pixels.into(),
        height: screen.height_in_pixels.into(),
    };
    let png = capture_bytes(&connection, screen, bounds)?;
    let after = windows(&connection, screen.root)?;
    emit_json(
        &json!({"frames": [{"dataUrl": format!("data:image/png;base64,{}", STANDARD.encode(png)),
        "bounds": bounds, "windows": if before == after { before } else { Vec::new() }, "label": "Desktop", "coordinateSpace": "screen-pixels"}]}),
    )
}

pub(super) async fn observe(region: Bounds) -> AppResult<()> {
    let (connection, number) = connect()?;
    let screen = &connection.setup().roots[number];
    let before_windows = windows(&connection, screen.root)?;
    let source = source_at(&before_windows, region);
    let before = if let Some(source) = &source {
        read_accessibility(source, region).await
    } else {
        json!({"limitation": "The region does not have one unobscured source window."})
    };
    let image = capture_bytes(&connection, screen, region)?;
    let after = if let Some(source) = &source {
        read_accessibility(source, region).await
    } else {
        before.clone()
    };
    let after_windows = windows(&connection, screen.root)?;
    let stable = source == source_at(&after_windows, region) && before == after;
    emit_json(
        &json!({"dataUrl": format!("data:image/png;base64,{}", STANDARD.encode(image)), "bounds": region,
        "source": source, "windows": after_windows, "stable": stable,
        "regionContext": if stable { before.get("regionContext") } else { None },
        "browserViewport": if stable { before.get("browserViewport") } else { None },
        "limitation": if stable { before["limitation"].clone() } else { json!("The window or accessible content changed during capture.") }}),
    )
}

async fn read_accessibility(source: &Value, region: Bounds) -> Value {
    match tokio::time::timeout(
        Duration::from_millis(1200),
        accessible_region(source, region),
    )
    .await
    {
        Ok(Ok(value)) => value,
        Ok(Err(_)) => {
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
    let native: Bounds = serde_json::from_value(source["bounds"].clone())?;
    for app in root.get_children().await?.into_iter().take(128) {
        let Some(name) = app.name() else {
            continue;
        };
        if dbus
            .get_connection_unix_process_id(name.clone().into())
            .await
            .ok()
            .map(u64::from)
            != source["processId"].as_u64()
        {
            continue;
        }
        let accessible = app.as_accessible_proxy(bus).await?;
        for window in accessible.get_children().await?.into_iter().take(128) {
            let accessible = window.as_accessible_proxy(bus).await?;
            let component = ComponentProxy::builder(bus)
                .destination(window.name().ok_or("missing bus name")?.clone())?
                .path(window.path())?
                .build()
                .await?;
            let Ok((x, y, w, h)) = component.get_extents(CoordType::Screen).await else {
                continue;
            };
            let bounds = Bounds {
                x: x.into(),
                y: y.into(),
                width: w.into(),
                height: h.into(),
            };
            if bounds.contains(region)
                && (bounds.x - native.x).abs() < 32.0
                && (bounds.y - native.y).abs() < 64.0
                && (bounds.width - native.width).abs() < 64.0
                && (bounds.height - native.height).abs() < 96.0
                && accessible.name().await.unwrap_or_default()
                    == source["windowTitle"].as_str().unwrap_or("")
            {
                matching.push(window);
            }
        }
    }
    if matching.len() != 1 {
        return Err("No unique accessibility window matches the native window".into());
    }
    let mut stack = vec![(matching.remove(0), None::<String>, 0usize)];
    let mut seen = HashSet::new();
    let mut elements = Vec::new();
    let mut viewport = None;
    let mut text_budget = 24_000usize;
    let mut truncated = false;
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
            if let Ok((x, y, w, h)) = component.get_extents(CoordType::Screen).await {
                let bounds = Bounds {
                    x: x.into(),
                    y: y.into(),
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
        json!({"regionContext": {"version": 1, "selectionKind": "bbox", "coordinateSpace": "image-pixels", "elements": elements, "truncated": truncated},
        "browserViewport": viewport, "limitation": "Captured AT-SPI accessibility. Intersecting elements may expose labels beyond the crop; the image is the selected content."}),
    )
}
