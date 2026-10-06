import Cocoa
import FlutterMacOS
import ApplicationServices
import CoreGraphics

class MainFlutterWindow: NSWindow {
  private var capturePermissionsChannel: FlutterMethodChannel?
  private var activationObserver: NSObjectProtocol?
  private var lastExternalApplication: NSRunningApplication?
  private var regionSelector: MacRegionSelector?
  private var requestedScreenRecording = false

  deinit {
    if let observer = activationObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(observer)
    }
  }

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    flutterViewController.backgroundColor = .clear
    isOpaque = false
    backgroundColor = .clear
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    let ownPID = ProcessInfo.processInfo.processIdentifier
    if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ownPID {
      lastExternalApplication = front
    }
    activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
    ) { [weak self] notification in
      guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
            app.processIdentifier != ownPID else { return }
      self?.lastExternalApplication = app
    }

    let channel = FlutterMethodChannel(
      name: "focalet/capture_permissions",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      if call.method == "captureDisplays" || call.method == "observeRegion" {
        Task { @MainActor in
          do {
            if call.method == "captureDisplays" {
              result(try await MacRegionCaptureBackend.captureDisplays())
            } else {
              let arguments = call.arguments as? [String: Any] ?? [:]
              result(try await MacRegionCaptureBackend.observe(arguments["bounds"] as? [String: Any] ?? [:]))
            }
          } catch {
            result(FlutterError(code: "capture-failed", message: error.localizedDescription, details: nil))
          }
        }
        return
      }
      if call.method == "selectRegions" {
        guard let self = self, self.regionSelector == nil else {
          result(FlutterError(code: "selection-in-progress", message: "A selection is already open", details: nil))
          return
        }
        let selector = MacRegionSelector()
        self.regionSelector = selector
        selector.start { [weak self] selected in
          self?.regionSelector = nil
          switch selected {
          case .success(let regions): result(regions)
          case .failure(let error):
            result(FlutterError(code: "capture-failed", message: error.localizedDescription, details: nil))
          }
        }
        return
      }
      if call.method == "cancelSelection" {
        self?.regionSelector?.cancel()
        result(nil)
        return
      }
      if call.method == "hideForCapture" {
        // Ordering out one window leaves Focalet frontmost. Hiding the app also
        // returns activation to the external app whose context is requested.
        let target = self?.lastExternalApplication
        if let target = target, !target.isTerminated {
          let activated = target.activate(options: [.activateIgnoringOtherApps])
          if ProcessInfo.processInfo.environment["FOCALET_MACOS_CAPTURE_PROBE"] != nil {
            print("macOS capture: restore \(target.localizedName ?? "external app") activated=\(activated)")
          }
        }
        self?.orderOut(nil)
        NSApp.hide(nil)
        result(nil)
        return
      }
      if call.method == "request" {
        let arguments = call.arguments as? [String: Any]
        switch arguments?["permission"] as? String {
        case "accessibility":
          let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
          _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        case "screenRecording":
          // Only the guide's explicit button requests access. Repeated checks
          // and repeated Settings visits must not stack native consent prompts.
          if !CGPreflightScreenCaptureAccess(), self?.requestedScreenRecording == false {
            self?.requestedScreenRecording = true
            _ = CGRequestScreenCaptureAccess()
          }
          if !CGPreflightScreenCaptureAccess(),
             let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
          }
        default:
          result(FlutterError(code: "invalid-permission", message: "Unknown capture permission", details: nil))
          return
        }
      } else if call.method != "status" {
        result(FlutterMethodNotImplemented)
        return
      }
      result([
        "accessibility": AXIsProcessTrusted(),
        "screenRecording": CGPreflightScreenCaptureAccess(),
      ])
    }
    capturePermissionsChannel = channel

    super.awakeFromNib()
  }
}
