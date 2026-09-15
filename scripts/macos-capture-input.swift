import CoreGraphics
import Foundation
import ImageIO

// Opt-in acceptance input for the real macOS screenshot selector.
func mouse(_ type: CGEventType, _ x: Double, _ y: Double) {
  let event = CGEvent(mouseEventSource: nil, mouseType: type,
                      mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left)!
  event.post(tap: .cghidEventTap)
}
if CommandLine.arguments.dropFirst().first == "inspect" {
  let url = URL(fileURLWithPath: CommandLine.arguments[2])
  let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
  let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
  let width = image.width, height = image.height
  var pixels = [UInt8](repeating: 0, count: width * height * 4)
  pixels.withUnsafeMutableBytes { buffer in
    let bitmap = CGContext(data: buffer.baseAddress, width: width, height: height,
      bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)!
    bitmap.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
  }
  var visible = 0, samples = 0
  for y in (height / 4)..<(height * 3 / 4) {
    for x in (width / 4)..<(width * 3 / 4) {
      let offset = (y * width + x) * 4
      if Int(pixels[offset]) + Int(pixels[offset + 1]) + Int(pixels[offset + 2]) > 48 {
        visible += 1
      }
      samples += 1
    }
  }
  let fraction = Double(visible) / Double(samples)
  print("{\"nonBlackFraction\":\(fraction),\"sampledPixels\":\(samples)}")
} else if CommandLine.arguments.dropFirst().first == "cancel" {
  CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true)!.post(tap: .cghidEventTap)
  Thread.sleep(forTimeInterval: 0.1)
  CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false)!.post(tap: .cghidEventTap)
} else {
  mouse(.mouseMoved, 120, 140)
  Thread.sleep(forTimeInterval: 0.15)
  mouse(.leftMouseDown, 120, 140)
  for step in 1...12 {
    Thread.sleep(forTimeInterval: 0.03)
    mouse(.leftMouseDragged, 120 + Double(step) * 10, 140 + Double(step) * 80 / 12)
  }
  mouse(.leftMouseUp, 240, 220)
}
