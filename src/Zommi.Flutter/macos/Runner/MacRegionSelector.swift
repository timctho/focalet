import Cocoa
import ScreenCaptureKit

struct MacSelectedRegion: Equatable {
  let displayIndex: Int
  // Coordinates are points from the top-left of this display.
  let rect: CGRect
}

struct MacRegionSelectionState {
  static let maximumSelections = 8
  private(set) var regions: [MacSelectedRegion] = []

  mutating func append(displayIndex: Int, start: CGPoint, end: CGPoint, size: CGSize) {
    let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                      width: abs(end.x - start.x), height: abs(end.y - start.y))
      .intersection(CGRect(origin: .zero, size: size))
    let region = MacSelectedRegion(displayIndex: displayIndex, rect: rect)
    guard !rect.isNull, rect.width >= 4, rect.height >= 4,
          regions.count < Self.maximumSelections, !regions.contains(region) else { return }
    regions.append(region)
  }

  mutating func undo() {
    if !regions.isEmpty { regions.removeLast() }
  }

  static func pixelRect(_ rect: CGRect, screenSize: CGSize, imageSize: CGSize) -> CGRect {
    CGRect(x: rect.minX * imageSize.width / screenSize.width,
           y: rect.minY * imageSize.height / screenSize.height,
           width: rect.width * imageSize.width / screenSize.width,
           height: rect.height * imageSize.height / screenSize.height)
      .integral.intersection(CGRect(origin: .zero, size: imageSize))
  }
}

private struct MacScreenSnapshot {
  let screen: NSScreen
  let image: CGImage
}

enum MacRegionSelectionError: LocalizedError {
  case captureUnavailable
  var errorDescription: String? {
    "Could not capture the display. Check Screen Recording for Zommi, then reopen Zommi and try again."
  }
}

/// Keeps full-screen pixels in memory only while choosing regions. Crops come
/// from the undimmed snapshot, so borders, labels and the toolbar cannot leak
/// into attachments, and every box refers to the same observed screen state.
@MainActor
final class MacRegionSelector {
  private var snapshots: [MacScreenSnapshot] = []
  private var windows: [MacRegionOverlayWindow] = []
  private var completion: ((Result<[[String: Any]], Error>) -> Void)?
  private var displayObserver: NSObjectProtocol?
  private let selectionId = UUID().uuidString
  private(set) var state = MacRegionSelectionState()

