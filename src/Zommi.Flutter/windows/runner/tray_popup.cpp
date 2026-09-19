#include "tray_popup.h"

#include <commctrl.h>
#include <cmath>
#include <cstdint>
#include <algorithm>
#include <string>
#include <variant>

namespace {
constexpr wchar_t kClass[] = L"ZommiTrayMenu";
COLORREF Color(const flutter::EncodableMap& colors, const char* name,
               COLORREF fallback) {
  const auto it = colors.find(flutter::EncodableValue(name));
  if (it == colors.end()) return fallback;
  unsigned long value;
  if (const auto* number = std::get_if<int64_t>(&it->second)) {
    value = static_cast<unsigned long>(*number);
  } else if (const auto* small_number = std::get_if<int32_t>(&it->second)) {
    value = static_cast<unsigned long>(*small_number);
  } else return fallback;
  return RGB((value >> 16) & 255, (value >> 8) & 255, value & 255);
}
}

TrayPopup::~TrayPopup() { Finish(""); }
int TrayPopup::Scale(int value) const { return MulDiv(value, dpi_, 96); }

void TrayPopup::Show(const flutter::EncodableMap& colors,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  Finish("");
  result_ = std::move(result);
  background_ = Color(colors, "background", background_);
  foreground_ = Color(colors, "foreground", foreground_);
  hover_ = Color(colors, "hover", hover_);
  hovered_ = -1;
  WNDCLASSW klass{};
  klass.lpfnWndProc = WindowProc;
  klass.hInstance = GetModuleHandle(nullptr);
  klass.hCursor = LoadCursor(nullptr, IDC_ARROW);
  klass.lpszClassName = kClass;
  RegisterClassW(&klass);
  POINT cursor{};
  GetCursorPos(&cursor);
  // Create on the pointer's monitor before reading its actual per-monitor DPI.
  window_ = CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_TOPMOST | WS_EX_LAYERED, kClass,
      L"Zommi menu", WS_POPUP, cursor.x, cursor.y, 1, 1,
      nullptr, nullptr, klass.hInstance, this);
  if (!window_) { Finish(""); return; }
  dpi_ = GetDpiForWindow(window_);
  MONITORINFO monitor{sizeof(MONITORINFO)};
  GetMonitorInfoW(MonitorFromPoint(cursor, MONITOR_DEFAULTTONEAREST), &monitor);
  const int width = Scale(164), height = Scale(70);
  const int left = std::clamp(cursor.x - width, monitor.rcWork.left,
                             monitor.rcWork.right - width);
  const int top = std::clamp(cursor.y - height, monitor.rcWork.top,
                            monitor.rcWork.bottom - height);
  SetWindowPos(window_, HWND_TOPMOST, left, top, width, height, SWP_NOACTIVATE);
  font_ = CreateFontW(-Scale(11), 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
      DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
      CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe UI");
  for (int i = 0; i < 2; ++i) {
    buttons_[i] = CreateWindowExW(0, L"BUTTON", i == 0 ? L"Open Zommi" : L"Quit",
        WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_OWNERDRAW,
        0, Scale(5 + i * 30), width, Scale(30), window_,
        reinterpret_cast<HMENU>(static_cast<INT_PTR>(i + 1)), klass.hInstance, nullptr);
    SetWindowSubclass(buttons_[i], ButtonProc, 1, reinterpret_cast<DWORD_PTR>(this));
  }
  PaintSurface();
  ShowWindow(window_, SW_SHOW);
  SetForegroundWindow(window_);
  SetFocus(buttons_[0]);
}

void TrayPopup::Finish(const char* action) {
  auto result = std::move(result_);
  if (window_) DestroyWindow(window_);
  window_ = nullptr;
  buttons_[0] = buttons_[1] = nullptr;
  if (font_) DeleteObject(font_);
  font_ = nullptr;
  if (result) result->Success(flutter::EncodableValue(action));
}

LRESULT CALLBACK TrayPopup::WindowProc(HWND window, UINT message,
                                      WPARAM wparam, LPARAM lparam) {
  auto* self = reinterpret_cast<TrayPopup*>(GetWindowLongPtrW(window, GWLP_USERDATA));
  if (message == WM_NCCREATE) {
    self = static_cast<TrayPopup*>(reinterpret_cast<CREATESTRUCTW*>(lparam)->lpCreateParams);
    SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(self));
  }
  if (!self) return DefWindowProcW(window, message, wparam, lparam);
  switch (message) {
    case WM_ACTIVATE:
      if (LOWORD(wparam) == WA_INACTIVE) PostMessageW(window, WM_CLOSE, 0, 0);
      return 0;
    case WM_CLOSE: self->Finish(""); return 0;
    case WM_COMMAND:
      if (HIWORD(wparam) == BN_CLICKED && (LOWORD(wparam) == 1 || LOWORD(wparam) == 2))
        self->Finish(LOWORD(wparam) == 1 ? "open" : "exit");
      return 0;
    case WM_DRAWITEM:
      // The layered surface draws the controls; native children keep input
      // and accessibility without painting opaque rectangles over the corners.
      return TRUE;
    case WM_ERASEBKGND: return TRUE;
    case WM_PAINT: {
      PAINTSTRUCT paint{};
      BeginPaint(window, &paint);
      EndPaint(window, &paint);
      self->PaintSurface();
      return 0;
    }
  }
  return DefWindowProcW(window, message, wparam, lparam);
}

