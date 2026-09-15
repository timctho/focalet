#include "desktop_snapshot.h"

#include <cstring>

using Microsoft::WRL::ComPtr;

void DesktopSnapshot::ReleaseOverlay() {
  composition_visual_.Reset();
  composition_target_.Reset();
  composition_.Reset();
  overlay_swap_chain_.Reset();
  staging_.Reset();
  width_ = height_ = 0;
}

HWND DesktopSnapshot::ShowOverlay(HWND owner, const RECT& area) {
  if (area.right <= area.left || area.bottom <= area.top ||
      !Prepare(MonitorFromRect(&area, MONITOR_DEFAULTTONEAREST))) return nullptr;
  const RECT& desktop = output_.DesktopCoordinates;
  if (area.left < desktop.left || area.top < desktop.top ||
      area.right > desktop.right || area.bottom > desktop.bottom) return nullptr;
  DXGI_OUTDUPL_FRAME_INFO information{};
  ComPtr<IDXGIResource> resource;
  const HRESULT acquired = duplication_->AcquireNextFrame(0, &information, &resource);
  if (FAILED(acquired)) {
    if (acquired != DXGI_ERROR_WAIT_TIMEOUT) Reset();
    return nullptr;
  }
  struct ReleaseFrame {
    ComPtr<IDXGIOutputDuplication> owner;
    ~ReleaseFrame() { owner->ReleaseFrame(); }
  } release{duplication_};
  ComPtr<ID3D11Texture2D> texture;
  if (FAILED(resource.As(&texture))) return nullptr;
  D3D11_TEXTURE2D_DESC source{};
  texture->GetDesc(&source);
  if (source.Format != DXGI_FORMAT_B8G8R8A8_UNORM ||
      source.Width < static_cast<UINT>(area.right - desktop.left) ||
      source.Height < static_cast<UINT>(area.bottom - desktop.top)) return nullptr;
  const UINT width = area.right - area.left;
  const UINT height = area.bottom - area.top;
  HWND window = CreateWindowExW(
      WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW | WS_EX_TOPMOST | WS_EX_NOREDIRECTIONBITMAP,
      L"STATIC", L"Zommi resize handoff", WS_POPUP | SS_NOTIFY,
      area.left, area.top, width, height, owner, nullptr,
      GetModuleHandleW(nullptr), nullptr);
  if (!window) return nullptr;
  const auto fail = [&]() -> HWND {
    ReleaseOverlay();
    DestroyWindow(window);
    return nullptr;
  };
  ComPtr<IDXGIDevice> dxgi_device;
  ComPtr<IDXGIAdapter> adapter;
  ComPtr<IDXGIFactory2> factory;
  if (FAILED(device_.As(&dxgi_device)) ||
      FAILED(dxgi_device->GetAdapter(&adapter)) ||
      FAILED(adapter->GetParent(IID_PPV_ARGS(&factory)))) return fail();
  DXGI_SWAP_CHAIN_DESC1 description{};
  description.Width = width;
  description.Height = height;
  description.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
  description.SampleDesc.Count = 1;
  description.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
  description.BufferCount = 2;
  description.SwapEffect = DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL;
  description.Scaling = DXGI_SCALING_STRETCH;
  description.AlphaMode = DXGI_ALPHA_MODE_IGNORE;
  if (FAILED(factory->CreateSwapChainForComposition(
          device_.Get(), &description, nullptr, &overlay_swap_chain_))) return fail();
  ComPtr<ID3D11Texture2D> buffer;
  if (FAILED(overlay_swap_chain_->GetBuffer(0, IID_PPV_ARGS(&buffer)))) return fail();
  const D3D11_BOX region{static_cast<UINT>(area.left - desktop.left),
                        static_cast<UINT>(area.top - desktop.top), 0,
                        static_cast<UINT>(area.right - desktop.left),
                        static_cast<UINT>(area.bottom - desktop.top), 1};
  context_->CopySubresourceRegion(buffer.Get(), 0, 0, 0, 0, texture.Get(), 0, &region);
  // Keep the snapshot in GPU memory. Commit its visual before resizing the
  // real window; waiting for a desktop refresh here adds an unnecessary frame
  // of latency. The overlay remains until Flutter presents the new frame.
  if (FAILED(overlay_swap_chain_->Present(0, 0)) ||
      FAILED(DCompositionCreateDevice(dxgi_device.Get(), IID_PPV_ARGS(&composition_))) ||
      FAILED(composition_->CreateTargetForHwnd(window, TRUE, &composition_target_)) ||
      FAILED(composition_->CreateVisual(&composition_visual_)) ||
      FAILED(composition_visual_->SetContent(overlay_swap_chain_.Get())) ||
      FAILED(composition_target_->SetRoot(composition_visual_.Get())) ||
      FAILED(composition_->Commit()) ||
      !SetWindowPos(window, HWND_TOPMOST, area.left, area.top, width, height,
                    SWP_NOACTIVATE | SWP_SHOWWINDOW) ||
      FAILED(composition_->WaitForCommitCompletion())) return fail();
  return window;
}

