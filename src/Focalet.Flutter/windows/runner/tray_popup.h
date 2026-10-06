#ifndef RUNNER_TRAY_POPUP_H_
#define RUNNER_TRAY_POPUP_H_

#include <windows.h>
#include <flutter/encodable_value.h>
#include <flutter/method_result.h>
#include <memory>

// An independent desktop popup keeps a minimized chat minimized until Open.
// Standard button children retain keyboard and accessibility support.
class TrayPopup {
 public:
  ~TrayPopup();
  void Show(const flutter::EncodableMap& colors,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

 private:
  static LRESULT CALLBACK WindowProc(HWND, UINT, WPARAM, LPARAM);
  static LRESULT CALLBACK ButtonProc(HWND, UINT, WPARAM, LPARAM,
                                    UINT_PTR, DWORD_PTR);
  void Finish(const char* action);
  void PaintSurface();
  int Scale(int value) const;

  HWND window_ = nullptr;
  HWND buttons_[2]{};
  HFONT font_ = nullptr;
  UINT dpi_ = 96;
  int hovered_ = -1;
  COLORREF background_ = RGB(40, 40, 40);
  COLORREF foreground_ = RGB(230, 230, 230);
  COLORREF hover_ = RGB(60, 60, 60);
  std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result_;
};
#endif
