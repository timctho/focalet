use std::env;
use std::error::Error;
use std::fs::{self, File};
use std::io::{BufReader, BufWriter, Write};
use std::path::{Path, PathBuf};
use std::thread;
use std::time::Duration;

use ashpd::desktop::global_shortcuts::{BindShortcutsOptions, GlobalShortcuts, NewShortcut};
use ashpd::desktop::screenshot::{AvailableTargets, Screenshot};
use ashpd::desktop::{CreateSessionOptions, ResponseError};
use ashpd::{AppID, register_host_app};
use futures_util::StreamExt;
use serde_json::Value;
use serde_json::json;
use url::Url;
use x11rb::CURRENT_TIME;
use x11rb::connection::Connection;
use x11rb::image::{Image, PixelLayout};
use x11rb::protocol::Event;
use x11rb::protocol::xproto::{
    Atom, AtomEnum, ConnectionExt, CreateGCAux, EventMask, GX, GrabMode, GrabStatus, Rectangle,
    SubwindowMode, Visualtype, Window,
};
use x11rb::rust_connection::RustConnection;

type AppResult<T> = Result<T, Box<dyn Error>>;

const BUTTON_LEFT: u8 = 1;
const PORTAL_APP_ID: &str = "com.zommi.desktop";
const KEYBOARD_GRAB_ATTEMPTS: usize = 50;
const KEYBOARD_GRAB_RETRY_DELAY: Duration = Duration::from_millis(20);
const KEYSYM_ESCAPE: u32 = 0xFF1B;

#[tokio::main]
async fn main() {
    if let Err(error) = run().await {
        eprintln!("Linux capture failed: {error}");
        std::process::exit(1);
    }
}

async fn run() -> AppResult<()> {
    let mut arguments = env::args_os().skip(1);
    match arguments
        .next()
        .and_then(|value| value.into_string().ok())
        .as_deref()
    {
        Some("probe") if arguments.next().is_none() => {
            emit_json(&json!({
                "ok": true,
                "providers": ["x11", "wayland-portal"],
            }))
        }
        Some("context") if arguments.next().is_none() => capture_context(),
        Some("point-context") if arguments.next().is_none() => select_point_context(),
        Some("portal-context") if arguments.next().is_none() => capture_portal_context(),
        Some("region") => {
            let flag = arguments.next().and_then(|value| value.into_string().ok());
            let output = arguments.next().map(PathBuf::from);
            if flag.as_deref() != Some("--output") || output.is_none() || arguments.next().is_some()
            {
                return Err("usage: zommi-x11-capture region --output <png-path>".into());
            }
            select_region(&output.unwrap())
        }
        Some("portal-region") => {
            let flag = arguments.next().and_then(|value| value.into_string().ok());
            let output = arguments.next().map(PathBuf::from);
            if flag.as_deref() != Some("--output") || output.is_none() || arguments.next().is_some()
            {
                return Err("usage: zommi-x11-capture portal-region --output <png-path>".into());
            }
            select_portal_region(&output.unwrap()).await
        }
        Some("portal-shortcuts") if arguments.next().is_none() => portal_shortcuts().await,
        _ => Err(
            "usage: zommi-x11-capture <probe|context|point-context|portal-context|region --output <png-path>|portal-region --output <png-path>|portal-shortcuts>"
                .into(),
        ),
    }
}

fn emit_json(value: &Value) -> AppResult<()> {
    let mut output = std::io::stdout().lock();
    serde_json::to_writer(&mut output, value)?;
    writeln!(output)?;
    output.flush()?;
    Ok(())
}

fn capture_portal_context() -> AppResult<()> {
    emit_json(&portal_context_value())
}

fn portal_context_value() -> Value {
    json!({
        "application": "Linux desktop",
        "processName": "wayland-session",
        "windowTitle": "",
        "degraded": true,
        "limitation": "Wayland portals do not expose active-window metadata; image regions remain available through the screenshot portal.",
    })
}

fn copy_portal_screenshot(uri: &str, output: &Path) -> AppResult<(u32, u32)> {
    let source = Url::parse(uri)?
        .to_file_path()
        .map_err(|_| "the screenshot portal returned a non-file URI")?;
    if !source.is_file() {
        return Err("the screenshot portal result is not a readable file".into());
    }
    if let Some(parent) = output.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::copy(&source, output)?;
    let reader = png::Decoder::new(BufReader::new(File::open(output)?)).read_info()?;
    Ok((reader.info().width, reader.info().height))
}

