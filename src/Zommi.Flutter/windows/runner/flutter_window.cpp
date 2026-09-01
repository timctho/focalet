#include "flutter_window.h"

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

  flutter_controller_->engine()->SetNextFrameCallback([&]() { this->Show(); });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  CancelWindowAnimation();
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
  if (call.method_name() == "configureSurfaceWindow") {
    CancelWindowAnimation();
    const auto window = GetHandle();
    SetLastError(ERROR_SUCCESS);
    const LONG_PTR style = GetWindowLongPtr(window, GWL_STYLE);
    if (style == 0 && GetLastError() != ERROR_SUCCESS) {
      result->Error("window_unavailable", "Could not read the Zommi window style.");
      return;
    }
    const LONG_PTR surface_style =
        (style & ~(WS_CAPTION | WS_THICKFRAME | WS_MINIMIZEBOX |
                   WS_MAXIMIZEBOX | WS_SYSMENU)) |
        WS_POPUP | WS_CLIPCHILDREN | WS_CLIPSIBLINGS;
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
  if (call.method_name() != "animateBounds") {
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
  if (!x || !y || !width || !height || !scale || !duration || *scale <= 0 ||
      *width <= 0 || *height <= 0 || *duration < 0) {
    result->Error("invalid_arguments", "Window bounds are incomplete.");
    return;
  }

  CancelWindowAnimation();
  if (!GetWindowRect(GetHandle(), &animation_from_)) {
    result->Error("window_unavailable", "The Zommi window is unavailable.");
    return;
  }
  animation_to_.left = static_cast<LONG>(std::lround(*x * *scale));
  animation_to_.top = static_cast<LONG>(std::lround(*y * *scale));
  animation_to_.right =
      animation_to_.left + static_cast<LONG>(std::lround(*width * *scale));
  animation_to_.bottom =
      animation_to_.top + static_cast<LONG>(std::lround(*height * *scale));
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
  const double eased = 1.0 - std::pow(1.0 - linear, 3.0);
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
