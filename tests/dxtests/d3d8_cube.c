// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
//
// BCD's Direct3D 8 test (round 602): a spinning textured cube drawn with the fixed-function pipeline (a texture modulated by
// the vertex colour, one world, view and projection matrix, a depth buffer), so it needs no shader. 32-bit (x86) Windows like
// the Direct3D 8 games, which are all 32-bit. See dxtest.h for what it shares with the other cube tests.
//
// BCD has no OpenGL, which Wine's own d3d8.dll (wined3d) draws with. What this test shows is whether Direct3D 8 works in the
// session at all, whichever d3d8.dll the session was given: it asks for a device like a game would, logs every answer, and
// never decides beforehand that it cannot work. Before the cube it makes the Direct3D 8 calls an old game makes at startup
// (adapter, display mode, device and format checks, caps), each a logged PASS or FAIL with its numbers; after two seconds of
// drawing it logs the verdict and reads the back buffer once with CopyRects, the Direct3D 8 way.
//
// It also says which d3d8.dll it got: the version resource of a d3d8to9 build (crosire's Direct3D 8 on Direct3D 9) holds
// that name, Wine's own does not. That line is information only.

#define COBJMACROS
#include "dxtest.h"
#include <d3d8.h>

#define API "Direct3D 8"

typedef IDirect3D8 *(WINAPI *create_fn)(UINT);

struct vertex8 { float x, y, z; DWORD diffuse; float u, v; };
#define FVF8 (D3DFVF_XYZ | D3DFVF_DIFFUSE | D3DFVF_TEX1)

static unsigned checks, check_fails;

/* A start-up check: logged as PASS or FAIL with its numbers, and counted. */
static void check(int ok, const char *what, const char *fmt, ...)
{
    char details[300];
    va_list ap;

    details[0] = 0;
    if (fmt) {
        va_start(ap, fmt);
        vsnprintf(details, sizeof details, fmt, ap);
        va_end(ap);
    }
    checks++;
    if (!ok) check_fails++;
    dxt_log(API " (%d-bit): %s %s%s%s", DXT_BITS, ok ? "PASS" : "FAIL", what, details[0] ? ": " : "", details);
}

/* A call the cube cannot go on without: a failure is a FAIL line, the RESULT line, a message box, and the end. */
#define CHECK(call, what) do { HRESULT hr_ = (call); if (FAILED(hr_)) { \
        char m_[200]; snprintf(m_, sizeof m_, "%s failed (%#lx)", what, (unsigned long)hr_); \
        check(0, what, "%#lx", (unsigned long)hr_); \
        route_hint(is9); \
        dxt_log(API " (%d-bit): RESULT FAIL (%u of %u checks passed, %u failed)", DXT_BITS, checks - check_fails, checks, check_fails); \
        dxt_fail(API, m_); return 1; } } while (0)

/* The module's version resource holds the name "d3d8to9" (in UTF-16) in a d3d8to9 build. */
static int is_d3d8to9(HMODULE dll)
{
    static const WCHAR tag[] = L"d3d8to9";
    HRSRC res = FindResourceW(dll, MAKEINTRESOURCEW(1), (LPCWSTR)RT_VERSION);
    HGLOBAL mem = res ? LoadResource(dll, res) : NULL;
    const BYTE *p = mem ? (const BYTE *)LockResource(mem) : NULL;
    DWORD n = res ? SizeofResource(dll, res) : 0, i;

    if (!p) return 0;
    for (i = 0; i + sizeof tag <= n; i++)
        if (memcmp(p + i, tag, sizeof tag - sizeof(WCHAR)) == 0) return 1;
    return 0;
}

/* Once, after the verdict: the back buffer to a system-memory image surface (CopyRects, as Direct3D 8 does it), then the
 * pixel at the centre (the cube) and near the corner (the clear colour). Information only. */