async fn select_portal_region(output: &Path) -> AppResult<()> {
    register_portal_host().await;
    let request = Screenshot::request()
        .interactive(true)
        .modal(false)
        .target(AvailableTargets::Area)
        .send()
        .await?;
    let screenshot = match request.response() {
        Ok(screenshot) => screenshot,
        Err(ashpd::Error::Response(ResponseError::Cancelled)) => {
            return emit_json(&json!({"cancelled": true}));
        }
        Err(error) => return Err(error.into()),
    };
    let (width, height) = copy_portal_screenshot(screenshot.uri().as_str(), output)?;
    emit_json(&json!({
        "cancelled": false,
        "imagePath": output,
        "bounds": {"width": width, "height": height},
        "provider": "wayland-portal",
    }))
}

async fn portal_shortcuts() -> AppResult<()> {
    register_portal_host().await;
    let portal = GlobalShortcuts::new().await?;
    let session = portal
        .create_session(CreateSessionOptions::default())
        .await?;
    let mut activations = Box::pin(portal.receive_activated().await?);
    let response = portal
        .bind_shortcuts(
            &session,
            &[NewShortcut::new("context", "Select content").preferred_trigger("ALT+a")],
            None,
            BindShortcutsOptions::default(),
        )
        .await?
        .response()?;
    let context_shortcut = response
        .shortcuts()
        .iter()
        .any(|shortcut| shortcut.id() == "context");
    emit_json(&json!({
        "event": "ready",
        "provider": "wayland-portal",
        "portalVersion": portal.version(),
        "contextShortcut": context_shortcut,
        "imageShortcut": false,
    }))?;

    while let Some(activation) = activations.next().await {
        if activation.shortcut_id() == "context" {
            emit_json(&json!({
                "event": "activated",
                "shortcutId": activation.shortcut_id(),
                "timestampMilliseconds": activation.timestamp().as_millis(),
            }))?;
        }
    }
    drop(session);
    Err("the Wayland global-shortcuts portal event stream ended".into())
}

async fn register_portal_host() {
    let app_id = AppID::try_from(PORTAL_APP_ID).expect("the Zommi application ID is valid");
    if let Err(error) = register_host_app(app_id).await {
        eprintln!("Wayland portal host registration warning: {error}");
    }
}

fn connect() -> AppResult<(RustConnection, usize)> {
    x11rb::connect(None).map_err(|error| {
        format!("an X11 display is required; Wayland-only sessions need portal support: {error}")
            .into()
    })
}

fn atom(connection: &RustConnection, name: &[u8]) -> AppResult<Atom> {
    Ok(connection.intern_atom(false, name)?.reply()?.atom)
}

fn property_bytes(
    connection: &RustConnection,
    window: Window,
    property: Atom,
    property_type: Atom,
) -> AppResult<Vec<u8>> {
    Ok(connection
        .get_property(false, window, property, property_type, 0, u32::MAX)?
        .reply()?
        .value)
}

fn property_u32(
    connection: &RustConnection,
    window: Window,
    property: Atom,
    property_type: Atom,
) -> AppResult<Option<u32>> {
    let reply = connection
        .get_property(false, window, property, property_type, 0, 1)?
        .reply()?;
    Ok(reply.value32().and_then(|mut values| values.next()))
}

fn active_window(connection: &RustConnection, screen_number: usize) -> AppResult<Window> {
    let root = connection.setup().roots[screen_number].root;
    let active = property_u32(
        connection,
        root,
        atom(connection, b"_NET_ACTIVE_WINDOW")?,
        AtomEnum::WINDOW.into(),
    )?;
    if let Some(window) = active.filter(|window| *window != 0 && *window != root) {
        return Ok(window);
    }
    let focus = connection.get_input_focus()?.reply()?.focus;
    if focus == 0 || focus == root {
        return Err("the X11 server did not expose an active external window".into());
    }
    Ok(focus)
}

fn window_title(connection: &RustConnection, window: Window) -> AppResult<String> {
    let utf8 = atom(connection, b"UTF8_STRING")?;
    let net_name = property_bytes(connection, window, atom(connection, b"_NET_WM_NAME")?, utf8)?;
    if !net_name.is_empty() {
        return Ok(String::from_utf8_lossy(&net_name)
            .trim_matches('\0')
            .to_owned());
    }
    let name = property_bytes(
        connection,
        window,
        AtomEnum::WM_NAME.into(),
        AtomEnum::STRING.into(),
    )?;
    Ok(String::from_utf8_lossy(&name).trim_matches('\0').to_owned())
}

