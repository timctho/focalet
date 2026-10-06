use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq)]
pub(crate) struct Bounds {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl Bounds {
    pub fn valid(self) -> bool {
        [self.x, self.y, self.width, self.height]
            .iter()
            .all(|v| v.is_finite())
            && self.width > 0.0
            && self.height > 0.0
    }
    pub fn intersects(self, other: Self) -> bool {
        self.valid()
            && other.valid()
            && self.x < other.x + other.width
            && other.x < self.x + self.width
            && self.y < other.y + other.height
            && other.y < self.y + self.height
    }
    pub fn contains(self, other: Self) -> bool {
        self.valid()
            && other.valid()
            && other.x >= self.x
            && other.y >= self.y
            && other.x + other.width <= self.x + self.width + 0.001
            && other.y + other.height <= self.y + self.height + 0.001
    }
    pub fn intersect(self, other: Self) -> Self {
        let x = self.x.max(other.x);
        let y = self.y.max(other.y);
        Self {
            x,
            y,
            width: (self.x + self.width).min(other.x + other.width) - x,
            height: (self.y + self.height).min(other.y + other.height) - y,
        }
    }
    pub fn relative_to(self, region: Self) -> Self {
        Self {
            x: self.x - region.x,
            y: self.y - region.y,
            ..self
        }
    }
    pub fn pixels(self, monitor: Self, width: u32, height: u32) -> Option<(u32, u32, u32, u32)> {
        if !monitor.contains(self) {
            return None;
        }
        let sx = f64::from(width) / monitor.width;
        let sy = f64::from(height) / monitor.height;
        let x = ((self.x - monitor.x) * sx).round() as u32;
        let y = ((self.y - monitor.y) * sy).round() as u32;
        let w = (self.width * sx).round() as u32;
        let h = (self.height * sy).round() as u32;
        (w > 0 && h > 0 && x.checked_add(w)? <= width && y.checked_add(h)? <= height)
            .then_some((x, y, w, h))
    }
}

pub(crate) fn source_at(windows: &[Value], region: Bounds) -> Option<Value> {
    for window in windows {
        let bounds: Bounds = serde_json::from_value(window.get("bounds")?.clone()).ok()?;
        if !bounds.valid() {
            return None;
        }
        if !bounds.intersects(region) {
            continue;
        }
        return (bounds.contains(region)
            && window["processId"].as_u64().is_some_and(|pid| pid > 0))
        .then(|| window.clone());
    }
    None
}

pub(crate) fn accessibility_origin(root: Bounds, frame: Bounds, buffer: Bounds) -> Option<Bounds> {
    if !root.valid() || root.x.abs() > 2.0 || root.y.abs() > 2.0 {
        return None;
    }
    let matches = |native: Bounds| {
        native.valid()
            && (root.width - native.width).abs() <= 2.0
            && (root.height - native.height).abs() <= 2.0
    };
    match (matches(frame), matches(buffer)) {
        (true, false) => Some(frame),
        (false, true) => Some(buffer),
        (true, true) if frame == buffer => Some(frame),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn maps_fractional_scale_and_negative_monitor_origin() {
        let monitor = Bounds {
            x: -1536.,
            y: 0.,
            width: 1536.,
            height: 864.,
        };
        let region = Bounds {
            x: -1520.,
            y: 24.,
            width: 320.,
            height: 200.,
        };
        assert_eq!(region.pixels(monitor, 1920, 1080), Some((20, 30, 400, 250)));
        assert!(
            Bounds {
                x: -1540.,
                ..region
            }
            .pixels(monitor, 1920, 1080)
            .is_none()
        );
    }
    #[test]
    fn foreground_obstruction_never_borrows_background_context() {
        let region = Bounds {
            x: 10.,
            y: 10.,
            width: 40.,
            height: 40.,
        };
        let back = json!({"processId": 42, "bounds": {"x":0,"y":0,"width":100,"height":100}});
        let front = json!({"bounds": {"x":20,"y":20,"width":10,"height":10}});
        assert!(source_at(&[front, back.clone()], region).is_none());
        assert_eq!(
            source_at(std::slice::from_ref(&back), region),
            Some(back.clone())
        );
    }
    #[test]
    fn accessibility_binds_only_a_unique_native_geometry() {
        let frame = Bounds {
            x: 100.,
            y: 50.,
            width: 720.,
            height: 400.,
        };
        let buffer = Bounds {
            x: 86.,
            y: 38.,
            width: 748.,
            height: 429.,
        };
        let root = |bounds: Bounds| Bounds {
            x: 0.,
            y: 0.,
            ..bounds
        };
        assert_eq!(
            accessibility_origin(root(frame), frame, buffer),
            Some(frame)
        );
        assert_eq!(
            accessibility_origin(root(buffer), frame, buffer),
            Some(buffer)
        );
        assert!(accessibility_origin(root(frame), frame, Bounds { x: 90., ..frame }).is_none());
        assert!(
            accessibility_origin(
                root(Bounds {
                    width: 600.,
                    ..frame
                }),
                frame,
                buffer
            )
            .is_none()
        );
    }
}
