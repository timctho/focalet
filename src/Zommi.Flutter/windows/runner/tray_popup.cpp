#include "tray_popup.h"

#include <commctrl.h>
#include <dwmapi.h>
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
  window_ = CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_TOPMOST, kClass,
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
  SetWindowRgn(window_, CreateRoundRectRgn(0, 0, width + 1, height + 1,
      Scale(36), Scale(36)), FALSE);
  const int round = 2;
  DwmSetWindowAttribute(window_, 33, &round, sizeof(round));
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
      self->PaintButton(*reinterpret_cast<DRAWITEMSTRUCT*>(lparam));
      return TRUE;
    case WM_ERASEBKGND: return TRUE;
    case WM_PAINT: {
      PAINTSTRUCT paint{};
      const auto dc = BeginPaint(window, &paint);
      RECT client{}; GetClientRect(window, &client);
      const auto brush = CreateSolidBrush(self->background_);
      FillRect(dc, &client, brush);
      DeleteObject(brush);
      EndPaint(window, &paint);
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
      InvalidateRect(self->buttons_[0], nullptr, FALSE);
      InvalidateRect(self->buttons_[1], nullptr, FALSE);
      TRACKMOUSEEVENT track{sizeof(TRACKMOUSEEVENT), TME_LEAVE, button, 0};
      TrackMouseEvent(&track);
    }
  } else if (message == WM_MOUSELEAVE) {
    if (self->hovered_ == index) self->hovered_ = -1;
    InvalidateRect(button, nullptr, FALSE);
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

void TrayPopup::PaintButton(const DRAWITEMSTRUCT& item) {
  const bool highlighted = hovered_ >= 0
      ? hovered_ == static_cast<int>(item.CtlID) - 1
      : (item.itemState & (ODS_SELECTED | ODS_FOCUS)) != 0;
  const auto brush = CreateSolidBrush(highlighted ? hover_ : background_);
  FillRect(item.hDC, &item.rcItem, brush);
  DeleteObject(brush);
  const auto old_font = SelectObject(item.hDC, font_);
  SetBkMode(item.hDC, TRANSPARENT);
  SetTextColor(item.hDC, foreground_);
  RECT text = item.rcItem;
  text.left += Scale(34);
  text.right -= Scale(12);
  DrawTextW(item.hDC, item.CtlID == 1 ? L"Open Zommi" : L"Quit", -1,
            &text, DT_SINGLELINE | DT_VCENTER | DT_LEFT);
  SelectObject(item.hDC, old_font);
  const auto pen = CreatePen(PS_SOLID, std::max(1, Scale(1)), foreground_);
  const auto old_pen = SelectObject(item.hDC, pen);
  const auto old_brush = SelectObject(item.hDC, GetStockObject(HOLLOW_BRUSH));
  const int x = Scale(12), y = (item.rcItem.bottom - Scale(14)) / 2;
  if (item.CtlID == 1) {
    Rectangle(item.hDC, x, y + Scale(4), x + Scale(10), y + Scale(14));
    MoveToEx(item.hDC, x + Scale(5), y + Scale(9), nullptr);
    LineTo(item.hDC, x + Scale(14), y);
    MoveToEx(item.hDC, x + Scale(8), y, nullptr);
    LineTo(item.hDC, x + Scale(14), y);
    LineTo(item.hDC, x + Scale(14), y + Scale(6));
  } else {
    Arc(item.hDC, x, y + Scale(2), x + Scale(14), y + Scale(14),
        x + Scale(4), y, x + Scale(10), y);
    MoveToEx(item.hDC, x + Scale(7), y, nullptr);
    LineTo(item.hDC, x + Scale(7), y + Scale(8));
  }
  SelectObject(item.hDC, old_pen); DeleteObject(pen);
  SelectObject(item.hDC, old_brush);
}