fn capture_context() -> AppResult<()> {
    let (connection, screen_number) = connect()?;
    let window = active_window(&connection, screen_number)?;
    emit_json(&context_value(&connection, window)?)
}

fn context_value(connection: &RustConnection, window: Window) -> AppResult<Value> {
    let title = window_title(connection, window)?;
    let process_id = property_u32(
        connection,
        window,
        atom(connection, b"_NET_WM_PID")?,
        AtomEnum::CARDINAL.into(),
    )?;
    let process_name = process_id
        .and_then(|value| fs::read_to_string(format!("/proc/{value}/comm")).ok())
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| "X11 application".to_owned());
    Ok(json!({
        "application": process_name,
        "processName": process_name,
        "windowTitle": title,
        "windowId": window,
        "processId": process_id,
        "limitation": "X11 exposes active-window metadata only; semantic enrichment depends on AT-SPI.",
    }))
}

fn top_level_window(
    connection: &RustConnection,
    root: Window,
    window: Window,
) -> AppResult<Window> {
    if window == 0 || window == root {
        return active_window(
            connection,
            connection
                .setup()
                .roots
                .iter()
                .position(|screen| screen.root == root)
                .unwrap_or(0),
        );
    }
    let mut current = window;
    loop {
        let tree = connection.query_tree(current)?.reply()?;
        if tree.parent == root || tree.parent == 0 || tree.parent == current {
            return Ok(current);
        }
        current = tree.parent;
    }
}

fn create_crosshair_cursor(connection: &RustConnection) -> AppResult<(u32, u32)> {
    const XC_CROSSHAIR: u16 = 34;
    let font = connection.generate_id()?;
    connection.open_font(font, b"cursor")?;
    let cursor = connection.generate_id()?;
    connection.create_glyph_cursor(
        cursor,
        font,
        font,
        XC_CROSSHAIR,
        XC_CROSSHAIR + 1,
        u16::MAX,
        u16::MAX,
        u16::MAX,
        0,
        0,
        0,
    )?;
    Ok((font, cursor))
}

