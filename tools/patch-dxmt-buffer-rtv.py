#!/usr/bin/env python3
"""Render target views on a buffer: log every failed CreateRenderTargetView, and an opt-in empty view for a buffer.

Need for Speed: The Run (Frostbite 2; Discord game-reports 2026-10-28 and Send Log FRGCNV, build 614, iPhone18,2) stops at
its loading screen with "DirectX error / DirectX function g_dxRenderer->getDevice()->CreateRenderTargetView(
desc.renderTargetResources[targetIt], ...) failed with E_INVALIDARG". Just before it DXMT logs
"D3D11Resource(buffer): Unknown interface query 6f15aaf2-..." (the game asking a buffer for ID3D11Texture2D): the game asks
for a render target view on a buffer. DXMT has no such view (only its device textures implement CreateRenderTargetView; the
buffer's answer is E_INVALIDARG). Frostbite 2 does this in every game of that generation: DXVK answered S_OK and no view for a
buffer from 2018 until 2026-08 ("It is required to run Battlefield 3 and Battlefield 4", doitsujin/dxvk 2942587876 replaced it
with a private 1D image; the games ran either way, Battlefield 3 lacked some clouds).

This patch:
  1. d3d11_device.cpp CreateRenderTargetView1: every failure is logged ([rtv-fail], 8 lines, then powers of two) with the
     resource (dimension, size, usage, bind flags) and the view description, so the next such report names its cause.
     With env.MADEIRA_BUFFER_RTV_EMPTY = 1 (or the DXMT option d3d11.bufferRtvEmpty=1) a failed view on a BUFFER returns
     S_OK with no view, as DXVK did. Off by default: nothing changes for any game without the line.
  2. d3d11_context_impl.cpp ClearRenderTargetView: a null view is ignored (DXVK does the same) instead of dereferenced. A
     null view crashed there before; no game that runs today passes one.
  3. d3d10_device.cpp CreateRenderTargetView: an S_OK with no D3D11 view returns S_OK with no D3D10 view instead of
     calling through a null pointer (reachable only with the switch on).

Idempotent; fails by name if an anchor moved. Run from the repository root.
"""
import pathlib
import sys

ROOT = pathlib.Path("dxmt/src")
MARKER = "madeira-bcd: render target views on a buffer"

DEV = "d3d11/d3d11_device.cpp"
DEV_NS_OLD = "\nnamespace dxmt {\n"
DEV_NS_NEW = """
#include <atomic>   /* madeira-bcd: render target views on a buffer */
#include <cstdio>
#include "util_env.hpp"

namespace dxmt {

/* madeira-bcd: render target views on a buffer (round 620: Need for Speed: The Run, Frostbite 2; Discord 2026-10-28, FRGCNV).
 * DXMT has no render target view on a buffer and answers E_INVALIDARG; the game then stops with its "DirectX error" box.
 * DXVK answered S_OK and no view for a buffer from 2018 until 2026-08 (Battlefield 3 and 4). env.MADEIRA_BUFFER_RTV_EMPTY = 1
 * (or d3d11.bufferRtvEmpty=1) does the same here; off by default. Every failed view is logged as [rtv-fail]. */
namespace {

bool MadeiraBufferRtvEmpty() {
  static const bool on = [] {
    const std::string env_v = env::getEnvVar("MADEIRA_BUFFER_RTV_EMPTY");
    if (!env_v.empty())
      return env_v != "0";
    return Config::getInstance().getOption<int>("d3d11.bufferRtvEmpty", 0) > 0;
  }();
  return on;
}

void MadeiraLogRtvFailure(ID3D11Resource *pResource, const D3D11_RENDER_TARGET_VIEW_DESC1 *pDesc, HRESULT hr, bool empty) {
  static std::atomic<unsigned> failures{0};
  unsigned n = ++failures;
  if (n > 8 && (n & (n - 1)))
    return;
  D3D11_RESOURCE_DIMENSION dim = D3D11_RESOURCE_DIMENSION_UNKNOWN;
  char res[200] = "no resource";
  if (pResource) {
    pResource->GetType(&dim);
    auto common = static_cast<D3D11ResourceCommon *>(pResource);
    if (dim == D3D11_RESOURCE_DIMENSION_BUFFER) {
      D3D11_BUFFER_DESC d = {};
      common->GetDesc(&d);
      snprintf(res, sizeof res, "resource=buffer bytes=%u usage=%u bind=0x%x misc=0x%x stride=%u", d.ByteWidth,
               (unsigned)d.Usage, d.BindFlags, d.MiscFlags, d.StructureByteStride);
    } else if (dim == D3D11_RESOURCE_DIMENSION_TEXTURE2D) {
      D3D11_TEXTURE2D_DESC d = {};
      common->GetDesc(&d);
      snprintf(res, sizeof res, "resource=tex2d %ux%u format=%u mips=%u array=%u samples=%u usage=%u bind=0x%x misc=0x%x",
               d.Width, d.Height, (unsigned)d.Format, d.MipLevels, d.ArraySize, d.SampleDesc.Count, (unsigned)d.Usage,
               d.BindFlags, d.MiscFlags);
    } else {
      snprintf(res, sizeof res, "resource=dimension%u", (unsigned)dim);
    }
  }
  char view[128] = "view=whole resource";
  if (pDesc) {
    if (pDesc->ViewDimension == D3D11_RTV_DIMENSION_BUFFER)
      snprintf(view, sizeof view, "view format=%u dimension=buffer first=%u count=%u", (unsigned)pDesc->Format,
               pDesc->Buffer.FirstElement, pDesc->Buffer.NumElements);
    else
      snprintf(view, sizeof view, "view format=%u dimension=%u", (unsigned)pDesc->Format, (unsigned)pDesc->ViewDimension);
  }
  char code[48];
  if (hr == E_INVALIDARG)
    snprintf(code, sizeof code, "E_INVALIDARG");
  else
    snprintf(code, sizeof code, "0x%08x", (unsigned)hr);
  const char *what = empty ? " -> S_OK with no view (env.MADEIRA_BUFFER_RTV_EMPTY)"
                     : dim == D3D11_RESOURCE_DIMENSION_BUFFER
                         ? " (DXMT has no render target view on a buffer; env.MADEIRA_BUFFER_RTV_EMPTY = 1 answers S_OK and no view, as DXVK did)"
                         : "";
  ERR("[rtv-fail] #", n, " CreateRenderTargetView ", code, " ", res, " ", view, what);
}

} // namespace
"""

