import Cocoa
import ScreenCaptureKit
import ApplicationServices

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

struct MacScreenSnapshot {
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

  static func captureScreens() async throws -> [MacScreenSnapshot] {
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

/// Native screen and AX observations for the shared multi-region drawing editor.
/// No input is sent to the observed application, and password subtrees are omitted.
@MainActor
enum MacRegionCaptureBackend {
  static func rect(_ value: [String: Any]) -> CGRect {
    func number(_ key: String) -> CGFloat { CGFloat((value[key] as? NSNumber)?.doubleValue ?? 0) }
    return CGRect(x: number("x"), y: number("y"), width: number("width"), height: number("height"))
  }
  static func json(_ value: CGRect) -> [String: Any] {
    ["x": value.minX, "y": value.minY, "width": value.width, "height": value.height]
  }
  private static func screenBounds(_ screen: NSScreen) -> CGRect {
    let top = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
    return CGRect(x: screen.frame.minX, y: top - screen.frame.maxY,
                  width: screen.frame.width, height: screen.frame.height)
  }
  private static func windows() -> [[String: Any]] {
    let entries = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    return entries.compactMap { entry in
      guard let pid = entry[kCGWindowOwnerPID as String] as? Int32,
            pid != ProcessInfo.processInfo.processIdentifier,
            let id = entry[kCGWindowNumber as String] as? Int,
            let dictionary = entry[kCGWindowBounds as String] as? [String: Any],
            let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary),
            bounds.width > 0, bounds.height > 0,
            (entry[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { return nil }
      let app = NSRunningApplication(processIdentifier: pid)
      var source: [String: Any] = [
        "nativeWindowId": String(id), "processId": pid, "platform": "macos", "provider": "macos-ax",
        "hostName": Host.current().localizedName ?? "Mac", "bounds": json(bounds), "windowBounds": json(bounds),
        "application": app?.localizedName ?? entry[kCGWindowOwnerName as String] as? String ?? "Application",
        "processName": app?.bundleIdentifier ?? "application",
        "windowTitle": entry[kCGWindowName as String] as? String ?? "",
      ]
      if let date = app?.launchDate { source["processStartToken"] = String(date.timeIntervalSince1970) }
      return source
    }
  }
  private static func sourceAt(_ windows: [[String: Any]], _ region: CGRect) -> [String: Any]? {
    for window in windows {
      let bounds = rect(window["bounds"] as? [String: Any] ?? [:])
      if !bounds.intersects(region) { continue }
      return bounds.contains(region) ? window : nil
    }
    return nil
  }
  private static func equal(_ a: Any, _ b: Any) -> Bool {
    guard let left = try? JSONSerialization.data(withJSONObject: a, options: [.sortedKeys, .fragmentsAllowed]),
          let right = try? JSONSerialization.data(withJSONObject: b, options: [.sortedKeys, .fragmentsAllowed]) else { return false }
    return left == right
  }
  private static func dataURL(_ image: CGImage) throws -> String {
    guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
      throw MacRegionSelectionError.captureUnavailable
    }
    return "data:image/png;base64,\(png.base64EncodedString())"
  }
  static func captureDisplays() async throws -> [String: Any] {
    let before = windows()
    let screens = try await MacRegionSelector.captureScreens()
    let after = windows()
    return ["frames": try screens.enumerated().map { index, snapshot -> [String: Any] in
      ["dataUrl": try dataURL(snapshot.image), "bounds": json(screenBounds(snapshot.screen)),
       "windows": equal(before, after) ? before : [], "label": "Display \(index + 1)",
       "coordinateSpace": "screen-points"]
    }]
  }
  static func observe(_ value: [String: Any]) async throws -> [String: Any] {
    let region = rect(value)
    guard region.width > 0, region.height > 0,
          [region.minX, region.minY, region.width, region.height].allSatisfy({ $0.isFinite }) else {
      throw MacRegionSelectionError.captureUnavailable
    }
    let beforeWindows = windows()
    let source = sourceAt(beforeWindows, region)
    let screens = try await MacRegionSelector.captureScreens()
    guard let screen = screens.first(where: { screenBounds($0.screen).contains(region) }) else {
      throw MacRegionSelectionError.captureUnavailable
    }
    let desktop = screenBounds(screen.screen)
    let local = region.offsetBy(dx: -desktop.minX, dy: -desktop.minY)
    let pixels = MacRegionSelectionState.pixelRect(local, screenSize: desktop.size,
      imageSize: CGSize(width: screen.image.width, height: screen.image.height))
    guard let crop = screen.image.cropping(to: pixels) else { throw MacRegionSelectionError.captureUnavailable }
    let scaleX = CGFloat(crop.width) / region.width
    let scaleY = CGFloat(crop.height) / region.height
    let before = source.map { accessibility($0, region, scaleX, scaleY) } ?? ["limitation": "The region has no single unobscured source window."]
    // Read pixels again between the two AX observations. The caller compares
    // them with the original frozen crop before retaining any metadata.
    let currentScreens = try await MacRegionSelector.captureScreens()
    guard let current = currentScreens.first(where: { screenBounds($0.screen) == desktop }),
          let currentCrop = current.image.cropping(to: pixels) else { throw MacRegionSelectionError.captureUnavailable }
    let after = source.map { accessibility($0, region, scaleX, scaleY) } ?? before
    let afterWindows = windows()
    let stable = equal(source ?? [:], sourceAt(afterWindows, region) ?? [:]) && equal(before, after)
    var result: [String: Any] = ["dataUrl": try dataURL(currentCrop), "bounds": json(region),
      "windows": afterWindows, "stable": stable,
      "limitation": stable ? before["limitation"] ?? "" : "The source or accessible content changed during capture."]
    result["source"] = source
    if stable {
      result["regionContext"] = before["regionContext"]
      result["browserViewport"] = before["browserViewport"]
    }
    return result
  }

  private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
  }
  private static func elementBounds(_ element: AXUIElement) -> CGRect? {
    guard let p = attribute(element, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
          let s = attribute(element, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero; var size = CGSize.zero
    guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size),
          point.x.isFinite, point.y.isFinite, size.width.isFinite, size.height.isFinite else { return nil }
    return CGRect(origin: point, size: size)
  }
  private static func accessibility(_ source: [String: Any], _ region: CGRect, _ scaleX: CGFloat, _ scaleY: CGFloat) -> [String: Any] {
    guard AXIsProcessTrusted(), let pid = source["processId"] as? Int32 else {
      return ["limitation": "Accessibility is unavailable. Enable Zommi in System Settings → Privacy & Security → Accessibility, then retry."]
    }
    let started = ProcessInfo.processInfo.systemUptime
    let application = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(application, 0.04)
    let native = rect(source["bounds"] as? [String: Any] ?? [:])
    let candidates = (attribute(application, kAXWindowsAttribute) as? [AXUIElement] ?? []).filter { window in
      guard let bounds = elementBounds(window) else { return false }
      return abs(bounds.minX-native.minX) < 3 && abs(bounds.minY-native.minY) < 3 &&
        abs(bounds.width-native.width) < 3 && abs(bounds.height-native.height) < 3
    }
    guard candidates.count == 1 else { return ["limitation": "The accessibility window could not be aligned with this image."] }
    var stack: [(AXUIElement, String?, Int)] = [(candidates[0], nil, 0)]
    var seen = Set<CFHashCode>()
    var elements: [[String: Any]] = []
    var viewport: CGRect?
    var remaining = 24000
    var truncated = false
    func bounded(_ value: String) -> String {
      let result = String(value.prefix(min(4000, remaining)))
      if result.count < value.count { truncated = true }
      remaining -= result.count
      return result
    }
    func map(_ bounds: CGRect) -> [String: Any] {
      json(CGRect(x: (bounds.minX-region.minX)*scaleX, y: (bounds.minY-region.minY)*scaleY,
                  width: bounds.width*scaleX, height: bounds.height*scaleY))
    }
    while let (element, parent, depth) = stack.popLast() {
      if seen.count >= 800 || elements.count >= 128 || remaining <= 0 || ProcessInfo.processInfo.systemUptime-started > 0.7 { truncated = true; break }
      if depth > 40 || !seen.insert(CFHash(element)).inserted { continue }
      AXUIElementSetMessagingTimeout(element, 0.04)
      let role = attribute(element, kAXRoleAttribute) as? String ?? ""
      let subrole = attribute(element, kAXSubroleAttribute) as? String ?? ""
      if subrole == "AXSecureTextField" || role == "AXSecureTextField" || (attribute(element, "AXProtectedContent") as? Bool) == true ||
          (attribute(element, "AXHidden") as? Bool) == true { continue }
      var retainedParent = parent
      if let bounds = elementBounds(element), bounds.width > 0, bounds.height > 0 {
        if role == "AXWebArea" && bounds.contains(region) { viewport = bounds }
        if bounds.intersects(region) {
          let id = "ax-\(elements.count)"
          let name = bounded(attribute(element, kAXTitleAttribute) as? String ?? attribute(element, "AXLabel") as? String ?? "")
          let description = bounded(attribute(element, kAXDescriptionAttribute) as? String ?? "")
          let rawValue = attribute(element, kAXValueAttribute)
          let text = bounded(rawValue as? String ?? (rawValue as? NSNumber)?.stringValue ?? "")
          var state: [String: Any] = [:]
          for (key, nativeKey) in [("enabled", kAXEnabledAttribute), ("focused", kAXFocusedAttribute), ("selected", kAXSelectedAttribute)] {
            if let value = attribute(element, nativeKey) as? Bool { state[key] = value }
          }
          var writable = DarwinBoolean(false)
          if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &writable) == .success {
            state["editable"] = writable.boolValue && ["AXTextField", "AXTextArea", "AXComboBox"].contains(role)
          }
          if let expanded = attribute(element, "AXExpanded") as? Bool { state["expanded"] = expanded ? "expanded" : "collapsed" }
          if ["AXCheckBox", "AXRadioButton"].contains(role), let value = rawValue as? NSNumber {
            state["toggle"] = value.intValue == 2 ? "mixed" : value.boolValue ? "on" : "off"
          }
          var item: [String: Any] = ["id": id, "provider": "macos-ax", "role": role, "name": name,
            "text": text, "value": text, "description": description, "state": state, "bounds": map(bounds),
            "visibleBounds": map(bounds.intersection(region)), "relation": region.contains(bounds) ? "inside" : "intersects"]
          item["parentId"] = parent
          if let identifier = attribute(element, "AXIdentifier") as? String, !identifier.isEmpty, identifier.count <= 256 {
            item["nativeIds"] = ["identifier": identifier]
          }
          if let url = attribute(element, kAXURLAttribute) as? URL { item["href"] = bounded(url.absoluteString) }
          elements.append(item)
          retainedParent = id
        }
      }
      let children = attribute(element, "AXVisibleChildren") as? [AXUIElement] ?? attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
      if children.count > 800 { truncated = true }
      for child in children.prefix(800).reversed() { stack.append((child, retainedParent, depth+1)) }
    }
    var result: [String: Any] = ["regionContext": ["version": 1, "selectionKind": "bbox", "coordinateSpace": "image-pixels", "elements": elements, "truncated": truncated],
      "limitation": "Captured macOS Accessibility. Intersecting elements may expose labels beyond the crop; the image is the selected content."]
    if let viewport = viewport { result["browserViewport"] = json(viewport) }
    return result
  }
}