void DesktopSnapshot::Reset() {
  staging_.Reset();
  duplication_.Reset();
  context_.Reset();
  device_.Reset();
  monitor_ = nullptr;
  width_ = height_ = 0;
}

bool DesktopSnapshot::Prepare(HMONITOR monitor) {
  if (monitor_ == monitor && duplication_) return true;
  Reset();
  ComPtr<IDXGIFactory1> factory;
  if (FAILED(CreateDXGIFactory1(IID_PPV_ARGS(&factory)))) return false;
  for (UINT adapter_index = 0; ; ++adapter_index) {
    ComPtr<IDXGIAdapter1> adapter;
    if (factory->EnumAdapters1(adapter_index, &adapter) != S_OK) break;
    for (UINT output_index = 0; ; ++output_index) {
      ComPtr<IDXGIOutput> output;
      if (adapter->EnumOutputs(output_index, &output) != S_OK) break;
      DXGI_OUTPUT_DESC description{};
      if (FAILED(output->GetDesc(&description)) ||
          description.Monitor != monitor || !description.AttachedToDesktop ||
          (description.Rotation != DXGI_MODE_ROTATION_IDENTITY &&
           description.Rotation != DXGI_MODE_ROTATION_UNSPECIFIED)) continue;
      ComPtr<IDXGIOutput1> output1;
      if (FAILED(output.As(&output1)) ||
          FAILED(D3D11CreateDevice(adapter.Get(), D3D_DRIVER_TYPE_UNKNOWN,
                                  nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                                  nullptr, 0, D3D11_SDK_VERSION, &device_,
                                  nullptr, &context_)) ||
          FAILED(output1->DuplicateOutput(device_.Get(), &duplication_))) {
        Reset();
        return false;
      }
      output_ = description;
      monitor_ = monitor;
      return true;
    }
  }
  return false;
}

bool DesktopSnapshot::Capture(const RECT& area, void* pixels, size_t stride) {
  if (!pixels || area.right <= area.left || area.bottom <= area.top ||
      !Prepare(MonitorFromRect(&area, MONITOR_DEFAULTTONEAREST))) return false;
  const RECT& desktop = output_.DesktopCoordinates;
  if (area.left < desktop.left || area.top < desktop.top ||
      area.right > desktop.right || area.bottom > desktop.bottom) return false;
  const UINT width = static_cast<UINT>(area.right - area.left);
  const UINT height = static_cast<UINT>(area.bottom - area.top);
  if (stride < static_cast<size_t>(width) * 4) return false;

  DXGI_OUTDUPL_FRAME_INFO information{};
  ComPtr<IDXGIResource> resource;
  const HRESULT acquired = duplication_->AcquireNextFrame(0, &information, &resource);
  if (FAILED(acquired)) {
    if (acquired != DXGI_ERROR_WAIT_TIMEOUT) Reset();
    return false;
  }
  struct ReleaseFrame {
    ComPtr<IDXGIOutputDuplication> owner;
    ~ReleaseFrame() { owner->ReleaseFrame(); }
  } release{duplication_};
  ComPtr<ID3D11Texture2D> texture;
  if (FAILED(resource.As(&texture))) return false;
  D3D11_TEXTURE2D_DESC source{};
  texture->GetDesc(&source);
  if (source.Format != DXGI_FORMAT_B8G8R8A8_UNORM ||
      source.Width < static_cast<UINT>(area.right - desktop.left) ||
      source.Height < static_cast<UINT>(area.bottom - desktop.top)) return false;

  if (!staging_ || width_ != width || height_ != height) {
    staging_.Reset();
    D3D11_TEXTURE2D_DESC description{};
    description.Width = width;
    description.Height = height;
    description.MipLevels = description.ArraySize = 1;
    description.Format = source.Format;
    description.SampleDesc.Count = 1;
    description.Usage = D3D11_USAGE_STAGING;
    description.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    if (FAILED(device_->CreateTexture2D(&description, nullptr, &staging_))) return false;
    width_ = width;
    height_ = height;
  }
  const D3D11_BOX region{static_cast<UINT>(area.left - desktop.left),
                        static_cast<UINT>(area.top - desktop.top), 0,
                        static_cast<UINT>(area.right - desktop.left),
                        static_cast<UINT>(area.bottom - desktop.top), 1};
  context_->CopySubresourceRegion(staging_.Get(), 0, 0, 0, 0,
                                  texture.Get(), 0, &region);
  D3D11_MAPPED_SUBRESOURCE mapped{};
  if (FAILED(context_->Map(staging_.Get(), 0, D3D11_MAP_READ, 0, &mapped))) {
    Reset();
    return false;
  }
  for (UINT row = 0; row < height; ++row) {
    std::memcpy(static_cast<unsigned char*>(pixels) + row * stride,
                static_cast<const unsigned char*>(mapped.pData) + row * mapped.RowPitch,
                static_cast<size_t>(width) * 4);
  }
  context_->Unmap(staging_.Get(), 0);
  return true;
}
