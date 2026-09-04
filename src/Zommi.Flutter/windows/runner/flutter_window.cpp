#include "flutter_window.h"

#include <dwmapi.h>

#include <algorithm>
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

constexpr UINT_PTR kWindowAnimationTimerId = 0x5A4D;
constexpr UINT kWindowAnimationFrameMs = 15;

constexpr double SymmetricSurfaceEase(double progress) {
  if (progress < 0.5) {
    return 4.0 * progress * progress * progress;
  }
  const double tail = -2.0 * progress + 2.0;
  return 1.0 - tail * tail * tail / 2.0;
}

static_assert(SymmetricSurfaceEase(0.0) == 0.0);
static_assert(SymmetricSurfaceEase(0.5) == 0.5);
static_assert(SymmetricSurfaceEase(1.0) == 1.0);
static_assert(SymmetricSurfaceEase(0.25) == 1.0 - SymmetricSurfaceEase(0.75));

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
  CancelWindowAnimation();
  CancelPendingSurfaceFrame();
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
  if (message == WM_TIMER && wparam == kWindowAnimationTimerId) {
    AdvanceWindowAnimation();
    return 0;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
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
    CancelWindowAnimation();
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
        (style & ~(WS_CAPTION | WS_THICKFRAME)) |
        WS_POPUP | WS_SYSMENU | WS_MINIMIZEBOX | WS_MAXIMIZEBOX | WS_CLIPCHILDREN |
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
  if (call.method_name() != "animateBounds" &&
      call.method_name() != "setBoundsWithoutCopy") {
    result->NotImplemented();
    return;
  }
  const auto *value = call.arguments();
  const auto *arguments =
      value == nullptr ? nullptr : std::get_if<flutter::EncodableMap>(value);
  if (arguments == nullptr) {
    result->Error("invalid_arguments", "Window bounds are required.");
    return;
  }
  const auto x = NumberArgument(*arguments, "toX");
  const auto y = NumberArgument(*arguments, "toY");
  const auto width = NumberArgument(*arguments, "toWidth");
  const auto height = NumberArgument(*arguments, "toHeight");
  const auto scale = NumberArgument(*arguments, "scaleFactor");
  const auto duration = NumberArgument(*arguments, "durationMs");
  const bool instant_without_copy =
      call.method_name() == "setBoundsWithoutCopy";
  if (!x || !y || !width || !height || !scale || *scale <= 0 || *width <= 0 ||
      *height <= 0 || (!instant_without_copy && (!duration || *duration < 0))) {
    result->Error("invalid_arguments", "Window bounds are incomplete.");
    return;
  }

  CancelWindowAnimation();
  CancelPendingSurfaceFrame();
  RECT target{};
  target.left = static_cast<LONG>(std::lround(*x * *scale));
  target.top = static_cast<LONG>(std::lround(*y * *scale));
  target.right = target.left + static_cast<LONG>(std::lround(*width * *scale));
  target.bottom = target.top + static_cast<LONG>(std::lround(*height * *scale));
  if (instant_without_copy) {
    RECT current{};
    if (!GetWindowRect(GetHandle(), &current)) {
      result->Error("window_unavailable", "The Zommi window is unavailable.");
      return;
    }
    const LONG current_width = current.right - current.left;
    const LONG current_height = current.bottom - current.top;
    const LONG target_width = target.right - target.left;
    const LONG target_height = target.bottom - target.top;
    RECT anchored_target{};
    anchored_target.left = current.left + (current_width - target_width) / 2;
    anchored_target.top = current.bottom - target_height;
    anchored_target.right = anchored_target.left + target_width;
    anchored_target.bottom = anchored_target.top + target_height;
    if (std::abs(anchored_target.left - target.left) <= 1 &&
        std::abs(anchored_target.top - target.top) <= 1) {
      target = anchored_target;
    }
    const bool growing =
        target_width * target_height > current_width * current_height;
    const bool staged = growing && BeginSurfaceFrameTransition(current);
    if (!SetWindowPos(GetHandle(), nullptr, target.left, target.top,
                      target.right - target.left, target.bottom - target.top,
                      SWP_NOACTIVATE | SWP_NOCOPYBITS | SWP_NOOWNERZORDER |
                          SWP_NOZORDER)) {
      if (staged) {
        FinishSurfaceFrameTransition();
      }
      result->Error("window_resize_failed",
                    "Could not resize the Zommi surface window.");
      return;
    }
    pending_surface_frame_result_ = std::move(result);
    flutter_controller_->engine()->SetNextFrameCallback([this]() {
      if (pending_surface_frame_result_ != nullptr) {
        FinishSurfaceFrameTransition();
        auto completed = std::move(pending_surface_frame_result_);
        completed->Success(flutter::EncodableValue(true));
      }
    });
    flutter_controller_->ForceRedraw();
    return;
  }
  if (!GetWindowRect(GetHandle(), &animation_from_)) {
    result->Error("window_unavailable", "The Zommi window is unavailable.");
    return;
  }
  animation_to_ = target;
  animation_duration_ms_ =
      static_cast<DWORD>(std::lround(std::max(1.0, *duration)));
  animation_started_at_ = GetTickCount64();
  window_animation_active_ = true;
  window_animation_result_ = std::move(result);
  if (SetTimer(GetHandle(), kWindowAnimationTimerId, kWindowAnimationFrameMs,
               nullptr) == 0) {
    SetWindowPos(GetHandle(), nullptr, animation_to_.left, animation_to_.top,
                 animation_to_.right - animation_to_.left,
                 animation_to_.bottom - animation_to_.top,
                 SWP_NOACTIVATE | SWP_NOOWNERZORDER | SWP_NOZORDER);
    window_animation_active_ = false;
    auto completed = std::move(window_animation_result_);
    completed->Success(flutter::EncodableValue(true));
  }
}