fn select_point_context() -> AppResult<()> {
    let (connection, screen_number) = connect()?;
    let root = connection.setup().roots[screen_number].root;
    let (font, cursor) = create_crosshair_cursor(&connection)?;
    let pointer_status = connection
        .grab_pointer(
            false,
            root,
            EventMask::BUTTON_PRESS,
            GrabMode::ASYNC,
            GrabMode::ASYNC,
            x11rb::NONE,
            cursor,
            CURRENT_TIME,
        )?
        .reply()?
        .status;
    if pointer_status != GrabStatus::SUCCESS {
        connection.free_cursor(cursor)?;
        connection.close_font(font)?;
        connection.flush()?;
        return Err(format!("the X11 pointer is already grabbed ({pointer_status:?})").into());
    }
    let keyboard_status = grab_keyboard_after_shortcut(&connection, root)?;
    if keyboard_status != GrabStatus::SUCCESS {
        connection.ungrab_pointer(CURRENT_TIME)?;
        connection.free_cursor(cursor)?;
        connection.close_font(font)?;
        connection.flush()?;
        return Err(format!("the X11 keyboard is already grabbed ({keyboard_status:?})").into());
    }

    connection.flush()?;
    let mut selected = None;
    loop {
        match connection.wait_for_event()? {
            Event::ButtonPress(event) if event.detail == BUTTON_LEFT => {
                selected = Some(event.child);
                break;
            }
            Event::KeyPress(event) if key_is_escape(&connection, event.detail)? => break,
            _ => {}
        }
    }

    connection.ungrab_keyboard(CURRENT_TIME)?;
    connection.ungrab_pointer(CURRENT_TIME)?;
    connection.free_cursor(cursor)?;
    connection.close_font(font)?;
    connection.flush()?;

    let Some(window) = selected else {
        return emit_json(&json!({"cancelled": true}));
    };
    let target = top_level_window(&connection, root, window)?;
    let context = context_value(&connection, target)?;
    emit_json(&json!({
        "cancelled": false,
        "application": context["application"],
        "processName": context["processName"],
        "windowTitle": context["windowTitle"],
        "windowId": context["windowId"],
        "processId": context["processId"],
        "limitation": context["limitation"],
    }))
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Region {
    x: i16,
    y: i16,
    width: u16,
    height: u16,
}

fn normalized_region(start: (i16, i16), end: (i16, i16), size: (u16, u16)) -> Option<Region> {
    let max_x = i32::from(size.0);
    let max_y = i32::from(size.1);
    let left = i32::from(start.0.min(end.0)).clamp(0, max_x);
    let top = i32::from(start.1.min(end.1)).clamp(0, max_y);
    let right = i32::from(start.0.max(end.0)).clamp(0, max_x);
    let bottom = i32::from(start.1.max(end.1)).clamp(0, max_y);
    let width = right - left;
    let height = bottom - top;
    (width > 0 && height > 0).then_some(Region {
        x: left as i16,
        y: top as i16,
        width: width as u16,
        height: height as u16,
    })
}

fn draw_rectangle(
    connection: &RustConnection,
    root: Window,
    gc: u32,
    region: Region,
) -> AppResult<()> {
    connection.poly_rectangle(
        root,
        gc,
        &[Rectangle {
            x: region.x,
            y: region.y,
            width: region.width,
            height: region.height,
        }],
    )?;
    connection.flush()?;
    Ok(())
}

fn grab_keyboard_after_shortcut(
    connection: &RustConnection,
    root: Window,
) -> AppResult<GrabStatus> {
    for attempt in 0..KEYBOARD_GRAB_ATTEMPTS {
        let status = connection
            .grab_keyboard(false, root, CURRENT_TIME, GrabMode::ASYNC, GrabMode::ASYNC)?
            .reply()?
            .status;
        if status != GrabStatus::ALREADY_GRABBED || attempt + 1 == KEYBOARD_GRAB_ATTEMPTS {
            return Ok(status);
        }
        thread::sleep(KEYBOARD_GRAB_RETRY_DELAY);
    }
    unreachable!("the bounded keyboard-grab loop always returns")
}

fn key_is_escape(connection: &RustConnection, keycode: u8) -> AppResult<bool> {
    Ok(connection
        .get_keyboard_mapping(keycode, 1)?
        .reply()?
        .keysyms
        .contains(&KEYSYM_ESCAPE))
}

fn select_region(output: &Path) -> AppResult<()> {
    let (connection, screen_number) = connect()?;
    let screen = &connection.setup().roots[screen_number];
    let root = screen.root;
    let pointer_status = connection
        .grab_pointer(
            false,
            root,
            EventMask::BUTTON_PRESS | EventMask::BUTTON_RELEASE | EventMask::POINTER_MOTION,
            GrabMode::ASYNC,
            GrabMode::ASYNC,
            x11rb::NONE,
            x11rb::NONE,
            CURRENT_TIME,
        )?
        .reply()?
        .status;
    if pointer_status != GrabStatus::SUCCESS {
        return Err(format!("the X11 pointer is already grabbed ({pointer_status:?})").into());
    }
    let keyboard_status = grab_keyboard_after_shortcut(&connection, root)?;
    if keyboard_status != GrabStatus::SUCCESS {
        connection.ungrab_pointer(CURRENT_TIME)?;
        connection.flush()?;
        return Err(format!("the X11 keyboard is already grabbed ({keyboard_status:?})").into());
    }

    let gc = connection.generate_id()?;
    connection.create_gc(
        gc,
        root,
        &CreateGCAux::new()
            .function(GX::XOR)
            .foreground(screen.white_pixel)
            .line_width(2)
            .subwindow_mode(SubwindowMode::INCLUDE_INFERIORS),
    )?;
    connection.flush()?;

    let mut start = None;
    let mut drawn = None;
    let mut selected = None;
    loop {
        match connection.wait_for_event()? {
            Event::ButtonPress(event) if event.detail == BUTTON_LEFT => {
                start = Some((event.root_x, event.root_y));
            }
            Event::MotionNotify(event) => {
                if let Some(origin) = start {
                    if let Some(previous) = drawn.take() {
                        draw_rectangle(&connection, root, gc, previous)?;
                    }
                    drawn = normalized_region(
                        origin,
                        (event.root_x, event.root_y),
                        (screen.width_in_pixels, screen.height_in_pixels),
                    );
                    if let Some(current) = drawn {
                        draw_rectangle(&connection, root, gc, current)?;
                    }
                }
            }
            Event::ButtonRelease(event) if event.detail == BUTTON_LEFT => {
                if let Some(origin) = start {
                    if let Some(previous) = drawn.take() {
                        draw_rectangle(&connection, root, gc, previous)?;
                    }
                    selected = normalized_region(
                        origin,
                        (event.root_x, event.root_y),
                        (screen.width_in_pixels, screen.height_in_pixels),
                    );
                }
                break;
            }
            Event::KeyPress(event) if key_is_escape(&connection, event.detail)? => {
                if let Some(previous) = drawn.take() {
                    draw_rectangle(&connection, root, gc, previous)?;
                }
                break;
            }
            _ => {}
        }
    }

    connection.free_gc(gc)?;
    connection.ungrab_keyboard(CURRENT_TIME)?;
    connection.ungrab_pointer(CURRENT_TIME)?;
    connection.flush()?;

    let Some(region) = selected else {
        return emit_json(&json!({"cancelled": true}));
    };
    write_region_png(&connection, screen.root_visual, root, region, output)?;
    emit_json(&json!({
        "cancelled": false,
        "imagePath": output,
        "bounds": {
            "x": region.x,
            "y": region.y,
            "width": region.width,
            "height": region.height,
        },
    }))
}

fn find_visual(connection: &RustConnection, visual_id: u32) -> AppResult<Visualtype> {
    connection
        .setup()
        .roots
        .iter()
        .flat_map(|screen| screen.allowed_depths.iter())
        .flat_map(|depth| depth.visuals.iter())
        .find(|visual| visual.visual_id == visual_id)
        .copied()
        .ok_or_else(|| format!("X11 visual {visual_id} was not described by the server").into())
}

fn write_region_png(
    connection: &RustConnection,
    root_visual: u32,
    root: Window,
    region: Region,
    output: &Path,
) -> AppResult<()> {
    let (image, visual_id) = Image::get(
        connection,
        root,
        region.x,
        region.y,
        region.width,
        region.height,
    )?;
    let visual = find_visual(
        connection,
        if visual_id == 0 {
            root_visual
        } else {
            visual_id
        },
    )?;
    let layout = PixelLayout::from_visual_type(visual)?;
    let mut rgb = Vec::with_capacity(usize::from(region.width) * usize::from(region.height) * 3);
    for y in 0..region.height {
        for x in 0..region.width {
            let (red, green, blue) = layout.decode(image.get_pixel(x, y));
            rgb.extend_from_slice(&[(red >> 8) as u8, (green >> 8) as u8, (blue >> 8) as u8]);
        }
    }
    if let Some(parent) = output.parent() {
        fs::create_dir_all(parent)?;
    }
    let mut encoder = png::Encoder::new(
        BufWriter::new(File::create(output)?),
        u32::from(region.width),
        u32::from(region.height),
    );
    encoder.set_color(png::ColorType::Rgb);
    encoder.set_depth(png::BitDepth::Eight);
    encoder.write_header()?.write_image_data(&rgb)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn normalizes_reverse_and_clamped_selection() {
        assert_eq!(
            normalized_region((80, 70), (20, 10), (100, 100)),
            Some(Region {
                x: 20,
                y: 10,
                width: 60,
                height: 60,
            })
        );
        assert_eq!(
            normalized_region((-10, -20), (120, 130), (100, 90)),
            Some(Region {
                x: 0,
                y: 0,
                width: 100,
                height: 90,
            })
        );
        assert_eq!(normalized_region((4, 4), (4, 8), (100, 100)), None);
    }

    #[test]
    fn portal_context_is_explicitly_degraded() {
        let value = portal_context_value();
        assert_eq!(value["degraded"], true);
        assert!(
            value["limitation"]
                .as_str()
                .unwrap()
                .contains("active-window")
        );
    }

    #[test]
    fn copies_and_measures_a_portal_png() {
        let directory = tempdir().unwrap();
        let source = directory.path().join("portal.png");
        let output = directory.path().join("zommi.png");
        let mut encoder = png::Encoder::new(BufWriter::new(File::create(&source).unwrap()), 3, 2);
        encoder.set_color(png::ColorType::Rgb);
        encoder.set_depth(png::BitDepth::Eight);
        encoder
            .write_header()
            .unwrap()
            .write_image_data(&[0; 18])
            .unwrap();
        let uri = Url::from_file_path(&source).unwrap();

        assert_eq!(
            copy_portal_screenshot(uri.as_str(), &output).unwrap(),
            (3, 2)
        );
        assert_eq!(fs::read(&output).unwrap(), fs::read(&source).unwrap());
        assert!(copy_portal_screenshot("https://example.com/image.png", &output).is_err());
    }
}