static void readback(IDirect3DDevice8 *dev)
{
    IDirect3DSurface8 *back = NULL, *img = NULL;
    D3DLOCKED_RECT lr;
    HRESULT hr;

    hr = IDirect3DDevice8_GetBackBuffer(dev, 0, D3DBACKBUFFER_TYPE_MONO, &back);
    if (FAILED(hr)) { dxt_log(API ": read-back: GetBackBuffer returned %#lx", (unsigned long)hr); return; }
    hr = IDirect3DDevice8_CreateImageSurface(dev, DXT_W, DXT_H, D3DFMT_X8R8G8B8, &img);
    if (FAILED(hr)) {
        dxt_log(API ": read-back: CreateImageSurface returned %#lx", (unsigned long)hr);
    } else if (FAILED(hr = IDirect3DDevice8_CopyRects(dev, back, NULL, 0, img, NULL))) {
        dxt_log(API ": read-back: CopyRects returned %#lx (not supported for the back buffer, or the device is busy)", (unsigned long)hr);
    } else if (FAILED(hr = IDirect3DSurface8_LockRect(img, &lr, NULL, D3DLOCK_READONLY))) {
        dxt_log(API ": read-back: LockRect returned %#lx", (unsigned long)hr);
    } else {
        const unsigned char *row_c = (const unsigned char *)lr.pBits + (DXT_H / 2) * lr.Pitch;
        const unsigned char *row_0 = (const unsigned char *)lr.pBits + 4 * lr.Pitch;
        unsigned centre = *(const unsigned *)(row_c + (DXT_W / 2) * 4) & 0xFFFFFF, corner = *(const unsigned *)(row_0 + 4 * 4) & 0xFFFFFF;
        dxt_log(API ": read-back: centre %06x, corner %06x (clear colour 0f121a): %s", centre, corner,
                centre != corner ? "the cube is in the back buffer" : "the centre is the clear colour (nothing drawn, or the read-back returns nothing)");
        IDirect3DSurface8_UnlockRect(img);
    }
    if (img) IDirect3DSurface8_Release(img);
    IDirect3DSurface8_Release(back);
}

/* Said when Direct3D 8 does not work and the d3d8.dll is not d3d8to9: what routes it to Direct3D 9 (round 602, env.MADEIRA_D3D8). */
static void route_hint(int is_9)
{
    if (!is_9)
        dxt_log(API ": hint: Wine's own Direct3D 8 draws with OpenGL, which iOS does not have. env.MADEIRA_D3D8 = d3d9 in the settings of the session "
                "(the Windows desktop's, or the game's) links d3d8to9 instead, which draws through DXMT's Direct3D 9");
}

