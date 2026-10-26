// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
//
// BCD's frame-time test (round 602): a Direct3D 11 scene that measures how evenly the engine puts frames on the screen.
// x86-64 Windows; built from the same shaders as the cube tests (cube_shaders.h), which draw everything here:
//
//   - a field of spinning cubes (1, 16, 64 or 256 of them: the load, keys 1 to 4 or a tap on the left third of the window),
//     one constant-buffer update and one draw call each;
//   - a frame-time graph along the bottom: one bar per frame for the last 200 frames, green when the frame took no more than
//     1.2 times the median, yellow up to 2 times, red above (a stutter), with lines at 8.3, 16.7 and 33.3 ms;
//   - a text panel (drawn with GDI into a texture four times a second): frames per second now, minimum / average / maximum,
//     the 1 % low, the number of stutters, the frame time, the display's refresh rate as Windows reports it and the rate the
//     frames actually come at (60 or 120 Hz or something else), VSync on or off (V, or a tap in the middle third), the load.
//
// The measurement: the time between two Present calls returning, in milliseconds, for every frame after the first second,
// until ten seconds are over; then the test logs one verdict, PASS or FAIL, with the numbers ("[bcd-test] frametime
// (64-bit): PASS 59.9 fps on average, 1 stutters in 540 frames", with the minimum, maximum, 1 % low, median and 99th
// percentile before it), and starts again with the next ten seconds (R, or a tap on the right third, restarts it by hand).
// The thresholds are in bcdstats.h (bt_ft_verdict): FAIL for fewer than 24 fps, for stutters in more than 5 % of the frames,
// and, with VSync on, for not holding 80 % of the display's rate.

#define COBJMACROS
/* dxtest.h is the cube tests' header: this test takes its matrices, cube and checker, not its window and clock */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused-function"
#include "dxtest.h"
#pragma clang diagnostic pop
#include "bcdtest.h"
#include "bcdstats.h"
#include <d3d11.h>
#include "cube_shaders.h"

#define API "Direct3D 11"
#define HIST 200            /* bars in the graph */
#define OV_W 560            /* the text panel's texture */
#define OV_H 150
#define GRAPH_X 20
#define GRAPH_BASE (DXT_H - 10)
#define MS_PX 3.0f          /* pixels a millisecond in the graph */
#define MAX_Q (HIST + 8)

typedef HRESULT (WINAPI *create_fn)(IDXGIAdapter *, D3D_DRIVER_TYPE, HMODULE, UINT, const D3D_FEATURE_LEVEL *, UINT, UINT,
                                    const DXGI_SWAP_CHAIN_DESC *, IDXGISwapChain **, ID3D11Device **, D3D_FEATURE_LEVEL *,
                                    ID3D11DeviceContext **);

static volatile int g_load_req, g_vsync_req, g_restart_req;

static LRESULT CALLBACK wndproc(HWND h, UINT m, WPARAM w, LPARAM l)
{
    switch (m) {
    case WM_KEYDOWN:
        if (w == VK_ESCAPE) PostMessageA(h, WM_CLOSE, 0, 0);
        else if (w >= '1' && w <= '4') g_load_req = (int)(w - '0');
        else if (w == 'V') g_vsync_req = 1;
        else if (w == 'R') g_restart_req = 1;
        return 0;
    case WM_LBUTTONUP: {   /* a tap: the thirds of the window are three buttons */
        int x = (short)LOWORD(l);
        if (x < DXT_W / 3) g_load_req = -1;
        else if (x < 2 * DXT_W / 3) g_vsync_req = 1;
        else g_restart_req = 1;
        return 0;
    }
    case WM_CLOSE:
        DestroyWindow(h);
        return 0;
    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    case WM_ERASEBKGND:
        return 1;
    }
    return DefWindowProcA(h, m, w, l);
}

static HWND make_window(const char *title)
{
    WNDCLASSA wc;
    RECT r = { 0, 0, DXT_W, DXT_H };
    const DWORD style = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX;
    HWND hwnd;

    memset(&wc, 0, sizeof wc);
    wc.lpfnWndProc = wndproc;
    wc.hInstance = GetModuleHandleA(NULL);
    wc.hCursor = LoadCursorA(NULL, (LPCSTR)IDC_ARROW);
    wc.lpszClassName = "BCDFrameTimeTest";
    if (!RegisterClassA(&wc)) return NULL;
    AdjustWindowRect(&r, style, FALSE);
    hwnd = CreateWindowExA(0, wc.lpszClassName, title, style, CW_USEDEFAULT, CW_USEDEFAULT, r.right - r.left, r.bottom - r.top, NULL, NULL, wc.hInstance, NULL);
    if (hwnd) { ShowWindow(hwnd, SW_SHOW); UpdateWindow(hwnd); }
    return hwnd;
}

static int pump(void)
{
    MSG msg;
    while (PeekMessageA(&msg, NULL, 0, 0, PM_REMOVE)) {
        if (msg.message == WM_QUIT) return 0;
        TranslateMessage(&msg);
        DispatchMessageA(&msg);
    }
    return 1;
}

