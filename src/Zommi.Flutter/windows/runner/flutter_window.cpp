#include "flutter_window.h"
#include "desktop_snapshot.h"
#include "tray_popup.h"

#include <dwmapi.h>
#include <dxgi.h>
#include <filesystem>
#include <fstream>
#include <cmath>
#include <cstdint>
#include <optional>
#include <string>
#include <utility>
#include <variant>

#include "flutter/generated_plugin_registrant.h"
#include "zommi_instance.h"
#include "utils.h"
#include <flutter/method_result_functions.h>
#include <flutter/standard_method_codec.h>

namespace {

constexpr UINT_PTR kSurfaceHandoffTimer = 0x5a41;

std::optional<double> NumberArgument(const flutter::EncodableMap &arguments,
                                     const char *name) {
  const auto iterator =
      arguments.find(flutter::EncodableValue(std::string(name)));
  if (iterator == arguments.end()) {
    return std::nullopt;
  }
  if (const auto *value = std::get_if<double>(&iterator->second)) {
    return *value;
  }
  if (const auto *value = std::get_if<int32_t>(&iterator->second)) {
    return static_cast<double>(*value);
  }
  if (const auto *value = std::get_if<int64_t>(&iterator->second)) {
    return static_cast<double>(*value);
  }
  return std::nullopt;
}

} // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject &project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  window_animation_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "zommi/window_animation",
          &flutter::StandardMethodCodec::GetInstance());
  window_animation_channel_->SetMethodCallHandler(
      [this](const auto &call, auto result) {
        HandleWindowAnimationMethodCall(call, std::move(result));
      });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  desktop_snapshot_ = std::make_unique<DesktopSnapshot>();
  tray_popup_ = std::make_unique<TrayPopup>();
  desktop_snapshot_->Prepare(MonitorFromWindow(GetHandle(), MONITOR_DEFAULTTONEAREST));

  wchar_t trace_path[32768]{};
  if (GetEnvironmentVariableW(L"ZOMMI_SCROLL_TRACE", trace_path, 32768) > 0) {
    IDXGIAdapter* adapter = nullptr;
    DXGI_ADAPTER_DESC description{};
    if (flutter_controller_->engine()->GetGraphicsAdapter(&adapter)) {
      adapter->GetDesc(&description);
      adapter->Release();
    }
    DWM_TIMING_INFO timing{};
    timing.cbSize = sizeof(timing);
    DwmGetCompositionTimingInfo(nullptr, &timing);
    std::ofstream output(
        std::filesystem::path(std::wstring(trace_path) + L".graphics.txt"));
    output << "adapter=" << Utf8FromUtf16(description.Description) << "\n"
           << "vendor=" << description.VendorId << "\n"
           << "device=" << description.DeviceId << "\n"
           << "refreshNumerator=" << timing.rateRefresh.uiNumerator << "\n"
           << "refreshDenominator=" << timing.rateRefresh.uiDenominator << "\n"
           << "renderer="
           << (project_.impeller_switch() == flutter::ImpellerSwitch::Disabled
                   ? "skia" : "impeller") << "\n";
  }

  // FlutterDesktopBridge shows the window only after it has applied the
  // compact frameless bounds and monitor anchor. Showing from this first-frame
  // callback races that configuration and exposes the runner template box.
  return true;
}

