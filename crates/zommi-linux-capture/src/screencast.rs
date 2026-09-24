use crate::{
    AppResult, accessibility,
    geometry::{Bounds, source_at},
    gnome,
    restore_token::RestoreToken,
};
use ashpd::desktop::{
    PersistMode, ResponseError, Session,
    screencast::{CursorMode, Screencast, SelectSourcesOptions, SourceType},
};
use atspi::zbus::Connection;
use base64::{Engine, engine::general_purpose::STANDARD};
use gst::prelude::*;
use gst_video::prelude::*;
use gstreamer as gst;
use gstreamer_app as gst_app;
use gstreamer_video as gst_video;
use serde_json::{Value, json};
use std::{
    os::fd::{AsRawFd, OwnedFd},
    time::{Duration, Instant},
};

struct Monitor {
    bounds: Bounds,
    pipeline: gst::Pipeline,
    sink: gst_app::AppSink,
    _remote: OwnedFd,
}
impl Drop for Monitor {
    fn drop(&mut self) {
        let _ = self.pipeline.set_state(gst::State::Null);
    }
}
struct Frame {
    width: u32,
    height: u32,
    rgb: Vec<u8>,
}
impl Frame {
    fn png(&self, crop: (u32, u32, u32, u32)) -> AppResult<String> {
        let (x, y, w, h) = crop;
        let mut pixels = Vec::with_capacity((w * h * 3) as usize);
        for row in y..y + h {
            let start = ((row * self.width + x) * 3) as usize;
            pixels.extend_from_slice(&self.rgb[start..start + (w * 3) as usize]);
        }
        let mut bytes = Vec::new();
        {
            let mut encoder = png::Encoder::new(&mut bytes, w, h);
            encoder.set_color(png::ColorType::Rgb);
            encoder.set_depth(png::BitDepth::Eight);
            encoder.write_header()?.write_image_data(&pixels)?;
        }
        Ok(format!("data:image/png;base64,{}", STANDARD.encode(bytes)))
    }
}
impl Monitor {
    fn new(remote: OwnedFd, node: u32, bounds: Bounds) -> AppResult<Self> {
        let pipeline = gst::Pipeline::new();
        let source = gst::ElementFactory::make("pipewiresrc")
            .property("fd", remote.as_raw_fd())
            .property("path", node.to_string())
            .property("do-timestamp", true)
            .build()?;
        let convert = gst::ElementFactory::make("videoconvert").build()?;
        let sink = gst_app::AppSink::builder()
            .max_buffers(1)
            .drop(true)
            .sync(false)
            .caps(
                &gst::Caps::builder("video/x-raw")
                    .field("format", "RGB")
                    .build(),
            )
            .build();
        pipeline.add_many([&source, &convert, sink.upcast_ref()])?;
        gst::Element::link_many([&source, &convert, sink.upcast_ref()])?;
        let monitor = Self {
            bounds,
            pipeline,
            sink,
            _remote: remote,
        };
        eprintln!("Wayland capture: starting monitor stream");
        monitor.pipeline.set_state(gst::State::Playing)?;
        eprintln!("Wayland capture: monitor stream started");
        Ok(monitor)
    }
    async fn frame(&self) -> AppResult<Frame> {
        while self.sink.try_pull_sample(gst::ClockTime::ZERO).is_some() {}
        let deadline = Instant::now() + Duration::from_secs(4);
        loop {
            if let Some(sample) = self.sink.try_pull_sample(gst::ClockTime::ZERO) {
                let info =
                    gst_video::VideoInfo::from_caps(sample.caps().ok_or("Missing video format")?)?;
                if info.width() == 0
                    || info.height() == 0
                    || u64::from(info.width()) * u64::from(info.height()) > 64_000_000
                {
                    return Err("The shared monitor is too large".into());
                }
                let buffer = sample.buffer().ok_or("Missing shared screen frame")?;
                if let Some(crop) = buffer.meta::<gst_video::VideoCropMeta>()
                    && crop.rect() != (0, 0, info.width(), info.height())
                {
                    return Err(
                        "The desktop supplied a cropped stream. Share a whole monitor and retry."
                            .into(),
                    );
                }
                let video = gst_video::VideoFrameRef::from_buffer_ref_readable(buffer, &info)?;
                let data = video.plane_data(0)?;
                let stride = video.plane_stride()[0];
                if stride < (info.width() * 3) as i32 {
                    return Err("Invalid shared screen stride".into());
                }
                let mut rgb = Vec::with_capacity((info.width() * info.height() * 3) as usize);
                for row in 0..info.height() as usize {
                    let start = row * stride as usize;
                    rgb.extend_from_slice(
                        data.get(start..start + (info.width() * 3) as usize)
                            .ok_or("Incomplete screen frame")?,
                    );
                }
                let sx = f64::from(info.width()) / self.bounds.width;
                let sy = f64::from(info.height()) / self.bounds.height;
                if (sx - sy).abs() > 0.01 {
                    return Err(
                        "Screen sharing geometry changed. Select again to reconnect.".into(),
                    );
                }
                return Ok(Frame {
                    width: info.width(),
                    height: info.height(),
                    rgb,
                });
            }
            if let Some(message) = self
                .pipeline
                .bus()
                .and_then(|bus| bus.pop_filtered(&[gst::MessageType::Error, gst::MessageType::Eos]))
            {
                return Err(format!(
                    "Screen sharing stopped ({:?}). Select again to reconnect.",
                    message.type_()
                )
                .into());
            }
            if Instant::now() >= deadline {
                return Err(
                    "No fresh screen frame arrived. Select again to reconnect screen sharing."
                        .into(),
                );
            }
            tokio::time::sleep(Duration::from_millis(15)).await;
        }
    }
}
pub(crate) struct Capture {
    connection: Connection,
    monitors: Vec<Monitor>,
    _session: PortalSession,
    session_id: String,
}
struct PortalSession(Option<Session<Screencast>>);
impl PortalSession {
    fn get(&self) -> &Session<Screencast> {
        self.0.as_ref().expect("active portal session")
    }
    async fn close(&mut self) {
        if let Some(session) = self.0.take() {
            let _ = tokio::time::timeout(Duration::from_secs(2), session.close()).await;
        }
    }
}
impl Drop for PortalSession {
    fn drop(&mut self) {
        if let Some(session) = self.0.take() {
            tokio::spawn(async move {
                let _ = session.close().await;
            });
        }
    }
}
impl Capture {
    pub async fn close(mut self) {
        self.monitors.clear();
        self._session.close().await;
    }
    pub async fn open(connection: Connection) -> AppResult<Option<Self>> {
        gst::init()?;
        let _ = ashpd::register_host_app(ashpd::AppID::try_from("com.zommi.desktop")?).await;
        let portal = Screencast::new().await?;
        let tokens = RestoreToken::for_user();
        let restore_token = tokens.take();
        let mut session = PortalSession(Some(portal.create_session(Default::default()).await?));
        let result: AppResult<_> = async {
            portal
                .select_sources(
                    session.get(),
                    SelectSourcesOptions::default()
                        .set_sources(ashpd::enumflags2::BitFlags::from(SourceType::Monitor))
                        .set_multiple(true)
                        .set_cursor_mode(CursorMode::Hidden)
                        .set_persist_mode(PersistMode::ExplicitlyRevoked)
                        .set_restore_token(restore_token.as_deref()),
                )
                .await?
                .response()?;
            eprintln!("Wayland capture: waiting for screen-sharing authorization");
            let response = portal
                .start(session.get(), None, Default::default())
                .await?
                .response()?;
            if let Err(error) = tokens.save(response.restore_token()) {
                eprintln!("Could not remember screen-sharing authorization: {error}");
            }
            eprintln!(
                "Wayland capture: authorized {} streams",
                response.streams().len()
            );
            let mut monitors = Vec::new();
            if response.streams().len() > 8 {
                return Err("Share at most eight monitors at a time.".into());
            }
            for stream in response.streams() {
                let (x, y) = stream
                    .position()
                    .ok_or("Share a monitor with a known desktop position.")?;
                let (w, h) = stream
                    .size()
                    .ok_or("Screen sharing did not provide monitor dimensions.")?;
                let bounds = Bounds {
                    x: x.into(),
                    y: y.into(),
                    width: w.into(),
                    height: h.into(),
                };
                if !bounds.valid() {
                    return Err("Invalid screen sharing dimensions".into());
                }
                monitors.push(Monitor::new(
                    portal
                        .open_pipe_wire_remote(session.get(), Default::default())
                        .await?,
                    stream.pipe_wire_node_id(),
                    bounds,
                )?);
            }
            if monitors.is_empty() {
                return Err("No monitor was selected.".into());
            }
            tokio::time::sleep(Duration::from_millis(350)).await;
            let desktop = gnome::snapshot(&connection).await?;
            let identity = desktop["sessionId"]
                .as_str()
                .ok_or("Missing GNOME session identity")?
                .to_owned();
            Ok((monitors, identity))
        }
        .await;
        match result {
            Ok((monitors, session_id)) => Ok(Some(Self {
                connection,
                monitors,
                _session: session,
                session_id,
            })),
            Err(error) => {
                session.close().await;
                if matches!(
                    error.downcast_ref::<ashpd::Error>(),
                    Some(ashpd::Error::Response(ResponseError::Cancelled))
                ) {
                    Ok(None)
                } else {
                    Err(error)
                }
            }
        }
    }
    async fn desktop(&self) -> AppResult<Value> {
        let desktop = gnome::snapshot(&self.connection).await?;
        if desktop["sessionId"].as_str() != Some(&self.session_id) {
            return Err("Desktop integration restarted. Select again to reconnect.".into());
        }
        let layouts: Vec<Bounds> = serde_json::from_value(desktop["monitors"].clone())?;
        if self
            .monitors
            .iter()
            .any(|monitor| !layouts.contains(&monitor.bounds))
        {
            return Err("The monitor layout changed. Select again to reconnect.".into());
        }
        Ok(desktop)
    }
    pub async fn snapshot(&mut self) -> AppResult<Value> {
        let mut frames = Vec::new();
        for monitor in &self.monitors {
            let before = self.desktop().await?;
            let frame = monitor.frame().await?;
            let after = self.desktop().await?;
            frames.push(json!({"dataUrl":frame.png((0,0,frame.width,frame.height))?,
                "bounds":monitor.bounds,"windows":if before["windows"] == after["windows"] {after["windows"].clone()} else {json!([])},
                "label":format!("Monitor {}",frames.len()+1),"coordinateSpace":"screen-logical","screenCoordinatesKnown":true}));
        }
        Ok(json!({"frames":frames}))
    }
    pub async fn observe(&mut self, region: Bounds) -> AppResult<Value> {
        let before_windows = self.desktop().await?;
        let monitor = self
            .monitors
            .iter()
            .find(|monitor| monitor.bounds.contains(region))
            .ok_or("The selected region is outside the shared monitor")?;
        let source = source_at(
            before_windows["windows"]
                .as_array()
                .ok_or("Missing window inventory")?,
            region,
        );
        let before = if let Some(source) = &source {
            accessibility::read_accessibility(source, region).await
        } else {
            json!({"limitation":"The selection does not have one unobscured source window."})
        };
        self.desktop().await?;
        let frame = monitor.frame().await?;
        let crop = region
            .pixels(monitor.bounds, frame.width, frame.height)
            .ok_or("Invalid selected pixel region")?;
        let after = if let Some(source) = &source {
            accessibility::read_accessibility(source, region).await
        } else {
            before.clone()
        };
        let after_windows = self.desktop().await?;
        let stable = before_windows["windows"] == after_windows["windows"] && before == after;
        if !stable {
            eprintln!(
                "Wayland capture: source changed (windows={}, accessibility={})",
                before_windows["windows"] != after_windows["windows"],
                before != after
            );
        }
        let mut context = after["regionContext"].clone();
        if let Some(elements) = context.get_mut("elements").and_then(Value::as_array_mut) {
            for element in elements {
                for key in ["bounds", "visibleBounds"] {
                    let mut bounds: Bounds = serde_json::from_value(element[key].clone())?;
                    let sx = f64::from(crop.2) / region.width;
                    let sy = f64::from(crop.3) / region.height;
                    bounds.x *= sx;
                    bounds.width *= sx;
                    bounds.y *= sy;
                    bounds.height *= sy;
                    element[key] = json!(bounds);
                }
            }
            context["coordinateSpace"] = json!("image-pixels");
        }
        Ok(
            json!({"dataUrl":frame.png(crop)?,"bounds":region,"source":source,
            "windows":after_windows["windows"],"stable":stable,
            "regionContext":if stable {context} else {Value::Null},
            "browserViewport":if stable {after["browserViewport"].clone()} else {Value::Null},
            "limitation":if stable {after["limitation"].clone()} else {json!("The selected content changed during capture.")}}),
        )
    }
}