DEV_OLD = """    if (!pResource)
      return E_INVALIDARG;

    if (!ppRTView)
      return S_FALSE;

    return static_cast<D3D11ResourceCommon *>(pResource)->CreateRenderTargetView(pDesc, ppRTView);
  }
"""
DEV_NEW = """    if (!pResource) {
      MadeiraLogRtvFailure(nullptr, pDesc, E_INVALIDARG, false);   /* madeira-bcd: render target views on a buffer */
      return E_INVALIDARG;
    }

    if (!ppRTView)
      return S_FALSE;

    HRESULT hr = static_cast<D3D11ResourceCommon *>(pResource)->CreateRenderTargetView(pDesc, ppRTView);
    if (FAILED(hr)) {
      D3D11_RESOURCE_DIMENSION dim = D3D11_RESOURCE_DIMENSION_UNKNOWN;
      pResource->GetType(&dim);
      const bool empty = dim == D3D11_RESOURCE_DIMENSION_BUFFER && MadeiraBufferRtvEmpty();
      MadeiraLogRtvFailure(pResource, pDesc, hr, empty);
      if (empty)
        return S_OK;   /* *ppRTView is still nullptr (InitReturnPtr) */
    }
    return hr;
  }
"""

CTX = "d3d11/d3d11_context_impl.cpp"
CTX_OLD = """  ClearRenderTargetView(ID3D11RenderTargetView *pRenderTargetView, const FLOAT ColorRGBA[4]) override {
    std::lock_guard<mutex_t> lock(mutex);

    ClearRenderTargetView(static_cast<D3D11RenderTargetView *>(pRenderTargetView), ColorRGBA);
  }
"""
CTX_NEW = """  ClearRenderTargetView(ID3D11RenderTargetView *pRenderTargetView, const FLOAT ColorRGBA[4]) override {
    /* madeira-bcd: render target views on a buffer. A null view is ignored, as in DXVK (it was dereferenced). */
    if (!pRenderTargetView)
      return;

    std::lock_guard<mutex_t> lock(mutex);

    ClearRenderTargetView(static_cast<D3D11RenderTargetView *>(pRenderTargetView), ColorRGBA);
  }
"""

D10 = "d3d10/d3d10_device.cpp"
D10_OLD = """  if (hr != S_OK)
    return hr;

  return ppRTView ? d3d11_view->QueryInterface(IID_PPV_ARGS(ppRTView)) : hr;
"""
D10_NEW = """  if (hr != S_OK)
    return hr;

  /* madeira-bcd: render target views on a buffer. S_OK with no view (env.MADEIRA_BUFFER_RTV_EMPTY): no view here either. */
  if (ppRTView && !d3d11_view)
    return S_OK;

  return ppRTView ? d3d11_view->QueryInterface(IID_PPV_ARGS(ppRTView)) : hr;
"""


def patch(rel, pairs):
    path = ROOT / rel
    s = path.read_text()
    if MARKER in s:
        print(f"{rel}: already patched")
        return
    for old, new in pairs:
        if s.count(old) != 1:
            sys.exit(f"patch-dxmt-buffer-rtv: anchor found {s.count(old)} times in {rel}")
        s = s.replace(old, new, 1)
    path.write_text(s)
    print(f"{rel}: patched")


def main():
    patch(DEV, [(DEV_NS_OLD, DEV_NS_NEW), (DEV_OLD, DEV_NEW)])
    patch(CTX, [(CTX_OLD, CTX_NEW)])
    patch(D10, [(D10_OLD, D10_NEW)])


main()