void FlutterWindow::AdvanceWindowAnimation() {
  if (!window_animation_active_) {
    KillTimer(GetHandle(), kWindowAnimationTimerId);
    return;
  }
  const auto elapsed = GetTickCount64() - animation_started_at_;
  const double linear =
      std::min(1.0, static_cast<double>(elapsed) / animation_duration_ms_);
  const double eased = SymmetricSurfaceEase(linear);
  const auto interpolate = [eased](LONG from, LONG to) {
    return static_cast<LONG>(std::lround(from + (to - from) * eased));
  };
  const LONG left = interpolate(animation_from_.left, animation_to_.left);
  const LONG top = interpolate(animation_from_.top, animation_to_.top);
  const LONG right = interpolate(animation_from_.right, animation_to_.right);
  const LONG bottom = interpolate(animation_from_.bottom, animation_to_.bottom);
  SetWindowPos(GetHandle(), nullptr, left, top, right - left, bottom - top,
               SWP_NOACTIVATE | SWP_NOOWNERZORDER | SWP_NOZORDER);
  if (linear < 1.0) {
    return;
  }
  KillTimer(GetHandle(), kWindowAnimationTimerId);
  window_animation_active_ = false;
  auto completed = std::move(window_animation_result_);
  completed->Success(flutter::EncodableValue(true));
}

void FlutterWindow::CancelWindowAnimation() {
  if (!window_animation_active_ && window_animation_result_ == nullptr) {
    return;
  }
  KillTimer(GetHandle(), kWindowAnimationTimerId);
  window_animation_active_ = false;
  if (window_animation_result_ != nullptr) {
    auto cancelled = std::move(window_animation_result_);
    cancelled->Success(flutter::EncodableValue(false));
  }
}

void FlutterWindow::CancelPendingSurfaceFrame() {
  FinishSurfaceFrameTransition();
  if (pending_surface_frame_result_ != nullptr) {
    auto cancelled = std::move(pending_surface_frame_result_);
    cancelled->Success(flutter::EncodableValue(false));
  }
}

bool FlutterWindow::BeginSurfaceFrameTransition(const RECT &current_bounds) {
  DestroySurfaceTransitionOverlay();
  const int width = current_bounds.right - current_bounds.left;
  const int height = current_bounds.bottom - current_bounds.top;
  HDC desktop = GetDC(nullptr);
  if (desktop == nullptr) {
    return false;
  }
  HDC memory = CreateCompatibleDC(desktop);
  HBITMAP bitmap = memory == nullptr
                       ? nullptr
                       : CreateCompatibleBitmap(desktop, width, height);
  HGDIOBJ previous = bitmap == nullptr ? nullptr : SelectObject(memory, bitmap);
  const bool copied = previous != nullptr &&
                      BitBlt(memory, 0, 0, width, height, desktop,
                             current_bounds.left, current_bounds.top, SRCCOPY);
  if (previous != nullptr) {
    SelectObject(memory, previous);
  }
  if (memory != nullptr) {
    DeleteDC(memory);
  }
  ReleaseDC(nullptr, desktop);
  if (!copied) {
    if (bitmap != nullptr) {
      DeleteObject(bitmap);
    }
    return false;
  }

  HWND overlay = CreateWindowExW(
      WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW | WS_EX_TOPMOST | WS_EX_TRANSPARENT,
      L"STATIC", nullptr,
      WS_POPUP | WS_VISIBLE | SS_BITMAP | SS_REALSIZECONTROL,
      current_bounds.left, current_bounds.top, width, height, nullptr, nullptr,
      GetModuleHandleW(nullptr), nullptr);
  if (overlay == nullptr) {
    DeleteObject(bitmap);
    return false;
  }
  SendMessageW(overlay, STM_SETIMAGE, IMAGE_BITMAP,
               reinterpret_cast<LPARAM>(bitmap));
  if (!SetWindowPos(overlay, HWND_TOPMOST, current_bounds.left,
                    current_bounds.top, width, height,
                    SWP_NOACTIVATE | SWP_SHOWWINDOW)) {
    DestroyWindow(overlay);
    DeleteObject(bitmap);
    return false;
  }

  BOOL cloak = TRUE;
  if (FAILED(DwmSetWindowAttribute(GetHandle(), DWMWA_CLOAK, &cloak,
                                   sizeof(cloak)))) {
    DestroyWindow(overlay);
    DeleteObject(bitmap);
    return false;
  }
  surface_transition_overlay_ = overlay;
  surface_transition_bitmap_ = bitmap;
  surface_window_cloaked_ = true;
  return true;
}

void FlutterWindow::FinishSurfaceFrameTransition() {
  if (surface_window_cloaked_) {
    BOOL cloak = FALSE;
    DwmSetWindowAttribute(GetHandle(), DWMWA_CLOAK, &cloak, sizeof(cloak));
    surface_window_cloaked_ = false;
  }
  DestroySurfaceTransitionOverlay();
}

void FlutterWindow::DestroySurfaceTransitionOverlay() {
  if (surface_transition_overlay_ != nullptr) {
    DestroyWindow(surface_transition_overlay_);
    surface_transition_overlay_ = nullptr;
  }
  if (surface_transition_bitmap_ != nullptr) {
    DeleteObject(surface_transition_bitmap_);
    surface_transition_bitmap_ = nullptr;
  }
}
