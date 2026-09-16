#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <d3d11.h>
#include <dxgi.h>
#include <wrl/client.h>

#include "flutter_window.h"
#include "utils.h"
#include "zommi_instance.h"

namespace {

bool HasHardwareRenderDevice() {
  // Virtual/remote display adapters can enumerate as hardware even when the
  // default D3D device is WARP. Inspect the device actually selected by D3D.
  const D3D_FEATURE_LEVEL levels[] = {
      D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_10_1,
      D3D_FEATURE_LEVEL_10_0, D3D_FEATURE_LEVEL_9_3};
  Microsoft::WRL::ComPtr<ID3D11Device> device;
  if (FAILED(D3D11CreateDevice(
          nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
          D3D11_CREATE_DEVICE_BGRA_SUPPORT, levels, ARRAYSIZE(levels),
          D3D11_SDK_VERSION, device.GetAddressOf(), nullptr, nullptr))) {
    return false;
  }
  Microsoft::WRL::ComPtr<IDXGIDevice> dxgi_device;
  Microsoft::WRL::ComPtr<IDXGIAdapter> adapter;
  Microsoft::WRL::ComPtr<IDXGIAdapter1> adapter1;
  DXGI_ADAPTER_DESC1 description{};
  if (FAILED(device.As(&dxgi_device)) ||
      FAILED(dxgi_device->GetAdapter(adapter.GetAddressOf())) ||
      FAILED(adapter.As(&adapter1)) ||
      FAILED(adapter1->GetDesc1(&description))) {
    // Preserve Flutter's default if the selected device cannot be identified.
    return true;
  }
  return (description.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) == 0;
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
  } else if (std::wstring(renderer) == L"skia" || !HasHardwareRenderDevice()) {
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
  Win32Window::Size size(1120, 820);
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
