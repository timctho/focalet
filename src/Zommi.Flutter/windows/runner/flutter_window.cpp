#include "flutter_window.h"

#include <cmath>
#include <cstdint>
#include <optional>
#include <string>
#include <utility>
#include <variant>

#include "flutter/generated_plugin_registrant.h"
#include "zommi_instance.h"
#include <flutter/standard_method_codec.h>

namespace {

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

  // FlutterDesktopBridge shows the window only after it has applied the
  // compact frameless bounds and monitor anchor. Showing from this first-frame
  // callback races that configuration and exposes the runner template box.
  return true;
}

void FlutterWindow::OnDestroy() {
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
    result->Success(flutter::EncodableValue(root_window == GetHandle()));
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
    result->Success();
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
  if (maximized != nullptr && *maximized) {
    if (!IsZoomed(GetHandle()) &&
        !PostMessage(GetHandle(), WM_SYSCOMMAND, SC_MAXIMIZE, 0)) {
      result->Error("window_resize_failed", "Could not maximize the window.");
      return;
    }
  } else if (IsZoomed(GetHandle())) {
    WINDOWPLACEMENT placement{};
    placement.length = sizeof(placement);
    MONITORINFO monitor{};
    monitor.cbSize = sizeof(monitor);
    if (!GetWindowPlacement(GetHandle(), &placement) ||
        !GetMonitorInfo(MonitorFromWindow(GetHandle(), MONITOR_DEFAULTTONEAREST), &monitor)) {
      result->Error("window_unavailable", "Window placement is unavailable.");
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
      result->Error("window_resize_failed", "Could not restore the window.");
      return;
    }
  } else if (!SetWindowPos(GetHandle(), nullptr, target.left, target.top,
                           target.right - target.left, target.bottom - target.top,
                           SWP_NOACTIVATE | SWP_NOOWNERZORDER | SWP_NOZORDER)) {
    result->Error("window_resize_failed", "Could not resize the window.");
    return;
  }
  result->Success(flutter::EncodableValue(true));
}