LRESULT CALLBACK TrayPopup::ButtonProc(HWND button, UINT message,
    WPARAM wparam, LPARAM lparam, UINT_PTR, DWORD_PTR data) {
  auto* self = reinterpret_cast<TrayPopup*>(data);
  const int index = GetDlgCtrlID(button) - 1;
  if (message == WM_MOUSEMOVE) {
    if (self->hovered_ != index) {
      self->hovered_ = index;
      InvalidateRect(self->window_, nullptr, FALSE);
      TRACKMOUSEEVENT track{sizeof(TRACKMOUSEEVENT), TME_LEAVE, button, 0};
      TrackMouseEvent(&track);
    }
  } else if (message == WM_MOUSELEAVE) {
    if (self->hovered_ == index) self->hovered_ = -1;
    InvalidateRect(self->window_, nullptr, FALSE);
  } else if (message == WM_SETFOCUS || message == WM_KILLFOCUS) {
    InvalidateRect(self->window_, nullptr, FALSE);
  } else if (message == WM_KEYDOWN) {
    if (wparam == VK_ESCAPE) { self->Finish(""); return 0; }
    if (wparam == VK_DOWN || wparam == VK_UP || wparam == VK_TAB) {
      SetFocus(self->buttons_[1 - index]); return 0;
    }
    if (wparam == VK_RETURN) {
      self->Finish(index == 0 ? "open" : "exit"); return 0;
    }
  } else if (message == WM_NCDESTROY) {
    RemoveWindowSubclass(button, ButtonProc, 1);
  }
  return DefSubclassProc(button, message, wparam, lparam);
}

void TrayPopup::PaintSurface() {
  if (!window_ || !font_) return;
  RECT bounds{};
  GetWindowRect(window_, &bounds);
  const int width = bounds.right - bounds.left;
  const int height = bounds.bottom - bounds.top;
  if (width <= 0 || height <= 0) return;
  BITMAPINFO info{};
  info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  info.bmiHeader.biWidth = width;
  info.bmiHeader.biHeight = -height;
  info.bmiHeader.biPlanes = 1;
  info.bmiHeader.biBitCount = 32;
  info.bmiHeader.biCompression = BI_RGB;
  void* pixels = nullptr;
  const HDC screen = GetDC(nullptr);
  const HDC dc = CreateCompatibleDC(screen);
  const HBITMAP bitmap = CreateDIBSection(screen, &info, DIB_RGB_COLORS,
                                         &pixels, nullptr, 0);
  if (!dc || !bitmap) {
    if (bitmap) DeleteObject(bitmap);
    if (dc) DeleteDC(dc);
    ReleaseDC(nullptr, screen);
    return;
  }
  const auto old_bitmap = SelectObject(dc, bitmap);
  const auto old_font = SelectObject(dc, font_);
  const RECT client{0, 0, width, height};
  const auto background = CreateSolidBrush(background_);
  FillRect(dc, &client, background);
  DeleteObject(background);
  SetBkMode(dc, TRANSPARENT);
  SetTextColor(dc, foreground_);
  for (int i = 0; i < 2; ++i) {
    RECT row{0, Scale(5 + i * 30), width, Scale(5 + (i + 1) * 30)};
    const bool highlighted = hovered_ >= 0 ? hovered_ == i : GetFocus() == buttons_[i];
    if (highlighted) {
      const auto hover = CreateSolidBrush(hover_);
      FillRect(dc, &row, hover);
      DeleteObject(hover);
    }
    row.left += Scale(12);
    row.right -= Scale(12);
    DrawTextW(dc, i == 0 ? L"Open Zommi" : L"Quit", -1, &row,
              DT_SINGLELINE | DT_VCENTER | DT_LEFT);
  }
  GdiFlush();
  // A per-pixel alpha edge stays smooth at every DPI, including desktops where
  // DWM rounding is unavailable. Apply it after GDI paints so hover rows share
  // the exact same rounded contour. UpdateLayeredWindow needs premultiplied RGB.
  const double radius = Scale(18);
  auto* argb = static_cast<uint32_t*>(pixels);
  for (int y = 0; y < height; ++y) {
    for (int x = 0; x < width; ++x) {
      const double dx = std::max({radius - (x + 0.5), x + 0.5 - (width - radius), 0.0});
      const double dy = std::max({radius - (y + 0.5), y + 0.5 - (height - radius), 0.0});
      const auto alpha = static_cast<uint32_t>(
          std::clamp(radius + 0.5 - std::hypot(dx, dy), 0.0, 1.0) * 255.0 + 0.5);
      auto& pixel = argb[static_cast<size_t>(y) * width + x];
      pixel = (alpha << 24) | (((pixel >> 16 & 255) * alpha / 255) << 16)
          | (((pixel >> 8 & 255) * alpha / 255) << 8) | ((pixel & 255) * alpha / 255);
    }
  }
  POINT destination{bounds.left, bounds.top}, origin{};
  SIZE size{width, height};
  BLENDFUNCTION blend{AC_SRC_OVER, 0, 255, AC_SRC_ALPHA};
  UpdateLayeredWindow(window_, screen, &destination, &size, dc, &origin,
                      0, &blend, ULW_ALPHA);
  SelectObject(dc, old_font);
  SelectObject(dc, old_bitmap);
  DeleteObject(bitmap);
  DeleteDC(dc);
  ReleaseDC(nullptr, screen);
}
