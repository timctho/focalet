#ifndef RUNNER_DESKTOP_SNAPSHOT_H_
#define RUNNER_DESKTOP_SNAPSHOT_H_

#include <windows.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <dcomp.h>
#include <wrl/client.h>

// One requested desktop snapshot; no background capture or retained history.
class DesktopSnapshot {
 public:
  bool Prepare(HMONITOR monitor);
  bool Capture(const RECT& area, void* pixels, size_t stride);
  // The caller destroys the returned window, then releases its snapshot.
  HWND ShowOverlay(HWND owner, const RECT& area);
  void ReleaseOverlay();
  void Reset();

 private:
  HMONITOR monitor_ = nullptr;
  DXGI_OUTPUT_DESC output_{};
  Microsoft::WRL::ComPtr<ID3D11Device> device_;
  Microsoft::WRL::ComPtr<ID3D11DeviceContext> context_;
  Microsoft::WRL::ComPtr<IDXGIOutputDuplication> duplication_;
  Microsoft::WRL::ComPtr<ID3D11Texture2D> staging_;
  UINT width_ = 0;
  UINT height_ = 0;
  Microsoft::WRL::ComPtr<IDXGISwapChain1> overlay_swap_chain_;
  Microsoft::WRL::ComPtr<IDCompositionDevice> composition_;
  Microsoft::WRL::ComPtr<IDCompositionTarget> composition_target_;
  Microsoft::WRL::ComPtr<IDCompositionVisual> composition_visual_;
};

#endif
