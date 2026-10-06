#ifndef RUNNER_FOCALET_INSTANCE_H_
#define RUNNER_FOCALET_INSTANCE_H_

#include <windows.h>

inline constexpr wchar_t kFocaletInstanceMutexName[] =
    L"Local\\Focalet.Desktop.SingleInstance";
inline constexpr wchar_t kFocaletShowWindowMessageName[] =
    L"Focalet.Desktop.ShowExistingWindow";

inline UINT FocaletShowWindowMessage() {
  static const UINT message =
      RegisterWindowMessageW(kFocaletShowWindowMessageName);
  return message;
}

#endif  // RUNNER_FOCALET_INSTANCE_H_