/* A rectangle in window pixels as four vertices in normalised device coordinates, the white texel of the 1x1 texture. */
static void quad(dxt_vertex *v, float x0, float y0, float x1, float y1, unsigned char r, unsigned char g, unsigned char b, unsigned char a)
{
    const float xs[4] = { x0, x0, x1, x1 }, ys[4] = { y1, y0, y0, y1 };
    const float us[4] = { 0, 0, 1, 1 }, vs[4] = { 1, 0, 0, 1 };
    int k;
    for (k = 0; k < 4; k++) {
        v[k].x = xs[k] / DXT_W * 2.0f - 1.0f;
        v[k].y = 1.0f - ys[k] / DXT_H * 2.0f;
        v[k].z = 0.0f;
        v[k].u = us[k]; v[k].v = vs[k];
        v[k].r = r; v[k].g = g; v[k].b = b; v[k].a = a;
    }
}

#define CHECK(call, what) do { HRESULT hr_ = (call); if (FAILED(hr_)) { \
        char m_[200]; snprintf(m_, sizeof m_, "%s failed (%#lx)", what, (unsigned long)hr_); \
        bt_check(0, what, "%s", bt_hr(hr_)); bt_result(); dxt_fail(API, m_); return 1; } } while (0)

int WINAPI WinMain(HINSTANCE inst, HINSTANCE prev, LPSTR cmd, int show)
{
    static const D3D_FEATURE_LEVEL levels[] = { D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_10_1, D3D_FEATURE_LEVEL_10_0 };
    static const D3D11_INPUT_ELEMENT_DESC layout[] = {
        { "POSITION", 0, DXGI_FORMAT_R32G32B32_FLOAT, 0, 0, D3D11_INPUT_PER_VERTEX_DATA, 0 },
        { "TEXCOORD", 0, DXGI_FORMAT_R32G32_FLOAT, 0, 12, D3D11_INPUT_PER_VERTEX_DATA, 0 },
        { "COLOR", 0, DXGI_FORMAT_R8G8B8A8_UNORM, 0, 20, D3D11_INPUT_PER_VERTEX_DATA, 0 },
    };
    static const int loads[5] = { 0, 1, 16, 64, 256 };
    HMODULE dll;
    create_fn create;
    HWND hwnd;
    DXGI_SWAP_CHAIN_DESC sd;
    IDXGISwapChain *swap = NULL;
    ID3D11Device *dev = NULL;
    ID3D11DeviceContext *ctx = NULL;
    D3D_FEATURE_LEVEL level = 0;
    ID3D11Texture2D *back = NULL, *depth = NULL, *checker = NULL, *white = NULL, *overlay = NULL;
    ID3D11RenderTargetView *rtv = NULL;
    ID3D11DepthStencilView *dsv = NULL;
    ID3D11ShaderResourceView *srv_checker = NULL, *srv_white = NULL, *srv_overlay = NULL;
    ID3D11SamplerState *sampler = NULL;
    ID3D11RasterizerState *raster = NULL;
    ID3D11DepthStencilState *depth_on = NULL, *depth_off = NULL;
    ID3D11BlendState *blend_alpha = NULL;
    ID3D11VertexShader *vs = NULL;
    ID3D11PixelShader *ps = NULL;
    ID3D11InputLayout *il = NULL;
    ID3D11Buffer *vb_cube = NULL, *ib_cube = NULL, *cb = NULL, *cb_ident = NULL, *vb_graph = NULL, *ib_quads = NULL, *vb_overlay = NULL;
    dxt_vertex cube_v[24];
    unsigned short cube_i[36];
    unsigned texels[DXT_TEX * DXT_TEX], white_texel = 0xFFFFFFFFu;
    D3D11_BUFFER_DESC bd;
    D3D11_SUBRESOURCE_DATA init;
    D3D11_TEXTURE2D_DESC td;
    D3D11_SAMPLER_DESC smd;
    D3D11_RASTERIZER_DESC rd;
    D3D11_DEPTH_STENCIL_DESC dd;
    D3D11_BLEND_DESC blend;
    D3D11_VIEWPORT vp;
    UINT stride = sizeof(dxt_vertex), offset = 0;
    DXGI_ADAPTER_DESC ad;
    IDXGIDevice *dxgidev = NULL;
    IDXGIAdapter *adapter = NULL;
    char adapter_name[128] = "?", title[160];
    static double ft[8192];         /* frame times since the last restart, after the first second */
    static double ring[HIST];       /* the last HIST frame times, for the graph */
    int nft = 0, ring_at = 0, ring_n = 0, vsync = 1, load_idx = 2, verdicts = 0;
    double t_start, t_prev, t_text = 0, t_run0, refresh_hz = 0;
    unsigned frames_total = 0, present_fail = 0;
    /* the text panel */
    HDC memdc = NULL;
    HBITMAP dib = NULL;
    HFONT font = NULL;
    void *dib_bits = NULL;
    BITMAPINFO bmi;
    char verdict_line[160] = "measuring (first second ignored, verdict at 10 s)", rate_txt[16];
    int progress_logged = 0;
    bt_ft_stats_t live;
    unsigned short quad_idx[MAX_Q * 6];
    int i;

    (void)inst; (void)prev; (void)cmd; (void)show;
    bt_init("frametime");
    snprintf(title, sizeof title, "BCD frame-time test (%d-bit)", BT_BITS);
    dll = LoadLibraryA("d3d11.dll");
    create = dll ? (create_fn)GetProcAddress(dll, "D3D11CreateDeviceAndSwapChain") : NULL;
    if (!create) { bt_check(0, "d3d11.dll", "not available"); bt_result(); dxt_fail(API, "d3d11.dll (D3D11CreateDeviceAndSwapChain) is not available"); return 1; }
    hwnd = make_window(title);
    if (!hwnd) { bt_check(0, "window", "could not be created"); bt_result(); dxt_fail(API, "the window could not be created"); return 1; }

    memset(&sd, 0, sizeof sd);
    sd.BufferDesc.Width = DXT_W;
    sd.BufferDesc.Height = DXT_H;
    sd.BufferDesc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    sd.SampleDesc.Count = 1;
    sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sd.BufferCount = 2;
    sd.OutputWindow = hwnd;
    sd.Windowed = TRUE;
    sd.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;
    CHECK(create(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, levels, 3, D3D11_SDK_VERSION, &sd, &swap, &dev, &level, &ctx), "D3D11CreateDeviceAndSwapChain");
    if (SUCCEEDED(ID3D11Device_QueryInterface(dev, &IID_IDXGIDevice, (void **)&dxgidev)) &&
        SUCCEEDED(IDXGIDevice_GetAdapter(dxgidev, &adapter)) && SUCCEEDED(IDXGIAdapter_GetDesc(adapter, &ad)))
        bt_ascii(adapter_name, sizeof adapter_name, ad.Description);
    if (adapter) IDXGIAdapter_Release(adapter);
    if (dxgidev) IDXGIDevice_Release(dxgidev);
    {
        DEVMODEA dm;
        memset(&dm, 0, sizeof dm);
        dm.dmSize = sizeof dm;
        if (EnumDisplaySettingsA(NULL, ENUM_CURRENT_SETTINGS, &dm)) refresh_hz = dm.dmDisplayFrequency;
        bt_check(1, "Direct3D 11 device", "feature level %#x, adapter \"%s\", display %lux%lu at %.0f Hz", (unsigned)level, adapter_name, (unsigned long)dm.dmPelsWidth,
                 (unsigned long)dm.dmPelsHeight, refresh_hz);
    }

    CHECK(IDXGISwapChain_GetBuffer(swap, 0, &IID_ID3D11Texture2D, (void **)&back), "GetBuffer");
    CHECK(ID3D11Device_CreateRenderTargetView(dev, (ID3D11Resource *)back, NULL, &rtv), "CreateRenderTargetView");
    memset(&td, 0, sizeof td);
    td.Width = DXT_W; td.Height = DXT_H; td.MipLevels = 1; td.ArraySize = 1;
    td.Format = DXGI_FORMAT_D24_UNORM_S8_UINT;
    td.SampleDesc.Count = 1;
    td.Usage = D3D11_USAGE_DEFAULT;
    td.BindFlags = D3D11_BIND_DEPTH_STENCIL;
    CHECK(ID3D11Device_CreateTexture2D(dev, &td, NULL, &depth), "CreateTexture2D (depth)");
    CHECK(ID3D11Device_CreateDepthStencilView(dev, (ID3D11Resource *)depth, NULL, &dsv), "CreateDepthStencilView");
    CHECK(ID3D11Device_CreateVertexShader(dev, cube_vs_5_0, sizeof cube_vs_5_0, NULL, &vs), "CreateVertexShader");
    CHECK(ID3D11Device_CreatePixelShader(dev, cube_ps_5_0, sizeof cube_ps_5_0, NULL, &ps), "CreatePixelShader");
    CHECK(ID3D11Device_CreateInputLayout(dev, layout, 3, cube_vs_5_0, sizeof cube_vs_5_0, &il), "CreateInputLayout");

    /* buffers: the cube, the constants (one per cube, rewritten), an identity matrix for the 2D parts, the graph's quads */
    dxt_cube(cube_v, cube_i);
    memset(&bd, 0, sizeof bd);
    memset(&init, 0, sizeof init);
    bd.ByteWidth = sizeof cube_v; bd.Usage = D3D11_USAGE_IMMUTABLE; bd.BindFlags = D3D11_BIND_VERTEX_BUFFER;
    init.pSysMem = cube_v;
    CHECK(ID3D11Device_CreateBuffer(dev, &bd, &init, &vb_cube), "CreateBuffer (cube vertices)");
    bd.ByteWidth = sizeof cube_i; bd.BindFlags = D3D11_BIND_INDEX_BUFFER;
    init.pSysMem = cube_i;
    CHECK(ID3D11Device_CreateBuffer(dev, &bd, &init, &ib_cube), "CreateBuffer (cube indices)");
    bd.ByteWidth = sizeof(dxt_mat); bd.Usage = D3D11_USAGE_DYNAMIC; bd.BindFlags = D3D11_BIND_CONSTANT_BUFFER; bd.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
    CHECK(ID3D11Device_CreateBuffer(dev, &bd, NULL, &cb), "CreateBuffer (constants)");
    {
        dxt_mat ident = dxt_identity();
        memset(&bd, 0, sizeof bd);
        bd.ByteWidth = sizeof ident; bd.Usage = D3D11_USAGE_IMMUTABLE; bd.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
        memset(&init, 0, sizeof init);
        init.pSysMem = &ident;
        CHECK(ID3D11Device_CreateBuffer(dev, &bd, &init, &cb_ident), "CreateBuffer (identity)");
    }
    memset(&bd, 0, sizeof bd);
    bd.ByteWidth = MAX_Q * 4 * sizeof(dxt_vertex); bd.Usage = D3D11_USAGE_DYNAMIC; bd.BindFlags = D3D11_BIND_VERTEX_BUFFER; bd.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
    CHECK(ID3D11Device_CreateBuffer(dev, &bd, NULL, &vb_graph), "CreateBuffer (graph)");
    for (i = 0; i < MAX_Q; i++) {
        quad_idx[i * 6 + 0] = (unsigned short)(i * 4 + 0); quad_idx[i * 6 + 1] = (unsigned short)(i * 4 + 1); quad_idx[i * 6 + 2] = (unsigned short)(i * 4 + 2);
        quad_idx[i * 6 + 3] = (unsigned short)(i * 4 + 0); quad_idx[i * 6 + 4] = (unsigned short)(i * 4 + 2); quad_idx[i * 6 + 5] = (unsigned short)(i * 4 + 3);
    }
    memset(&bd, 0, sizeof bd);
    bd.ByteWidth = sizeof quad_idx; bd.Usage = D3D11_USAGE_IMMUTABLE; bd.BindFlags = D3D11_BIND_INDEX_BUFFER;
    memset(&init, 0, sizeof init);
    init.pSysMem = quad_idx;
    CHECK(ID3D11Device_CreateBuffer(dev, &bd, &init, &ib_quads), "CreateBuffer (quad indices)");
    {
        dxt_vertex ov[4];
        quad(ov, 6, 6, 6 + OV_W, 6 + OV_H, 255, 255, 255, 255);
        memset(&bd, 0, sizeof bd);
        bd.ByteWidth = sizeof ov; bd.Usage = D3D11_USAGE_IMMUTABLE; bd.BindFlags = D3D11_BIND_VERTEX_BUFFER;
        memset(&init, 0, sizeof init);
        init.pSysMem = ov;
        CHECK(ID3D11Device_CreateBuffer(dev, &bd, &init, &vb_overlay), "CreateBuffer (overlay)");
    }

    /* textures: the cubes' checker, one white texel for the graph, and the text panel (dynamic, rewritten four times a second) */
    dxt_checker(texels);
    memset(&td, 0, sizeof td);
    td.Width = DXT_TEX; td.Height = DXT_TEX; td.MipLevels = 1; td.ArraySize = 1;
    td.Format = DXGI_FORMAT_R8G8B8A8_UNORM; td.SampleDesc.Count = 1; td.Usage = D3D11_USAGE_IMMUTABLE; td.BindFlags = D3D11_BIND_SHADER_RESOURCE;
    memset(&init, 0, sizeof init);
    init.pSysMem = texels; init.SysMemPitch = DXT_TEX * 4;
    CHECK(ID3D11Device_CreateTexture2D(dev, &td, &init, &checker), "CreateTexture2D (checker)");
    CHECK(ID3D11Device_CreateShaderResourceView(dev, (ID3D11Resource *)checker, NULL, &srv_checker), "CreateShaderResourceView (checker)");
    td.Width = 1; td.Height = 1;
    init.pSysMem = &white_texel; init.SysMemPitch = 4;
    CHECK(ID3D11Device_CreateTexture2D(dev, &td, &init, &white), "CreateTexture2D (white)");
    CHECK(ID3D11Device_CreateShaderResourceView(dev, (ID3D11Resource *)white, NULL, &srv_white), "CreateShaderResourceView (white)");
    td.Width = OV_W; td.Height = OV_H; td.Usage = D3D11_USAGE_DYNAMIC; td.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
    CHECK(ID3D11Device_CreateTexture2D(dev, &td, NULL, &overlay), "CreateTexture2D (text panel)");
    CHECK(ID3D11Device_CreateShaderResourceView(dev, (ID3D11Resource *)overlay, NULL, &srv_overlay), "CreateShaderResourceView (text panel)");

    memset(&smd, 0, sizeof smd);
    smd.Filter = D3D11_FILTER_MIN_MAG_MIP_LINEAR;
    smd.AddressU = smd.AddressV = smd.AddressW = D3D11_TEXTURE_ADDRESS_WRAP;
    smd.MaxAnisotropy = 1; smd.ComparisonFunc = D3D11_COMPARISON_NEVER; smd.MaxLOD = D3D11_FLOAT32_MAX;
    CHECK(ID3D11Device_CreateSamplerState(dev, &smd, &sampler), "CreateSamplerState");
    memset(&rd, 0, sizeof rd);
    rd.FillMode = D3D11_FILL_SOLID; rd.CullMode = D3D11_CULL_NONE; rd.DepthClipEnable = TRUE;
    CHECK(ID3D11Device_CreateRasterizerState(dev, &rd, &raster), "CreateRasterizerState");
    memset(&dd, 0, sizeof dd);
    dd.DepthEnable = TRUE; dd.DepthWriteMask = D3D11_DEPTH_WRITE_MASK_ALL; dd.DepthFunc = D3D11_COMPARISON_LESS;
    dd.StencilReadMask = dd.StencilWriteMask = 0xFF;
    dd.FrontFace.StencilFailOp = dd.FrontFace.StencilDepthFailOp = dd.FrontFace.StencilPassOp = D3D11_STENCIL_OP_KEEP;
    dd.FrontFace.StencilFunc = D3D11_COMPARISON_ALWAYS;
    dd.BackFace = dd.FrontFace;
    CHECK(ID3D11Device_CreateDepthStencilState(dev, &dd, &depth_on), "CreateDepthStencilState");
    dd.DepthEnable = FALSE;
    CHECK(ID3D11Device_CreateDepthStencilState(dev, &dd, &depth_off), "CreateDepthStencilState (off)");
    memset(&blend, 0, sizeof blend);
    blend.RenderTarget[0].BlendEnable = TRUE;
    blend.RenderTarget[0].SrcBlend = D3D11_BLEND_SRC_ALPHA;
    blend.RenderTarget[0].DestBlend = D3D11_BLEND_INV_SRC_ALPHA;
    blend.RenderTarget[0].BlendOp = D3D11_BLEND_OP_ADD;
    blend.RenderTarget[0].SrcBlendAlpha = D3D11_BLEND_ONE;
    blend.RenderTarget[0].DestBlendAlpha = D3D11_BLEND_ZERO;
    blend.RenderTarget[0].BlendOpAlpha = D3D11_BLEND_OP_ADD;
    blend.RenderTarget[0].RenderTargetWriteMask = D3D11_COLOR_WRITE_ENABLE_ALL;
    CHECK(ID3D11Device_CreateBlendState(dev, &blend, &blend_alpha), "CreateBlendState");
    memset(&vp, 0, sizeof vp);
    vp.Width = DXT_W; vp.Height = DXT_H; vp.MaxDepth = 1.0f;

    /* GDI draws the text panel into a DIB; the pixels go to the texture with the text's brightness as alpha */
    memset(&bmi, 0, sizeof bmi);
    bmi.bmiHeader.biSize = sizeof bmi.bmiHeader;
    bmi.bmiHeader.biWidth = OV_W;
    bmi.bmiHeader.biHeight = -OV_H;
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;
    bmi.bmiHeader.biCompression = BI_RGB;
    memdc = CreateCompatibleDC(NULL);
    dib = CreateDIBSection(memdc, &bmi, DIB_RGB_COLORS, &dib_bits, NULL, 0);
    font = CreateFontA(-15, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, ANSI_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, DEFAULT_QUALITY, FIXED_PITCH | FF_MODERN, "Courier New");
    if (dib) SelectObject(memdc, dib);
    SelectObject(memdc, font);
    bt_check(dib != NULL, "text panel (GDI into a texture)", "DIB section %s", dib ? "made" : "could not be made; the numbers are in the log only");

    t_start = t_run0 = t_prev = bt_now();
    memset(&live, 0, sizeof live);
    bt_log("drawing; keys 1-4 load, V vsync, R restart; a tap: left third load, middle vsync, right restart");
    while (pump()) {
        static const float clear[4] = { 0.05f, 0.06f, 0.09f, 1.0f };
        double now, dt_ms, secs;
        int cubes, cols, c;
        D3D11_MAPPED_SUBRESOURCE mapped;
        dxt_vertex gv[MAX_Q * 4];
        int nq = 0;
        float med;
        HRESULT hr;

        /* requests from the keys and taps */
        if (g_load_req) {
            load_idx = g_load_req > 0 ? g_load_req : (load_idx % 4) + 1;
            g_load_req = 0;
            g_restart_req = 1;
        }
        if (g_vsync_req) { vsync = !vsync; g_vsync_req = 0; g_restart_req = 1; }
        if (g_restart_req) {
            g_restart_req = 0;
            nft = 0; ring_n = 0; ring_at = 0;
            t_run0 = bt_now();
            snprintf(verdict_line, sizeof verdict_line, "measuring (first second ignored, verdict at 10 s)");
            progress_logged = 0;
            bt_log("restart: %d cubes, vsync %s", loads[load_idx], vsync ? "on" : "off");
        }
        cubes = loads[load_idx];
        secs = bt_now() - t_start;

        /* the scene */
        ID3D11DeviceContext_OMSetRenderTargets(ctx, 1, &rtv, dsv);
        ID3D11DeviceContext_RSSetViewports(ctx, 1, &vp);
        ID3D11DeviceContext_RSSetState(ctx, raster);
        ID3D11DeviceContext_ClearRenderTargetView(ctx, rtv, clear);
        ID3D11DeviceContext_ClearDepthStencilView(ctx, dsv, D3D11_CLEAR_DEPTH | D3D11_CLEAR_STENCIL, 1.0f, 0);
        ID3D11DeviceContext_OMSetDepthStencilState(ctx, depth_on, 0);
        ID3D11DeviceContext_OMSetBlendState(ctx, NULL, NULL, 0xFFFFFFFFu);
        ID3D11DeviceContext_IASetInputLayout(ctx, il);
        ID3D11DeviceContext_IASetPrimitiveTopology(ctx, D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
        ID3D11DeviceContext_IASetVertexBuffers(ctx, 0, 1, &vb_cube, &stride, &offset);
        ID3D11DeviceContext_IASetIndexBuffer(ctx, ib_cube, DXGI_FORMAT_R16_UINT, 0);
        ID3D11DeviceContext_VSSetShader(ctx, vs, NULL, 0);
        ID3D11DeviceContext_VSSetConstantBuffers(ctx, 0, 1, &cb);
        ID3D11DeviceContext_PSSetShader(ctx, ps, NULL, 0);
        ID3D11DeviceContext_PSSetShaderResources(ctx, 0, 1, &srv_checker);
        ID3D11DeviceContext_PSSetSamplers(ctx, 0, 1, &sampler);
        cols = 1;
        while (cols * cols < cubes) cols++;
        for (c = 0; c < cubes; c++) {
            float s = 1.5f / (float)cols, gx = (float)(c % cols) - (cols - 1) * 0.5f, gy = (float)(c / cols) - (cols - 1) * 0.5f;
            float spacing = cols > 1 ? 2.2f / (float)cols * 1.9f : 0.0f;
            dxt_mat scale = dxt_identity(), world, mvp;
            scale.m[0] = scale.m[5] = scale.m[10] = s;
            world = dxt_mul(dxt_mul(scale, dxt_world((float)secs + (float)c * 0.37f)), dxt_translate(gx * spacing, gy * spacing * 0.75f - 0.3f, 0.0f));
            mvp = dxt_mul(dxt_mul(world, dxt_view()), dxt_proj());
            if (SUCCEEDED(ID3D11DeviceContext_Map(ctx, (ID3D11Resource *)cb, 0, D3D11_MAP_WRITE_DISCARD, 0, &mapped))) {
                memcpy(mapped.pData, &mvp, sizeof mvp);
                ID3D11DeviceContext_Unmap(ctx, (ID3D11Resource *)cb, 0);
            }
            ID3D11DeviceContext_DrawIndexed(ctx, 36, 0, 0);
        }

        /* the graph: a bar a frame, and the lines at 8.3, 16.7 and 33.3 ms */
        med = live.median_ms > 0 ? (float)live.median_ms : 16.7f;
        {
            static const float marks[3] = { 8.333f, 16.667f, 33.333f };
            static const unsigned char mark_a[3] = { 90, 160, 90 };
            for (c = 0; c < 3; c++) {
                float y = GRAPH_BASE - marks[c] * MS_PX;
                quad(gv + nq * 4, GRAPH_X - 6, y - 0.5f, GRAPH_X + HIST * 3 + 6, y + 0.5f, 255, 255, 255, mark_a[c]);
                nq++;
            }
        }
        for (c = 0; c < ring_n && nq < MAX_Q; c++) {
            double v = ring[(ring_at - ring_n + c + HIST * 2) % HIST];
            float hpx = (float)v * MS_PX, x = (float)(GRAPH_X + c * 3);
            unsigned char r = 70, g = 210, b = 90;
            if (hpx > 150.0f) hpx = 150.0f;
            if (v > 2.0 * med + 2.0) { r = 240; g = 70; b = 70; }
            else if (v > 1.2 * med + 1.0) { r = 240; g = 200; b = 60; }
            quad(gv + nq * 4, x, GRAPH_BASE - hpx, x + 2.0f, (float)GRAPH_BASE, r, g, b, 255);
            nq++;
        }
        if (SUCCEEDED(ID3D11DeviceContext_Map(ctx, (ID3D11Resource *)vb_graph, 0, D3D11_MAP_WRITE_DISCARD, 0, &mapped))) {
            memcpy(mapped.pData, gv, (size_t)nq * 4 * sizeof(dxt_vertex));
            ID3D11DeviceContext_Unmap(ctx, (ID3D11Resource *)vb_graph, 0);
        }
        {
            ID3D11Buffer *ident = cb_ident;
            ID3D11DeviceContext_OMSetDepthStencilState(ctx, depth_off, 0);
            ID3D11DeviceContext_OMSetBlendState(ctx, blend_alpha, NULL, 0xFFFFFFFFu);
            ID3D11DeviceContext_VSSetConstantBuffers(ctx, 0, 1, &ident);
            ID3D11DeviceContext_PSSetShaderResources(ctx, 0, 1, &srv_white);
            ID3D11DeviceContext_IASetVertexBuffers(ctx, 0, 1, &vb_graph, &stride, &offset);
            ID3D11DeviceContext_IASetIndexBuffer(ctx, ib_quads, DXGI_FORMAT_R16_UINT, 0);
            ID3D11DeviceContext_DrawIndexed(ctx, (UINT)nq * 6, 0, 0);
            /* the text panel on top */
            ID3D11DeviceContext_PSSetShaderResources(ctx, 0, 1, &srv_overlay);
            ID3D11DeviceContext_IASetVertexBuffers(ctx, 0, 1, &vb_overlay, &stride, &offset);
            ID3D11DeviceContext_DrawIndexed(ctx, 6, 0, 0);
        }

        hr = IDXGISwapChain_Present(swap, vsync ? 1 : 0, 0);
        if (FAILED(hr)) {
            if (present_fail++ < 3) bt_log("Present returned %s", bt_hr(hr));
            Sleep(16);
        }
        now = bt_now();
        dt_ms = (now - t_prev) * 1000.0;
        t_prev = now;
        frames_total++;
        if (now - t_run0 > 1.0 && nft < 8192) ft[nft++] = dt_ms;   /* the first second of a run is warm-up */
        if (now - t_run0 > 0.5) { ring[ring_at] = dt_ms; ring_at = (ring_at + 1) % HIST; if (ring_n < HIST) ring_n++; }

        /* live numbers and the text panel, four times a second */
        if (now - t_text >= 0.25) {
            double recent[HIST];
            int n = ring_n, k;
            t_text = now;
            for (k = 0; k < n; k++) recent[k] = ring[(ring_at - n + k + HIST * 2) % HIST];
            if (n > 10) bt_ft_stats(recent, n, &live);
            if (dib_bits) {
                char line[96];
                int refresh_class = live.median_ms > 0 ? bt_refresh_class(live.median_ms) : 0;
                RECT all = { 0, 0, OV_W, OV_H };
                unsigned *px = (unsigned *)dib_bits;
                int y;
                HBRUSH black = CreateSolidBrush(RGB(0, 0, 0));
                FillRect(memdc, &all, black);
                DeleteObject(black);
                SetBkMode(memdc, TRANSPARENT);
                SetTextColor(memdc, RGB(255, 255, 255));
#define TXT(row, ...) do { int n_ = snprintf(line, sizeof line, __VA_ARGS__); if (n_ > (int)sizeof line - 1) n_ = (int)sizeof line - 1; TextOutA(memdc, 6, 4 + (row) * 18, line, n_); } while (0)
                TXT(0, "%.1f fps now  (min %.1f  avg %.1f  max %.1f)", live.fps_avg, live.fps_min, live.fps_avg, live.fps_max);
                TXT(1, "frame %.2f ms  median %.2f  99th %.2f", live.avg_ms, live.median_ms, live.p99_ms);
                TXT(2, "1%% low %.1f fps   stutters %d of the last %d", live.fps_1pct_low, live.stutters, live.n);
                if (refresh_class) snprintf(rate_txt, sizeof rate_txt, "%d", refresh_class);
                else snprintf(rate_txt, sizeof rate_txt, "?");
                TXT(3, "display %.0f Hz, frames come at %s Hz", refresh_hz, rate_txt);
                TXT(4, "VSync %s (V)   load %d cubes (1-4)   R restart", vsync ? "ON" : "OFF", cubes);
                TXT(5, "%.60s", verdict_line);
                TXT(6, "%dx%d, feature level %x, %.20s", DXT_W, DXT_H, (unsigned)level, adapter_name);
#undef TXT
                for (y = 0; y < OV_W * OV_H; y++) {   /* alpha = the text's brightness, with a dark glass behind it */
                    unsigned p = px[y], br = (p >> 16) & 255;
                    if (((p >> 8) & 255) > br) br = (p >> 8) & 255;
                    if ((p & 255) > br) br = p & 255;
                    px[y] = (p & 0x00FFFFFFu) | ((br > 120 ? 255u : 130u + br) << 24);
                }
                if (SUCCEEDED(ID3D11DeviceContext_Map(ctx, (ID3D11Resource *)overlay, 0, D3D11_MAP_WRITE_DISCARD, 0, &mapped))) {
                    int row;
                    for (row = 0; row < OV_H; row++) {
                        unsigned *dst = (unsigned *)((BYTE *)mapped.pData + (size_t)row * mapped.RowPitch), *src = px + (size_t)row * OV_W;
                        int col;
                        for (col = 0; col < OV_W; col++) {   /* GDI's BGRA to the texture's RGBA */
                            unsigned p = src[col];
                            dst[col] = (p & 0xFF000000u) | ((p & 0xFF) << 16) | (p & 0xFF00) | ((p >> 16) & 0xFF);
                        }
                    }
                    ID3D11DeviceContext_Unmap(ctx, (ID3D11Resource *)overlay, 0);
                }
            }
        }
        if (now - t_run0 > 6.0 && !progress_logged && nft > 30) {   /* a progress line for the log */
            bt_ft_stats_t part;
            bt_ft_stats(ft, nft, &part);
            bt_log("progress: %.1f fps on average after %d frames", part.fps_avg, part.n);
            progress_logged = 1;
        }
        if (now - t_run0 >= 11.0 && nft > 0) {   /* ten seconds measured (the first one is warm-up): the verdict */
            bt_ft_stats_t all;
            char why[200];
            int ok, refresh_class;
            bt_ft_stats(ft, nft, &all);
            refresh_class = bt_refresh_class(all.median_ms);
            ok = bt_ft_verdict(&all, refresh_hz, vsync, why, sizeof why);
            bt_log("fps min %.1f, avg %.1f, max %.1f; 1%% low %.1f; frame time median %.2f ms, 99th percentile %.2f ms, max %.2f ms; %d stutters in %d frames; "
                   "display %.0f Hz, frames come at %d Hz; VSync %s; %d cubes",
                   all.fps_min, all.fps_avg, all.fps_max, all.fps_1pct_low, all.median_ms, all.p99_ms, all.max_ms, all.stutters, all.n, refresh_hz, refresh_class,
                   vsync ? "on" : "off", cubes);
            bt_check(ok, "frame times", "%s", why);
            bt_headline("%.1f fps average (min %.1f, max %.1f, 1%% low %.1f), %d stutters in %d frames, display %.0f Hz, frames come at %d Hz, VSync %s, %d cubes",
                        all.fps_avg, all.fps_min, all.fps_max, all.fps_1pct_low, all.stutters, all.n, refresh_hz, refresh_class, vsync ? "on" : "off", cubes);
            bt_result();
            snprintf(verdict_line, sizeof verdict_line, "%s: %s", ok ? "PASS" : "FAIL", why);
            snprintf(title, sizeof title, "BCD frame-time test (%d-bit) - %s %.1f fps", BT_BITS, ok ? "PASS" : "FAIL", all.fps_avg);
            SetWindowTextA(hwnd, title);
            verdicts++;
            bt_g.checks = bt_g.fails = 0;   /* the next ten seconds are a verdict of their own */
            nft = 0;
            t_run0 = now - 1.0;             /* no second warm-up: the engine is already running */
            progress_logged = 0;
        }
        if (frames_total % 120 == 0 && verdicts == 0) {
            snprintf(title, sizeof title, "BCD frame-time test (%d-bit) - %.0f fps", BT_BITS, live.fps_avg);
            SetWindowTextA(hwnd, title);
        }
    }
    bt_log("the window was closed after %u frames", frames_total);
    if (verdicts == 0) { bt_check(frames_total >= 60, "ran", "%u frames in %.1f s, closed before the ten-second verdict", frames_total, bt_now() - t_start);
        bt_headline("closed after %u frames, before the ten-second verdict", frames_total); bt_result(); }

    ID3D11DeviceContext_ClearState(ctx);
    if (font) DeleteObject(font);
    if (dib) DeleteObject(dib);
    if (memdc) DeleteDC(memdc);
    ID3D11BlendState_Release(blend_alpha);
    ID3D11DepthStencilState_Release(depth_off);
    ID3D11DepthStencilState_Release(depth_on);
    ID3D11RasterizerState_Release(raster);
    ID3D11SamplerState_Release(sampler);
    ID3D11ShaderResourceView_Release(srv_overlay);
    ID3D11ShaderResourceView_Release(srv_white);
    ID3D11ShaderResourceView_Release(srv_checker);
    ID3D11Texture2D_Release(overlay);
    ID3D11Texture2D_Release(white);
    ID3D11Texture2D_Release(checker);
    ID3D11Buffer_Release(vb_overlay);
    ID3D11Buffer_Release(ib_quads);
    ID3D11Buffer_Release(vb_graph);
    ID3D11Buffer_Release(cb_ident);
    ID3D11Buffer_Release(cb);
    ID3D11Buffer_Release(ib_cube);
    ID3D11Buffer_Release(vb_cube);
    ID3D11InputLayout_Release(il);
    ID3D11PixelShader_Release(ps);
    ID3D11VertexShader_Release(vs);
    ID3D11DepthStencilView_Release(dsv);
    ID3D11Texture2D_Release(depth);
    ID3D11RenderTargetView_Release(rtv);
    ID3D11Texture2D_Release(back);
    ID3D11DeviceContext_Release(ctx);
    IDXGISwapChain_Release(swap);
    ID3D11Device_Release(dev);
    return 0;
}
