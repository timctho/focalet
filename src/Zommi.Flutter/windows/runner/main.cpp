#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <dxgi.h>

#include "flutter_window.h"
#include "utils.h"
#include "zommi_instance.h"

namespace {

bool HasHardwareRenderAdapter() {
  IDXGIFactory1* factory = nullptr;
  if (FAILED(CreateDXGIFactory1(IID_PPV_ARGS(&factory)))) {
    // Preserve Flutter's default when capability discovery is unavailable.
    return true;
  }
  bool hardware = false;
  for (UINT index = 0; ; ++index) {
    IDXGIAdapter1* adapter = nullptr;
    if (factory->EnumAdapters1(index, &adapter) != S_OK) break;
    DXGI_ADAPTER_DESC1 description{};
    if (SUCCEEDED(adapter->GetDesc1(&description)) &&
        (description.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) == 0) {
      hardware = true;
    }
    adapter->Release();
    if (hardware) break;
  }
  factory->Release();
  return hardware;
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  HANDLE instance_mutex =
      CreateMutexW(nullptr, TRUE, kZommiInstanceMutexName);
  if (instance_mutex != nullptr && GetLastError() == ERROR_ALREADY_EXISTS) {
    PostMessageW(HWND_BROADCAST, ZommiShowWindowMessage(), 0, 0);
    CloseHandle(instance_mutex);
    return EXIT_SUCCESS;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");
  // A release-capable diagnostic override for paired renderer measurements.
  // Flutter itself only accepts engine environment switches in debug/profile.
  wchar_t renderer[32]{};
  GetEnvironmentVariableW(L"ZOMMI_WINDOWS_RENDERER", renderer, 32);
  if (std::wstring(renderer) == L"impeller") {
    project.set_impeller_switch(flutter::ImpellerSwitch::Enabled);
  } else if (std::wstring(renderer) == L"skia" || !HasHardwareRenderAdapter()) {
    // Impeller's Windows/WARP path can take >100 ms to raster a text frame.
    // Skia avoids that cost on software-only hosts, including remote VMs.
    project.set_impeller_switch(flutter::ImpellerSwitch::Disabled);
  }

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  // The taskbar-first UI starts as the complete chat surface; there is no
  // compact orb bootstrap frame to morph away from.
  Win32Window::Size size(720, 620);
  if (!window.Create(L"Zommi", origin, size)) {
    if (instance_mutex != nullptr) {
      ReleaseMutex(instance_mutex);
      CloseHandle(instance_mutex);
    }
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  if (instance_mutex != nullptr) {
    ReleaseMutex(instance_mutex);
    CloseHandle(instance_mutex);
  }
  return EXIT_SUCCESS;
}
