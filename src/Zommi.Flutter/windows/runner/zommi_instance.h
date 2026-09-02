#ifndef RUNNER_ZOMMI_INSTANCE_H_
#define RUNNER_ZOMMI_INSTANCE_H_

#include <windows.h>

inline constexpr wchar_t kZommiInstanceMutexName[] =
    L"Local\\Zommi.Desktop.SingleInstance";
inline constexpr wchar_t kZommiShowWindowMessageName[] =
    L"Zommi.Desktop.ShowExistingWindow";

inline UINT ZommiShowWindowMessage() {
  static const UINT message =
      RegisterWindowMessageW(kZommiShowWindowMessageName);
  return message;
}

#endif  // RUNNER_ZOMMI_INSTANCE_H_