int WINAPI WinMain(HINSTANCE inst, HINSTANCE prev, LPSTR cmd, int show)
{
    HMODULE dll;
    create_fn create;
    HWND hwnd;
    IDirect3D8 *d3d;
    IDirect3DDevice8 *dev = NULL;
    IDirect3DVertexBuffer8 *vb = NULL;
    IDirect3DIndexBuffer8 *ib = NULL;
    IDirect3DTexture8 *tex = NULL;
    D3DPRESENT_PARAMETERS pp;
    D3DADAPTER_IDENTIFIER8 id;
    D3DDISPLAYMODE mode;
    D3DCAPS8 caps;
    dxt_vertex cube[24];
    struct vertex8 verts[24];
    unsigned short idx[36];
    dxt_clock clock;
    unsigned failures = 0, presented = 0, reported = 0, modes;
    char title[96], verdict[16], path[MAX_PATH];
    HRESULT hr;
    BYTE *p;
    int i, drew, is9;

    (void)inst; (void)prev; (void)cmd; (void)show;
    dxt_crash_log();
    dxt_log(API " (%d-bit): start, %dx%d", DXT_BITS, DXT_W, DXT_H);
    snprintf(title, sizeof title, "BCD DirectX 8 test (%d-bit)", DXT_BITS);
    dll = LoadLibraryA("d3d8.dll");
    create = dll ? (create_fn)GetProcAddress(dll, "Direct3DCreate8") : NULL;
    if (!create) {
        check(0, "d3d8.dll", "not available (LoadLibrary %lu)", GetLastError());
        dxt_log(API " (%d-bit): RESULT FAIL (d3d8.dll is not available)", DXT_BITS);
        dxt_fail(API, "d3d8.dll (Direct3DCreate8) is not available");
        return 1;
    }
    path[0] = 0;
    GetModuleFileNameA(dll, path, sizeof path);
    is9 = is_d3d8to9(dll);
    {
        char sw[32];
        sw[0] = 0;
        GetEnvironmentVariableA("MADEIRA_D3D8", sw, sizeof sw);
        dxt_log(API ": d3d8.dll is %s (%s); env.MADEIRA_D3D8 = %s", path, is9 ? "d3d8to9: Direct3D 8 on Direct3D 9" : "not a d3d8to9 build; Wine's own d3d8 needs OpenGL", sw[0] ? sw : "(not set)");
    }
    hwnd = dxt_window(title);
    if (!hwnd) {
        check(0, "window", "could not be created");
        dxt_log(API " (%d-bit): RESULT FAIL (no window)", DXT_BITS);
        dxt_fail(API, "the window could not be created");
        return 1;
    }

    d3d = create(220);   /* D3D_SDK_VERSION of Direct3D 8 */
    if (!d3d) {
        check(0, "Direct3DCreate8", "returned no interface (Wine's d3d8 without OpenGL says so)");
        route_hint(is9);
        dxt_log(API " (%d-bit): RESULT FAIL (Direct3DCreate8 returned no interface)", DXT_BITS);
        dxt_fail(API, "Direct3DCreate8 returned no interface");
        return 1;
    }
    check(1, "Direct3DCreate8", "interface %p", (void *)d3d);

    memset(&id, 0, sizeof id);
    hr = IDirect3D8_GetAdapterIdentifier(d3d, D3DADAPTER_DEFAULT, 0, &id);
    if (SUCCEEDED(hr))
        check(1, "GetAdapterIdentifier", "\"%s\", driver \"%s\", vendor %04lx device %04lx", id.Description, id.Driver,
              (unsigned long)id.VendorId, (unsigned long)id.DeviceId);
    else
        check(0, "GetAdapterIdentifier", "%#lx", (unsigned long)hr);
    memset(&mode, 0, sizeof mode);
    hr = IDirect3D8_GetAdapterDisplayMode(d3d, D3DADAPTER_DEFAULT, &mode);
    check(SUCCEEDED(hr) && mode.Width > 0, "GetAdapterDisplayMode", "%ux%u, %u Hz, format %u (R5G6B5=23, X8R8G8B8=22)", mode.Width, mode.Height,
          mode.RefreshRate, (unsigned)mode.Format);
    modes = IDirect3D8_GetAdapterModeCount(d3d, D3DADAPTER_DEFAULT);
    check(modes > 0, "GetAdapterModeCount", "%u modes", modes);
    hr = IDirect3D8_CheckDeviceType(d3d, D3DADAPTER_DEFAULT, D3DDEVTYPE_HAL, mode.Format ? mode.Format : D3DFMT_X8R8G8B8, mode.Format ? mode.Format : D3DFMT_X8R8G8B8, TRUE);
    check(SUCCEEDED(hr), "CheckDeviceType (HAL, windowed)", "%#lx", (unsigned long)hr);
    hr = IDirect3D8_CheckDeviceFormat(d3d, D3DADAPTER_DEFAULT, D3DDEVTYPE_HAL, mode.Format ? mode.Format : D3DFMT_X8R8G8B8, 0, D3DRTYPE_TEXTURE, D3DFMT_A8R8G8B8);
    check(SUCCEEDED(hr), "CheckDeviceFormat (A8R8G8B8 texture)", "%#lx", (unsigned long)hr);
    hr = IDirect3D8_CheckDeviceFormat(d3d, D3DADAPTER_DEFAULT, D3DDEVTYPE_HAL, mode.Format ? mode.Format : D3DFMT_X8R8G8B8, 0, D3DRTYPE_TEXTURE, D3DFMT_DXT1);
    dxt_log(API ": DXT1 textures %s (%#lx); information only", SUCCEEDED(hr) ? "supported" : "not supported", (unsigned long)hr);
    memset(&caps, 0, sizeof caps);
    hr = IDirect3D8_GetDeviceCaps(d3d, D3DADAPTER_DEFAULT, D3DDEVTYPE_HAL, &caps);
    check(SUCCEEDED(hr) && caps.MaxTextureWidth >= 256, "GetDeviceCaps", "vertex shader %u.%u, pixel shader %u.%u, max texture %lux%lu, %lu texture stages",
          (unsigned)D3DSHADER_VERSION_MAJOR(caps.VertexShaderVersion), (unsigned)D3DSHADER_VERSION_MINOR(caps.VertexShaderVersion),
          (unsigned)D3DSHADER_VERSION_MAJOR(caps.PixelShaderVersion), (unsigned)D3DSHADER_VERSION_MINOR(caps.PixelShaderVersion),
          (unsigned long)caps.MaxTextureWidth, (unsigned long)caps.MaxTextureHeight, (unsigned long)caps.MaxSimultaneousTextures);

    memset(&pp, 0, sizeof pp);
    pp.BackBufferWidth = DXT_W;
    pp.BackBufferHeight = DXT_H;
    pp.BackBufferFormat = mode.Format ? mode.Format : D3DFMT_X8R8G8B8;
    pp.BackBufferCount = 1;
    pp.SwapEffect = D3DSWAPEFFECT_DISCARD;
    pp.hDeviceWindow = hwnd;
    pp.Windowed = TRUE;
    pp.EnableAutoDepthStencil = TRUE;
    pp.AutoDepthStencilFormat = D3DFMT_D24S8;
    pp.FullScreen_PresentationInterval = D3DPRESENT_INTERVAL_DEFAULT;   /* Direct3D 8 wants the default in a window */
    hr = IDirect3D8_CreateDevice(d3d, D3DADAPTER_DEFAULT, D3DDEVTYPE_HAL, hwnd, D3DCREATE_HARDWARE_VERTEXPROCESSING, &pp, &dev);
    if (FAILED(hr)) {
        dxt_log(API ": CreateDevice with hardware vertex processing returned %#lx; trying software", (unsigned long)hr);
        hr = IDirect3D8_CreateDevice(d3d, D3DADAPTER_DEFAULT, D3DDEVTYPE_HAL, hwnd, D3DCREATE_SOFTWARE_VERTEXPROCESSING, &pp, &dev);
    }
    if (FAILED(hr)) {   /* a 16-bit depth buffer is the common one of the era */
        pp.AutoDepthStencilFormat = D3DFMT_D16;
        dxt_log(API ": CreateDevice with a 24-bit depth buffer returned %#lx; trying 16-bit depth", (unsigned long)hr);
        hr = IDirect3D8_CreateDevice(d3d, D3DADAPTER_DEFAULT, D3DDEVTYPE_HAL, hwnd, D3DCREATE_SOFTWARE_VERTEXPROCESSING, &pp, &dev);
    }
    CHECK(hr, "CreateDevice");
    check(1, "CreateDevice", "%#lx, depth format %u", (unsigned long)hr, (unsigned)pp.AutoDepthStencilFormat);

    /* the cube, as fixed-function vertices (position, diffuse colour, one texture coordinate pair) */
    dxt_cube(cube, idx);
    for (i = 0; i < 24; i++) {
        verts[i].x = cube[i].x; verts[i].y = cube[i].y; verts[i].z = cube[i].z;
        verts[i].diffuse = D3DCOLOR_ARGB(cube[i].a, cube[i].r, cube[i].g, cube[i].b);
        verts[i].u = cube[i].u; verts[i].v = cube[i].v;
    }
    CHECK(IDirect3DDevice8_CreateVertexBuffer(dev, sizeof verts, D3DUSAGE_WRITEONLY, FVF8, D3DPOOL_MANAGED, &vb), "CreateVertexBuffer");
    CHECK(IDirect3DVertexBuffer8_Lock(vb, 0, 0, &p, 0), "Lock (vertices)");
    memcpy(p, verts, sizeof verts);
    IDirect3DVertexBuffer8_Unlock(vb);
    CHECK(IDirect3DDevice8_CreateIndexBuffer(dev, sizeof idx, D3DUSAGE_WRITEONLY, D3DFMT_INDEX16, D3DPOOL_MANAGED, &ib), "CreateIndexBuffer");
    CHECK(IDirect3DIndexBuffer8_Lock(ib, 0, 0, &p, 0), "Lock (indices)");
    memcpy(p, idx, sizeof idx);
    IDirect3DIndexBuffer8_Unlock(ib);
    check(1, "vertex and index buffers", "24 vertices, 36 indices");

    /* the texture, filled through LockRect and read back through it */
    CHECK(IDirect3DDevice8_CreateTexture(dev, DXT_TEX, DXT_TEX, 1, 0, D3DFMT_A8R8G8B8, D3DPOOL_MANAGED, &tex), "CreateTexture");
    {
        D3DLOCKED_RECT lr;
        unsigned texels[DXT_TEX * DXT_TEX], back_px = 0;
        int y;
        dxt_checker(texels);
        CHECK(IDirect3DTexture8_LockRect(tex, 0, &lr, NULL, 0), "LockRect");
        for (y = 0; y < DXT_TEX; y++) memcpy((BYTE *)lr.pBits + y * lr.Pitch, texels + y * DXT_TEX, DXT_TEX * 4);
        IDirect3DTexture8_UnlockRect(tex, 0);
        if (SUCCEEDED(IDirect3DTexture8_LockRect(tex, 0, &lr, NULL, D3DLOCK_READONLY))) {
            back_px = *(const unsigned *)((const BYTE *)lr.pBits + 10 * lr.Pitch + 10 * 4);
            IDirect3DTexture8_UnlockRect(tex, 0);
        }
        check(back_px == texels[10 * DXT_TEX + 10], "texture LockRect round trip", "wrote %08x, read %08x", texels[10 * DXT_TEX + 10], back_px);
    }

    IDirect3DDevice8_SetRenderState(dev, D3DRS_LIGHTING, FALSE);
    IDirect3DDevice8_SetRenderState(dev, D3DRS_ZENABLE, TRUE);
    IDirect3DDevice8_SetRenderState(dev, D3DRS_CULLMODE, D3DCULL_NONE);
    IDirect3DDevice8_SetTexture(dev, 0, (IDirect3DBaseTexture8 *)tex);
    IDirect3DDevice8_SetTextureStageState(dev, 0, D3DTSS_COLOROP, D3DTOP_MODULATE);
    IDirect3DDevice8_SetTextureStageState(dev, 0, D3DTSS_COLORARG1, D3DTA_TEXTURE);
    IDirect3DDevice8_SetTextureStageState(dev, 0, D3DTSS_COLORARG2, D3DTA_DIFFUSE);
    IDirect3DDevice8_SetTextureStageState(dev, 0, D3DTSS_MINFILTER, D3DTEXF_LINEAR);
    IDirect3DDevice8_SetTextureStageState(dev, 0, D3DTSS_MAGFILTER, D3DTEXF_LINEAR);
    IDirect3DDevice8_SetVertexShader(dev, FVF8);   /* Direct3D 8 names the vertex format through SetVertexShader */
    IDirect3DDevice8_SetStreamSource(dev, 0, vb, sizeof(struct vertex8));
    IDirect3DDevice8_SetIndices(dev, ib, 0);
    {
        dxt_mat view = dxt_view(), proj = dxt_proj();
        IDirect3DDevice8_SetTransform(dev, D3DTS_VIEW, (const D3DMATRIX *)&view);
        IDirect3DDevice8_SetTransform(dev, D3DTS_PROJECTION, (const D3DMATRIX *)&proj);
    }

    dxt_clock_start(&clock, hwnd, title);
    dxt_log(API ": drawing");
    drew = 0;
    while (dxt_pump()) {
        dxt_mat world = dxt_world(dxt_seconds(&clock));
        IDirect3DDevice8_Clear(dev, 0, NULL, D3DCLEAR_TARGET | D3DCLEAR_ZBUFFER, D3DCOLOR_XRGB(15, 18, 26), 1.0f, 0);
        if (SUCCEEDED(IDirect3DDevice8_BeginScene(dev))) {
            IDirect3DDevice8_SetTransform(dev, D3DTS_WORLD, (const D3DMATRIX *)&world);
            IDirect3DDevice8_DrawIndexedPrimitive(dev, D3DPT_TRIANGLELIST, 0, 24, 0, 12);
            IDirect3DDevice8_EndScene(dev);
            drew = 1;
        }
        hr = IDirect3DDevice8_Present(dev, NULL, NULL, NULL, NULL);
        if (FAILED(hr)) {
            if (failures++ < 3) dxt_log(API ": Present returned %#lx", (unsigned long)hr);
            Sleep(16);   /* a lost device (minimised, say) is not a reason to spin */
        } else if (drew) {
            presented++;
        }
        dxt_clock_frame(&clock);
        if (!reported && dxt_seconds(&clock) >= 2.0f) {   /* the verdict, once; the title keeps it */
            int ok = dxt_verdict(API, presented, failures, dxt_seconds(&clock), id.Description, verdict, sizeof verdict);
            reported = 1;
            checks++;
            if (!ok) check_fails++;
            if (check_fails) strcpy(verdict, "FAIL");
            dxt_log(API " (%d-bit): RESULT %s (%u of %u checks passed, %u failed, drawing %s)", DXT_BITS, check_fails ? "FAIL" : "PASS", checks - check_fails, checks,
                    check_fails, ok ? "PASS" : "FAIL");
            snprintf(clock.base, sizeof clock.base, "%s - %s", title, verdict);
            readback(dev);
        }
    }
    dxt_log(API ": the window was closed after %u frames", clock.total);

    IDirect3DTexture8_Release(tex);
    IDirect3DIndexBuffer8_Release(ib);
    IDirect3DVertexBuffer8_Release(vb);
    IDirect3DDevice8_Release(dev);
    IDirect3D8_Release(d3d);
    return 0;
}