void FlutterWindow::OnDestroy() {
  if (selection_hotkey_id_) {
    UnregisterHotKey(GetHandle(), selection_hotkey_id_);
    selection_hotkey_id_ = 0;
  }
  if (surface_handoff_result_) {
    surface_handoff_result_->Error("window_closed", "The window was closed.");
    surface_handoff_result_.reset();
  }
  DestroySurfaceHandoff();
  desktop_snapshot_.reset();
  tray_popup_.reset();
  window_animation_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == WM_HOTKEY && selection_hotkey_id_ &&
      wparam == static_cast<WPARAM>(selection_hotkey_id_)) {
    window_animation_channel_->InvokeMethod("selectContent", nullptr);
    return 0;
  }
  if (message == WM_TIMER && surface_handoff_timer_ != 0 &&
      wparam == surface_handoff_timer_) {
    CompleteSurfaceHandoff(true);
    return 0;
  }
  if (surface_handoff_result_ &&
      ((message == WM_SHOWWINDOW && wparam == FALSE) ||
       (message == WM_SIZE && wparam == SIZE_MINIMIZED))) {
    pending_surface_command_ = 0;
    CompleteSurfaceHandoff(true);
  }
  if (message == ZommiShowWindowMessage()) {
    ShowWindow(hwnd, SW_RESTORE);
    SetForegroundWindow(hwnd);
    return 0;
  }
  // Give Flutter, including plugins, an opportunity to handle window messages.
  std::optional<LRESULT> plugin_result;
  if (flutter_controller_) {
    plugin_result = flutter_controller_->HandleTopLevelWindowProc(
        hwnd, message, wparam, lparam);
  }
  if (message == WM_GETMINMAXINFO) {
    MONITORINFO monitor_info{};
    monitor_info.cbSize = sizeof(monitor_info);
    if (GetMonitorInfoW(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST),
                        &monitor_info)) {
      auto *limits = reinterpret_cast<MINMAXINFO *>(lparam);
      const auto &work_area = monitor_info.rcWork;
      const auto &monitor_area = monitor_info.rcMonitor;
      limits->ptMaxPosition = {work_area.left - monitor_area.left,
                               work_area.top - monitor_area.top};
      limits->ptMaxSize = {work_area.right - work_area.left,
                           work_area.bottom - work_area.top};
    }
    return 0;
  }
  if (plugin_result) {
    return *plugin_result;
  }
  if (message == WM_SYSCOMMAND && IsWindowVisible(hwnd) && !IsIconic(hwnd)) {
    const auto command = wparam & 0xfff0;
    const bool maximize = command == SC_MAXIMIZE;
    if (surface_handoff_result_ &&
        (maximize || command == SC_RESTORE)) {
      pending_surface_command_ = command;
      return 0;
    }
    if ((maximize && !IsZoomed(hwnd)) ||
        (command == SC_RESTORE && IsZoomed(hwnd))) {
      RECT target{};
      if (GetSystemSurfaceBounds(maximize, target)) {
        ResizeSurface(target, maximize,
            std::make_unique<flutter::MethodResultFunctions<flutter::EncodableValue>>(
                nullptr, nullptr, nullptr));
        return 0;
      }
    }
  }

  switch (message) {
  case WM_FONTCHANGE:
    flutter_controller_->engine()->ReloadSystemFonts();
    break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

void FlutterWindow::HandleWindowAnimationMethodCall(
    const flutter::MethodCall<flutter::EncodableValue> &call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (call.method_name() == "setSelectionShortcut") {
    const auto* arguments = call.arguments() == nullptr
        ? nullptr : std::get_if<flutter::EncodableMap>(call.arguments());
    if (arguments == nullptr) {
      if (selection_hotkey_id_) UnregisterHotKey(GetHandle(), selection_hotkey_id_);
      selection_hotkey_id_ = 0;
      result->Success();
      return;
    }
    const auto key = NumberArgument(*arguments, "key");
    const auto modifiers = NumberArgument(*arguments, "modifiers");
    if (!key || !modifiers || *key < 1 || *key > 255 ||
        *modifiers < 1 || *modifiers > 15) {
      result->Error("invalid_shortcut", "Choose a modified letter, number or function key.");
      return;
    }
    const auto next_key = static_cast<UINT>(*key);
    const auto next_modifiers = static_cast<UINT>(*modifiers);
    if (selection_hotkey_id_ && selection_hotkey_key_ == next_key &&
        selection_hotkey_modifiers_ == next_modifiers) {
      result->Success();
      return;
    }
    // Reserve the replacement first, so conflicts never discard a working key.
    const int next_id = selection_hotkey_id_ == 0x5a50 ? 0x5a51 : 0x5a50;
    if (!RegisterHotKey(GetHandle(), next_id, next_modifiers | MOD_NOREPEAT, next_key)) {
      result->Error("shortcut_unavailable", "That shortcut is already in use or reserved by Windows.");
      return;
    }
    if (selection_hotkey_id_) UnregisterHotKey(GetHandle(), selection_hotkey_id_);
    selection_hotkey_id_ = next_id;
    selection_hotkey_key_ = next_key;
    selection_hotkey_modifiers_ = next_modifiers;
    result->Success();
    return;
  }
  if (call.method_name() == "showTrayMenu") {
    const auto* arguments = call.arguments() == nullptr
        ? nullptr : std::get_if<flutter::EncodableMap>(call.arguments());
    tray_popup_->Show(arguments ? *arguments : flutter::EncodableMap{}, std::move(result));
    return;
  }
  if (call.method_name() == "surfaceMetricsChanged") {
    const auto* arguments = call.arguments() == nullptr
        ? nullptr : std::get_if<flutter::EncodableMap>(call.arguments());
    const auto width = arguments == nullptr ? std::nullopt : NumberArgument(*arguments, "width");
    const auto height = arguments == nullptr ? std::nullopt : NumberArgument(*arguments, "height");
    RECT client{};
    if (surface_handoff_result_ && width && height &&
        *width == surface_handoff_size_.cx && *height == surface_handoff_size_.cy &&
        GetClientRect(GetHandle(), &client) &&
        client.right == surface_handoff_size_.cx && client.bottom == surface_handoff_size_.cy) {
      AwaitSurfaceFrame();
    }
    result->Success();
    return;
  }
  if (call.method_name() == "getSurfaceGeometry") {
    RECT bounds{};
    MONITORINFO monitor{};
    monitor.cbSize = sizeof(monitor);
    if (!GetWindowRect(GetHandle(), &bounds) ||
        !GetMonitorInfo(MonitorFromWindow(GetHandle(), MONITOR_DEFAULTTONEAREST),
                        &monitor)) {
      result->Error("window_unavailable", "Window geometry is unavailable.");
      return;
    }
    const double scale = GetDpiForWindow(GetHandle()) / 96.0;
    const auto rectangle = [scale](const RECT& value) {
      return flutter::EncodableValue(flutter::EncodableList{
          flutter::EncodableValue(value.left / scale),
          flutter::EncodableValue(value.top / scale),
          flutter::EncodableValue((value.right - value.left) / scale),
          flutter::EncodableValue((value.bottom - value.top) / scale)});
    };
    result->Success(flutter::EncodableValue(flutter::EncodableMap{
        {flutter::EncodableValue("bounds"), rectangle(bounds)},
        {flutter::EncodableValue("workArea"), rectangle(monitor.rcWork)},
        {flutter::EncodableValue("scale"), flutter::EncodableValue(scale)},
        {flutter::EncodableValue("maximized"),
         flutter::EncodableValue(IsZoomed(GetHandle()) != FALSE)}}));
    return;
  }
  if (call.method_name() == "presentPanel") {
    const auto arguments = std::get_if<flutter::EncodableMap>(call.arguments());
    bool focus = true;
    if (arguments != nullptr) {
      const auto entry = arguments->find(flutter::EncodableValue("focus"));
      if (entry != arguments->end()) {
        if (const auto value = std::get_if<bool>(&entry->second)) focus = *value;
      }
    }
    const auto window = GetHandle();
    if (!focus) {
      ShowWindow(window, IsIconic(window) ? SW_SHOWNOACTIVATE : SW_SHOWNA);
      result->Success(flutter::EncodableValue(true));
      return;
    }
    ShowWindow(window, IsIconic(window) ? SW_RESTORE : SW_SHOW);
    const auto foreground = GetForegroundWindow();
    const auto foreground_thread = GetWindowThreadProcessId(foreground, nullptr);
    const auto current_thread = GetCurrentThreadId();
    const bool attached = !SetForegroundWindow(window) &&
                          foreground_thread != 0 &&
                          foreground_thread != current_thread &&
                          AttachThreadInput(current_thread, foreground_thread, TRUE);
    BringWindowToTop(window);
    SetForegroundWindow(window);
    SetFocus(flutter_controller_->view()->GetNativeWindow());
    if (attached) AttachThreadInput(current_thread, foreground_thread, FALSE);
    result->Success(flutter::EncodableValue(GetForegroundWindow() == window));
    return;
  }
  if (call.method_name() == "isPointerWithinWindow") {
    POINT cursor{};
    if (!GetCursorPos(&cursor)) {
      result->Error("cursor_unavailable",
                    "Could not read the current pointer position.");
      return;
    }
    const HWND hit_window = WindowFromPoint(cursor);
    const HWND root_window =
        hit_window == nullptr ? nullptr : GetAncestor(hit_window, GA_ROOT);
    result->Success(flutter::EncodableValue(
        root_window == GetHandle() ||
        (surface_handoff_window_ != nullptr && root_window == surface_handoff_window_)));
    return;
  }
  if (call.method_name() == "configureSurfaceWindow") {
    const auto window = GetHandle();
    SetLastError(ERROR_SUCCESS);
    const LONG_PTR style = GetWindowLongPtr(window, GWL_STYLE);
    if (style == 0 && GetLastError() != ERROR_SUCCESS) {
      result->Error("window_unavailable",
                    "Could not read the Zommi window style.");
      return;
    }
    // Keep the native system/minimize capabilities even though the caption is
    // custom drawn. Windows uses these styles for taskbar click toggling, and
    // window_manager uses SC_MOVE to drag a frameless surface.
    const LONG_PTR surface_style =
        (style & ~WS_POPUP) | WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN |
        WS_CLIPSIBLINGS;
    SetLastError(ERROR_SUCCESS);
    if (SetWindowLongPtr(window, GWL_STYLE, surface_style) == 0 &&
        GetLastError() != ERROR_SUCCESS) {
      result->Error("window_style_failed",
                    "Could not apply the frameless Zommi window style.");
      return;
    }
    if (!SetWindowPos(window, nullptr, 0, 0, 0, 0,
                      SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE |
                          SWP_NOACTIVATE | SWP_NOOWNERZORDER | SWP_NOZORDER)) {
      result->Error("window_style_failed",
                    "Could not refresh the frameless Zommi window style.");
      return;
    }
    const BOOL transitions_disabled = TRUE;
    if (FAILED(DwmSetWindowAttribute(window, DWMWA_TRANSITIONS_FORCEDISABLED,
                                     &transitions_disabled,
                                     sizeof(transitions_disabled)))) {
      result->Error("window_style_failed", "Could not disable window transitions.");
      return;
    }
    result->Success();
    return;
  }
  if (call.method_name() == "toggleSurfaceMaximized") {
    RECT target{};
    const bool maximize = !IsZoomed(GetHandle());
    if (!GetSystemSurfaceBounds(maximize, target)) {
      result->Error("window_unavailable", "Window placement is unavailable.");
      return;
    }
    ResizeSurface(target, maximize, std::move(result));
    return;
  }
  if (call.method_name() != "setSurfaceBounds") {
    result->NotImplemented();
    return;
  }
  const auto *arguments = call.arguments() == nullptr
      ? nullptr : std::get_if<flutter::EncodableMap>(call.arguments());
  if (arguments == nullptr) {
    result->Error("invalid_arguments", "Window bounds are required.");
    return;
  }
  const auto left = NumberArgument(*arguments, "toX");
  const auto top = NumberArgument(*arguments, "toY");
  const auto width = NumberArgument(*arguments, "toWidth");
  const auto height = NumberArgument(*arguments, "toHeight");
  const auto scale = NumberArgument(*arguments, "scaleFactor");
  if (!left || !top || !width || !height || !scale || *scale <= 0 ||
      *width <= 0 || *height <= 0) {
    result->Error("invalid_arguments", "Window bounds are incomplete.");
    return;
  }
  RECT target{};
  target.left = static_cast<LONG>(std::lround(*left * *scale));
  target.top = static_cast<LONG>(std::lround(*top * *scale));
  target.right = target.left + static_cast<LONG>(std::lround(*width * *scale));
  target.bottom = target.top + static_cast<LONG>(std::lround(*height * *scale));
  const auto entry = arguments->find(flutter::EncodableValue("maximized"));
  const auto *maximized = entry == arguments->end()
      ? nullptr : std::get_if<bool>(&entry->second);
  ResizeSurface(target, maximized != nullptr && *maximized, std::move(result));
}

bool FlutterWindow::GetSystemSurfaceBounds(bool maximized, RECT& bounds) {
  MONITORINFO monitor{};
  monitor.cbSize = sizeof(monitor);
  if (!GetMonitorInfo(MonitorFromWindow(GetHandle(), MONITOR_DEFAULTTONEAREST),
                      &monitor)) return false;
  if (maximized) {
    bounds = monitor.rcWork;
    return true;
  }
  WINDOWPLACEMENT placement{};
  placement.length = sizeof(placement);
  if (!GetWindowPlacement(GetHandle(), &placement)) return false;
  bounds = placement.rcNormalPosition;
  if ((GetWindowLongPtr(GetHandle(), GWL_EXSTYLE) & WS_EX_TOOLWINDOW) == 0) {
    OffsetRect(&bounds, monitor.rcWork.left - monitor.rcMonitor.left,
                monitor.rcWork.top - monitor.rcMonitor.top);
  }
  return true;
}

void FlutterWindow::ResizeSurface(
    const RECT& target, bool target_maximized,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (surface_handoff_result_ || surface_handoff_window_ != nullptr) {
    result->Error("window_resize_busy", "A window frame is still pending.");
    return;
  }
  RECT current{};
  if (!GetWindowRect(GetHandle(), &current)) {
    result->Error("window_unavailable", "The current window is unavailable.");
    return;
  }
  if ((target_maximized && IsZoomed(GetHandle())) ||
      (!target_maximized && !IsZoomed(GetHandle()) && EqualRect(&current, &target))) {
    result->Success(flutter::EncodableValue(true));
    return;
  }
  const bool protect_frame =
      IsWindowVisible(GetHandle()) && !IsIconic(GetHandle());
  if (protect_frame && !BeginSurfaceHandoff(target)) {
    result->Error("surface_capture_failed", "Could not preserve the visible window.");
    return;
  }
  if (protect_frame) {
    surface_handoff_result_ = std::move(result);
    surface_handoff_size_ = {target.right - target.left, target.bottom - target.top};
    surface_handoff_applying_ = true;
    surface_handoff_armed_ = false;
    surface_handoff_frame_ready_ = false;
    const auto epoch = ++surface_handoff_epoch_;
    surface_handoff_timer_ = SetTimer(
        GetHandle(), kSurfaceHandoffTimer + static_cast<UINT_PTR>(epoch), 2000, nullptr);
    if (surface_handoff_timer_ == 0) {
      CompleteSurfaceHandoff(true);
      return;
    }
  }
  const auto fail_resize = [&](const char* code, const char* message) {
    auto response = surface_handoff_result_ ? std::move(surface_handoff_result_) : std::move(result);
    DestroySurfaceHandoff();
    if (response) response->Error(code, message);
  };
  if (target_maximized) {
    ShowWindow(GetHandle(), SW_MAXIMIZE);
    if (!IsZoomed(GetHandle())) {
      fail_resize("window_resize_failed", "Could not maximize the window.");
      return;
    }
  } else if (IsZoomed(GetHandle())) {
    WINDOWPLACEMENT placement{};
    placement.length = sizeof(placement);
    MONITORINFO monitor{};
    monitor.cbSize = sizeof(monitor);
    if (!GetWindowPlacement(GetHandle(), &placement) ||
        !GetMonitorInfo(MonitorFromWindow(GetHandle(), MONITOR_DEFAULTTONEAREST), &monitor)) {
      fail_resize("window_unavailable", "Window placement is unavailable.");
      return;
    }
    placement.showCmd = SW_SHOWNOACTIVATE;
    placement.flags = 0;
    placement.rcNormalPosition = target;
    if ((GetWindowLongPtr(GetHandle(), GWL_EXSTYLE) & WS_EX_TOOLWINDOW) == 0) {
      OffsetRect(&placement.rcNormalPosition,
                 monitor.rcMonitor.left - monitor.rcWork.left,
                 monitor.rcMonitor.top - monitor.rcWork.top);
    }
    if (!SetWindowPlacement(GetHandle(), &placement)) {
      fail_resize("window_resize_failed", "Could not restore the window.");
      return;
    }
  } else if (!SetWindowPos(GetHandle(), nullptr, target.left, target.top,
                           target.right - target.left, target.bottom - target.top,
                           SWP_NOACTIVATE | SWP_NOOWNERZORDER | SWP_NOZORDER)) {
    fail_resize("window_resize_failed", "Could not resize the window.");
    return;
  }
  if (!protect_frame) {
    result->Success(flutter::EncodableValue(true));
    return;
  }
  surface_handoff_applying_ = false;
  if (surface_handoff_frame_ready_) CompleteSurfaceHandoff(false);
  else if (!surface_handoff_armed_) AwaitSurfaceFrame();
}

void FlutterWindow::AwaitSurfaceFrame() {
  if (!surface_handoff_result_ || surface_handoff_armed_) return;
  surface_handoff_armed_ = true;
  const auto epoch = surface_handoff_epoch_;
  // Flutter's Windows wrapper already marshals this callback to the platform
  // thread. Another window message delays revealing the completed frame.
  flutter_controller_->engine()->SetNextFrameCallback([this, epoch]() {
    if (epoch != surface_handoff_epoch_ || !surface_handoff_result_) return;
    if (surface_handoff_applying_) surface_handoff_frame_ready_ = true;
    else CompleteSurfaceHandoff(false);
  });
  flutter_controller_->ForceRedraw();
}

bool FlutterWindow::BeginSurfaceHandoff(const RECT& target) {
  RECT bounds{};
  RECT combined{};
  RECT visible{};
  const RECT desktop_bounds{
      GetSystemMetrics(SM_XVIRTUALSCREEN), GetSystemMetrics(SM_YVIRTUALSCREEN),
      GetSystemMetrics(SM_XVIRTUALSCREEN) + GetSystemMetrics(SM_CXVIRTUALSCREEN),
      GetSystemMetrics(SM_YVIRTUALSCREEN) + GetSystemMetrics(SM_CYVIRTUALSCREEN)};
  if (!GetWindowRect(GetHandle(), &bounds) ||
      !UnionRect(&combined, &bounds, &target) ||
      !IntersectRect(&visible, &combined, &desktop_bounds)) return false;
  const int width = visible.right - visible.left;
  const int height = visible.bottom - visible.top;
  if (static_cast<std::int64_t>(width) * height > 64 * 1024 * 1024) return false;
  if (desktop_snapshot_) {
    surface_handoff_window_ = desktop_snapshot_->ShowOverlay(GetHandle(), visible);
    if (surface_handoff_window_) {
      return true;
    }
  }
  HDC desktop = GetDC(nullptr);
  if (desktop == nullptr) return false;
  BITMAPINFO description{};
  description.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  description.bmiHeader.biWidth = width;
  description.bmiHeader.biHeight = -height;
  description.bmiHeader.biPlanes = 1;
  description.bmiHeader.biBitCount = 32;
  description.bmiHeader.biCompression = BI_RGB;
  void* pixels = nullptr;
  surface_handoff_bitmap_ = CreateDIBSection(
      desktop, &description, DIB_RGB_COLORS, &pixels, nullptr, 0);
  bool copied = surface_handoff_bitmap_ != nullptr && desktop_snapshot_ &&
      desktop_snapshot_->Capture(visible, pixels, static_cast<size_t>(width) * 4);
  HDC memory = !copied && surface_handoff_bitmap_ != nullptr
      ? CreateCompatibleDC(desktop) : nullptr;
  if (!copied && memory != nullptr) {
    const auto previous = SelectObject(memory, surface_handoff_bitmap_);
    if (previous != nullptr && previous != HGDI_ERROR) {
      copied = BitBlt(memory, 0, 0, width, height, desktop,
                      visible.left, visible.top, SRCCOPY) != FALSE;
      SelectObject(memory, previous);
    }
    DeleteDC(memory);
  }
  ReleaseDC(nullptr, desktop);
  if (!copied || !GdiFlush()) {
    DestroySurfaceHandoff();
    return false;
  }
  surface_handoff_window_ = CreateWindowExW(
      WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW | WS_EX_TOPMOST | WS_EX_LAYERED,
      L"STATIC", L"Zommi resize handoff",
      WS_POPUP | SS_NOTIFY,
      visible.left, visible.top, width, height, GetHandle(), nullptr,
      GetModuleHandleW(nullptr), nullptr);
  if (surface_handoff_window_ == nullptr) {
    DestroySurfaceHandoff();
    return false;
  }
  HDC bitmap_dc = CreateCompatibleDC(nullptr);
  if (bitmap_dc == nullptr) {
    DestroySurfaceHandoff();
    return false;
  }
  const auto previous_bitmap = SelectObject(bitmap_dc, surface_handoff_bitmap_);
  POINT destination{visible.left, visible.top};
  POINT source{};
  SIZE dimensions{width, height};
  const bool updated = previous_bitmap != nullptr && previous_bitmap != HGDI_ERROR &&
      UpdateLayeredWindow(surface_handoff_window_, nullptr, &destination, &dimensions,
                           bitmap_dc, &source, 0, nullptr, ULW_OPAQUE) != FALSE;
  if (previous_bitmap != nullptr && previous_bitmap != HGDI_ERROR) {
    SelectObject(bitmap_dc, previous_bitmap);
  }
  DeleteDC(bitmap_dc);
  if (!updated) {
    DestroySurfaceHandoff();
    return false;
  }
  if (!SetWindowPos(surface_handoff_window_, HWND_TOPMOST,
                    visible.left, visible.top, width, height,
                    SWP_NOACTIVATE | SWP_SHOWWINDOW)) {
    DestroySurfaceHandoff();
    return false;
  }
  return true;
}

void FlutterWindow::CompleteSurfaceHandoff(bool timed_out) {
  if (!surface_handoff_result_) return;
  auto result = std::move(surface_handoff_result_);
  const auto pending_command = pending_surface_command_;
  DestroySurfaceHandoff();
  if (timed_out) {
    result->Error("surface_handoff_failed", "The resized frame was not presented.");
  } else {
    result->Success(flutter::EncodableValue(true));
  }
  if (pending_command != 0 && IsWindowVisible(GetHandle()) &&
      !IsIconic(GetHandle())) {
    PostMessage(GetHandle(), WM_SYSCOMMAND, pending_command, 0);
  }
}

void FlutterWindow::DestroySurfaceHandoff() {
  pending_surface_command_ = 0;
  surface_handoff_applying_ = false;
  surface_handoff_armed_ = false;
  surface_handoff_frame_ready_ = false;
  if (surface_handoff_timer_ != 0) {
    KillTimer(GetHandle(), surface_handoff_timer_);
    surface_handoff_timer_ = 0;
  }
  if (surface_handoff_window_ != nullptr) {
    DestroyWindow(surface_handoff_window_);
    surface_handoff_window_ = nullptr;
  }
  if (desktop_snapshot_) desktop_snapshot_->ReleaseOverlay();
  if (surface_handoff_bitmap_ != nullptr) {
    DeleteObject(surface_handoff_bitmap_);
    surface_handoff_bitmap_ = nullptr;
  }
}
