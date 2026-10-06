import Cocoa

// Compile together with src/Focalet.Capture.Mac/MacRegionSelector.swift. Exercises selection
// and Retina crop geometry without screen access, UI input, or user data.
@main
struct MacRegionSelectionTests {
  @MainActor
  static func main() {
    var state = MacRegionSelectionState()
    let screen = CGSize(width: 400, height: 300)
    state.append(displayIndex: 0, start: CGPoint(x: 120, y: 100), end: CGPoint(x: 20, y: 30), size: screen)
    assert(state.regions[0].rect == CGRect(x: 20, y: 30, width: 100, height: 70))
    state.append(displayIndex: 1, start: CGPoint(x: 50, y: 60), end: CGPoint(x: 90, y: 90), size: screen)
    assert(state.regions.map(\.displayIndex) == [0, 1])
    state.undo()
    assert(state.regions.count == 1)
    // Identical regions are ignored; tiny gestures do not attach pixels.
    state.append(displayIndex: 0, start: CGPoint(x: 20, y: 30), end: CGPoint(x: 120, y: 100), size: screen)
    state.append(displayIndex: 0, start: .zero, end: CGPoint(x: 2, y: 2), size: screen)
    assert(state.regions.count == 1)
    for index in 1...10 {
      state.append(displayIndex: index, start: CGPoint(x: -10, y: -20), end: CGPoint(x: 450, y: 400), size: screen)
    }
    assert(state.regions.count == 8)
    assert(state.regions.last!.rect == CGRect(origin: .zero, size: screen))
    let pixels = MacRegionSelectionState.pixelRect(state.regions[0].rect, screenSize: screen,
                                                  imageSize: CGSize(width: 800, height: 600))
    assert(pixels == CGRect(x: 40, y: 60, width: 200, height: 140))
    let fractional = MacRegionSelectionState.pixelRect(CGRect(x: 0.25, y: 0.25, width: 5, height: 5),
      screenSize: screen, imageSize: CGSize(width: 800, height: 600))
    assert(fractional == CGRect(x: 0, y: 0, width: 11, height: 11))
    let context = CGContext(data: nil, width: 800, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(NSColor.red.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
    let cropped = context.makeImage()!.cropping(to: pixels)!
    let png = NSBitmapImageRep(cgImage: cropped).representation(using: .png, properties: [:])!
    let decoded = NSBitmapImageRep(data: png)!
    assert(decoded.pixelsWide == 200 && decoded.pixelsHigh == 140)
    assert(decoded.colorAt(x: 10, y: 10)!.redComponent > 0.9)
    let stroke = MacCaptureStroke(tool: "Arrow", points: [CGPoint(x: 30, y: 40), CGPoint(x: 100, y: 60)], color: .blue)
    let annotated = try! MacCaptureStroke.render(cropped, state.regions[0].rect, [stroke])
    let marked = NSBitmapImageRep(data: annotated)!
    assert(marked.pixelsWide == decoded.pixelsWide && marked.pixelsHigh == decoded.pixelsHigh)
    assert(marked.colorAt(x: 190, y: 130)!.redComponent > 0.9, "Unmarked pixels changed")
    assert(marked.colorAt(x: 90, y: 40)!.blueComponent > 0.9, "Retina annotation coordinates drifted")
    assert(decoded.colorAt(x: 90, y: 40)!.redComponent > 0.9, "Annotation mutated the frozen source")
    let description = stroke.metadata(state.regions[0].rect, 200, 140)
    assert(description["coordinateSpace"] as? String == "image-pixels")
    for _ in 0..<10 { state.undo() }
    assert(state.regions.isEmpty)
    let birth = MacRegionCaptureBackend.processStartToken(getpid())
    assert(birth != nil && birth == MacRegionCaptureBackend.processStartToken(getpid()))
    assert(MacRegionCaptureBackend.processStartToken(-1) == nil)
    func window(_ id: String, _ bounds: CGRect) -> [String: Any] {
      ["nativeWindowId": id, "bounds": MacRegionCaptureBackend.json(bounds), "windowTitle": id]
    }
    let document = window("document", CGRect(x: 100, y: 100, width: 500, height: 400))
    let crop = CGRect(x: 200, y: 200, width: 100, height: 100)
    let indicator = window("StatusIndicator", CGRect(x: 1000, y: 0, width: 28, height: 28))
    let stable = MacRegionCaptureBackend.stableWindows(before: [document], after: [indicator, document])
    assert(MacRegionCaptureBackend.sourceAt(stable, crop)?["nativeWindowId"] as? String == "document")
    let overlay = window("overlay", crop)
    let covered = MacRegionCaptureBackend.stableWindows(before: [document], after: [overlay, document])
    assert(MacRegionCaptureBackend.sourceAt(covered, crop) == nil)
    let removed = MacRegionCaptureBackend.stableWindows(before: [overlay, document], after: [document])
    assert(MacRegionCaptureBackend.sourceAt(removed, crop) == nil)
    let movedOverlay = window("overlay", crop.offsetBy(dx: 120, dy: 0))
    let moved = MacRegionCaptureBackend.stableWindows(before: [overlay, document], after: [movedOverlay, document])
    assert(MacRegionCaptureBackend.sourceAt(moved, crop) == nil)
    assert(MacRegionCaptureBackend.sourceAt(moved, crop.offsetBy(dx: 120, dy: 0)) == nil)
    let reordered = MacRegionCaptureBackend.stableWindows(before: [overlay, document], after: [document, overlay])
    assert(MacRegionCaptureBackend.sourceAt(reordered, crop) == nil)
    var renamed = document
    renamed["windowTitle"] = "different document"
    let changed = MacRegionCaptureBackend.stableWindows(before: [document], after: [renamed])
    assert(MacRegionCaptureBackend.sourceAt(changed, crop) == nil)
    print("Passed: reverse drag, display/order retention, undo, duplicates, minimum size, eight-region limit, edge clamping, Retina/fractional crop, PNG round trip")
    print("Passed: recording indicator preserves unrelated context; added/removed/moved overlays, changed titles and overlapping window reorders block stale context")
  }
}