  func start(completion: @escaping (Result<[[String: Any]], Error>) -> Void) {
    self.completion = completion
    displayObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
    ) { [weak self] _ in Task { @MainActor in self?.cancel() } }
    Task {
      do {
        let captured = try await Self.captureScreens()
        guard self.completion != nil else { return }
        snapshots = captured
        showOverlays()
      } catch {
        finish(.failure(error))
      }
    }
  }

  private static func captureScreens() async throws -> [MacScreenSnapshot] {
    guard CGPreflightScreenCaptureAccess(), !NSScreen.screens.isEmpty else {
      throw MacRegionSelectionError.captureUnavailable
    }
    let screens = NSScreen.screens
    var result: [MacScreenSnapshot] = []
    if #available(macOS 14.0, *) {
      let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
      for screen in screens {
        let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        guard let display = content.displays.first(where: { $0.displayID == id }) else {
          throw MacRegionSelectionError.captureUnavailable
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = Int(screen.frame.width * screen.backingScaleFactor)
        configuration.height = Int(screen.frame.height * screen.backingScaleFactor)
        configuration.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        result.append(MacScreenSnapshot(screen: screen, image: image))
      }
    } else {
      // macOS 12/13 predate SCScreenshotManager. Capture each display without
      // its interactive selector, then use the same multi-region overlay.
      for (index, screen) in screens.enumerated() {
        let image = try await legacyScreenshot(displayNumber: index + 1)
        result.append(MacScreenSnapshot(screen: screen, image: image))
      }
    }
    return result
  }

  private static func legacyScreenshot(displayNumber: Int) async throws -> CGImage {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("zommi-display-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: path) }
        do {
          let process = Process()
          process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
          process.arguments = ["-x", "-D", String(displayNumber), path.path]
          process.standardError = FileHandle.nullDevice
          try process.run()
          process.waitUntilExit()
          guard process.terminationStatus == 0,
                let data = try? Data(contentsOf: path),
                let image = NSBitmapImageRep(data: data)?.cgImage else {
            throw MacRegionSelectionError.captureUnavailable
          }
          continuation.resume(returning: image)
        } catch { continuation.resume(throwing: error) }
      }
    }
  }

  private func showOverlays() {
    NSApp.unhideWithoutActivation()
    for (index, snapshot) in snapshots.enumerated() {
      let window = MacRegionOverlayWindow(contentRect: snapshot.screen.frame,
                                         styleMask: .borderless, backing: .buffered, defer: false)
      window.title = "Zommi content selection"
      window.level = .screenSaver
      window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
      window.hasShadow = false
      window.isReleasedWhenClosed = false
      window.contentView = MacRegionOverlayView(snapshot: snapshot, displayIndex: index, selector: self)
      windows.append(window)
      window.orderFrontRegardless()
    }
    NSApp.activate(ignoringOtherApps: true)
    let active = windows.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? windows.first
    active?.makeKeyAndOrderFront(nil)
    active?.makeFirstResponder(active?.contentView)
    trace("ready")
  }

  func append(displayIndex: Int, start: CGPoint, end: CGPoint) {
    state.append(displayIndex: displayIndex, start: start, end: end, size: snapshots[displayIndex].screen.frame.size)
    refresh()
  }

  func undo() { state.undo(); refresh() }
  func cancel() { finish(.success([])) }

  private func refresh() {
    for window in windows { (window.contentView as? MacRegionOverlayView)?.refresh() }
  }

  func attach() {
    guard !state.regions.isEmpty else { return }
    do {
      let results = try state.regions.map { region -> [String: Any] in
        let snapshot = snapshots[region.displayIndex]
        let pixelRect = MacRegionSelectionState.pixelRect(region.rect, screenSize: snapshot.screen.frame.size,
                                                         imageSize: CGSize(width: snapshot.image.width, height: snapshot.image.height))
        guard let crop = snapshot.image.cropping(to: pixelRect),
              let png = NSBitmapImageRep(cgImage: crop).representation(using: .png, properties: [:]) else {
          throw MacRegionSelectionError.captureUnavailable
        }
        // Global coordinates use the top-left of the primary display, matching
        // the attachment contract; scale is recorded separately from points.
        let primaryTop = snapshots[0].screen.frame.maxY
        let frame = snapshot.screen.frame
        let bounds: [String: Any] = ["x": frame.minX + region.rect.minX,
                                     "y": primaryTop - frame.maxY + region.rect.minY,
                                     "width": region.rect.width, "height": region.rect.height]
        let mapping: [String: Any] = [
          "imageBounds": ["x": 0, "y": 0, "width": crop.width, "height": crop.height],
          "scaleX": CGFloat(snapshot.image.width) / frame.width,
          "scaleY": CGFloat(snapshot.image.height) / frame.height,
          "coordinateSpace": "screen-points",
        ]
        let alignment: [String: Any] = ["status": "image-only", "screenBounds": bounds,
                                       "mapping": mapping, "reason": "No aligned text was exposed for this region."]
        return ["dataUrl": "data:image/png;base64,\(png.base64EncodedString())",
                "bounds": bounds, "alignment": alignment,
                "snapshot": ["region": alignment,
                             "source": ["platform": "macos", "hostName": Host.current().localizedName ?? "Mac"],
                             "application": "Screen"]]
      }
      finish(.success(results))
    } catch { finish(.failure(error)) }
  }

  private func finish(_ result: Result<[[String: Any]], Error>) {
    guard let callback = completion else { return }
    completion = nil
    if let observer = displayObserver { NotificationCenter.default.removeObserver(observer) }
    displayObserver = nil
    for window in windows { window.orderOut(nil); window.close() }
    windows.removeAll()
    snapshots.removeAll()
    NSCursor.arrow.set()
    trace("closed")
    callback(result)
  }

  private func trace(_ event: String) {
    if ProcessInfo.processInfo.environment["ZOMMI_MACOS_INTERACTIVE_PROBE"] == "1" {
      print("macOS selector: \(event) \(selectionId)")
      fflush(stdout)
    }
  }
}

private final class MacRegionOverlayWindow: NSWindow {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }
}

@MainActor
private final class MacRegionOverlayView: NSView {
  private let snapshot: MacScreenSnapshot
  private let displayIndex: Int
  private weak var selector: MacRegionSelector?
  private var anchor: CGPoint?
  private var dragged: CGRect?
  private let hint = NSTextField(labelWithString: "")
  private let attachButton = NSButton(title: "Attach", target: nil, action: nil)
  private let undoButton = NSButton(title: "Undo", target: nil, action: nil)

  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }

  init(snapshot: MacScreenSnapshot, displayIndex: Int, selector: MacRegionSelector) {
    self.snapshot = snapshot
    self.displayIndex = displayIndex
    self.selector = selector
    super.init(frame: CGRect(origin: .zero, size: snapshot.screen.frame.size))
    let toolbar = NSVisualEffectView()
    toolbar.material = .hudWindow
    toolbar.state = .active
    toolbar.appearance = NSAppearance(named: .darkAqua)
    toolbar.wantsLayer = true
    toolbar.layer?.cornerRadius = 12
    toolbar.translatesAutoresizingMaskIntoConstraints = false
    let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
    attachButton.target = self; attachButton.action = #selector(attach)
    undoButton.target = self; undoButton.action = #selector(undo)
    for button in [attachButton, undoButton, cancelButton] { button.bezelStyle = .rounded }
    hint.font = .systemFont(ofSize: 13)
    let stack = NSStackView(views: [hint, undoButton, cancelButton, attachButton])
    stack.spacing = 12
    stack.translatesAutoresizingMaskIntoConstraints = false
    toolbar.addSubview(stack)
    addSubview(toolbar)
    let topInset = snapshot.screen.frame.maxY - snapshot.screen.visibleFrame.maxY + 16
    NSLayoutConstraint.activate([
      toolbar.topAnchor.constraint(equalTo: topAnchor, constant: topInset),
      toolbar.centerXAnchor.constraint(equalTo: centerXAnchor),
      toolbar.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -24),
      stack.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 16),
      stack.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -16),
      stack.topAnchor.constraint(equalTo: toolbar.topAnchor, constant: 12),
      stack.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: -12),
    ])
    refresh()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

  func refresh() {
    let count = selector?.state.regions.count ?? 0
    hint.stringValue = count == 0 ? "Drag boxes · Enter to attach · Esc to cancel" : "\(count)/8 selected · Drag another box · Enter to attach"
    attachButton.isEnabled = count > 0
    undoButton.isEnabled = count > 0
    needsDisplay = true
  }

  @objc private func attach() { if anchor == nil { selector?.attach() } }
  @objc private func cancel() { selector?.cancel() }
  @objc private func undo() { if anchor == nil { selector?.undo() } }

  override func keyDown(with event: NSEvent) {
    switch event.keyCode {
    case 36, 76: attach()
    case 53: cancel()
    case 51, 117: undo()
    default: super.keyDown(with: event)
    }
  }

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    anchor = convert(event.locationInWindow, from: nil)
    dragged = nil
  }

  override func mouseDragged(with event: NSEvent) {
    guard let start = anchor else { return }
    let end = convert(event.locationInWindow, from: nil)
    dragged = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                     width: abs(end.x - start.x), height: abs(end.y - start.y)).intersection(bounds)
    needsDisplay = true
  }

  override func mouseUp(with event: NSEvent) {
    guard let start = anchor else { return }
    anchor = nil
    dragged = nil
    selector?.append(displayIndex: displayIndex, start: start, end: convert(event.locationInWindow, from: nil))
  }

  override func rightMouseDown(with event: NSEvent) { cancel() }

  private func drawSnapshot() {
    NSImage(cgImage: snapshot.image, size: bounds.size).draw(in: bounds, from: .zero,
      operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
  }

  override func draw(_ dirtyRect: NSRect) {
    drawSnapshot()
    NSColor.black.withAlphaComponent(0.3).setFill()
    bounds.fill()
    for (index, region) in (selector?.state.regions ?? []).enumerated() where region.displayIndex == displayIndex {
      NSGraphicsContext.saveGraphicsState()
      NSBezierPath(rect: region.rect).addClip()
      drawSnapshot()
      NSGraphicsContext.restoreGraphicsState()
      drawBorder(region.rect, color: .systemCyan)
      let label = CGRect(x: region.rect.minX, y: max(0, region.rect.minY - 24), width: 28, height: 24)
      NSColor.black.setFill(); label.fill()
      ("\(index + 1)" as NSString).draw(at: CGPoint(x: label.minX + 8, y: label.minY + 3), withAttributes: [
        .foregroundColor: NSColor.white, .font: NSFont.boldSystemFont(ofSize: 13),
      ])
    }
    if let rect = dragged, !rect.isNull { drawBorder(rect, color: .white) }
  }

  private func drawBorder(_ rect: CGRect, color: NSColor) {
    color.setStroke()
    let border = NSBezierPath(rect: rect)
    border.lineWidth = 2
    border.stroke()
  }
}
