/*
 * d3d9log.c — D3D9 transparent proxy that logs shader constants to CSV
 *
 * Build (32-bit, cross-compiled on Mac):
 *   i686-w64-mingw32-gcc -shared -o d3d9.dll d3d9log.c \
 *       -ld3d9 -I$(mingw-i686 include path) -Wl,--kill-at
 *
 * Deploy: place d3d9.dll alongside elevated_1920_1080.exe
 * Output: %TEMP%\elevated_q.csv  (or same dir as exe)
 *
 * CSV columns:
 *   frame, q0x,q0y,q0z,q0w, q1x,...q1w, q2x,...q2w, q3x,...q3w, q4x,...q4w
 *
 * q[2].w = terScale (what we're hunting)
 */

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d9.h>
#include <stdio.h>
#include <string.h>

/* ── Real d3d9.dll ─────────────────────────────────────────────────────── */
static HMODULE g_real = NULL;
static IDirect3D9 *(WINAPI *real_Direct3DCreate9)(UINT) = NULL;

/* ── Log file ──────────────────────────────────────────────────────────── */
static FILE   *g_log  = NULL;
static DWORD   g_frame = 0;

/* ── Captured q[0..4] (5 float4s) ─────────────────────────────────────── */
static float   g_q[5][4];   /* g_q[reg][xyzw] */

/*
 * We only hook Present (17) and SetPixelShaderConstantF (107).
 * Everything else forwards directly to the real device.
 * We build our own vtable by copying all slots, then replacing two.
 */
struct ProxyDevice {
    IDirect3DDevice9Vtbl *lpVtbl;  /* must be first */
    IDirect3DDevice9     *real;
};
typedef struct ProxyDevice ProxyDevice;

static IDirect3DDevice9Vtbl g_vt;
static ProxyDevice g_dev;

/* SetPixelShaderConstantF — vtable slot 107 */
static HRESULT WINAPI hook_SetPSConstF(IDirect3DDevice9 *self,
                                        UINT startReg,
                                        const float *data,
                                        UINT count)
{
    ProxyDevice *p = (ProxyDevice *)self;
    for (UINT i = 0; i < count && (startReg + i) < 5; i++)
        memcpy(g_q[startReg + i], data + i*4, sizeof(float)*4);
    return p->real->lpVtbl->SetPixelShaderConstantF(p->real, startReg, data, count);
}

/* Present — vtable slot 17 */
static HRESULT WINAPI hook_Present(IDirect3DDevice9 *self,
                                    const RECT *src, const RECT *dst,
                                    HWND hwnd, const RGNDATA *dirty)
{
    ProxyDevice *p = (ProxyDevice *)self;
    if (g_log) {
        fprintf(g_log, "%lu", g_frame++);
        for (int r = 0; r < 5; r++)
            fprintf(g_log, ",%.6f,%.6f,%.6f,%.6f",
                    g_q[r][0], g_q[r][1], g_q[r][2], g_q[r][3]);
        fprintf(g_log, "\n");
        if ((g_frame % 60) == 0) fflush(g_log);
    }
    return p->real->lpVtbl->Present(p->real, src, dst, hwnd, dirty);
}

/* ── IDirect3D9 proxy ────────────────────────────────────────────────── */
typedef struct {
    IDirect3D9Vtbl *lpVtbl;
    IDirect3D9     *real;
} ProxyD3D;

static ProxyD3D g_d3d;
static IDirect3D9Vtbl g_d3d_vt;

static HRESULT WINAPI hook_CreateDevice(IDirect3D9 *self,
    UINT adapter, D3DDEVTYPE type, HWND focus,
    DWORD flags, D3DPRESENT_PARAMETERS *pp, IDirect3DDevice9 **out)
{
    ProxyD3D *pd = (ProxyD3D *)self;
    IDirect3DDevice9 *real_dev = NULL;
    HRESULT hr = pd->real->lpVtbl->CreateDevice(
        pd->real, adapter, type, focus, flags, pp, &real_dev);
    if (FAILED(hr) || !real_dev) { *out = NULL; return hr; }

    /* Shallow-copy real vtable then patch our two hooks */
    memcpy(&g_vt, real_dev->lpVtbl, sizeof(IDirect3DDevice9Vtbl));
    g_vt.Present                  = hook_Present;
    g_vt.SetPixelShaderConstantF  = hook_SetPSConstF;

    g_dev.lpVtbl = &g_vt;
    g_dev.real   = real_dev;
    *out = (IDirect3DDevice9 *)&g_dev;
    return S_OK;
}

/* ── Shared init: load real d3d9.dll and wrap the IDirect3D9 ─────────── */

static void ensure_real(void)
{
    if (g_real) return;
    char path[MAX_PATH];
    GetSystemDirectory(path, MAX_PATH);
    strcat(path, "\\d3d9.dll");
    g_real = LoadLibraryA(path);
    real_Direct3DCreate9 = (void *)GetProcAddress(g_real, "Direct3DCreate9");
}

static IDirect3D9 *wrap_d3d(IDirect3D9 *real)
{
    if (!real) return NULL;
    memcpy(&g_d3d_vt, real->lpVtbl, sizeof(IDirect3D9Vtbl));
    g_d3d_vt.CreateDevice = hook_CreateDevice;
    g_d3d.lpVtbl = &g_d3d_vt;
    g_d3d.real   = real;
    return (IDirect3D9 *)&g_d3d;
}

/* ── Exports ─────────────────────────────────────────────────────────── */

IDirect3D9 *WINAPI Direct3DCreate9(UINT sdk)
{
    ensure_real();
    if (g_log) { fprintf(g_log, "# Direct3DCreate9 called\n"); fflush(g_log); }
    return wrap_d3d(real_Direct3DCreate9(sdk));
}

HRESULT WINAPI Direct3DCreate9Ex(UINT sdk, IDirect3D9Ex **ppD3D)
{
    if (g_log) { fprintf(g_log, "# Direct3DCreate9Ex called\n"); fflush(g_log); }
    ensure_real();
    typedef HRESULT (WINAPI *Fn)(UINT, IDirect3D9Ex**);
    Fn fn = (Fn)GetProcAddress(g_real, "Direct3DCreate9Ex");
    if (!fn) return E_NOTIMPL;
    IDirect3D9Ex *real = NULL;
    HRESULT hr = fn(sdk, &real);
    if (FAILED(hr) || !real) { *ppD3D = NULL; return hr; }
    /* IDirect3D9Ex extends IDirect3D9 — wrap as IDirect3D9 */
    *ppD3D = (IDirect3D9Ex *)wrap_d3d((IDirect3D9 *)real);
    return S_OK;
}

BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, LPVOID reserved)
{
    (void)inst; (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) {
        /* Open log in same dir as the exe */
        char exepath[MAX_PATH], *slash;
        GetModuleFileNameA(NULL, exepath, MAX_PATH);
        slash = strrchr(exepath, '\\');
        if (slash) *(slash+1) = '\0';
        strcat(exepath, "elevated_q.csv");
        g_log = fopen(exepath, "w");
        if (g_log) {
            fprintf(g_log,
                "frame,"
                "q0x,q0y,q0z,q0w,"
                "q1x,q1y,q1z,q1w,"
                "q2x,q2y,q2z,q2w,"
                "q3x,q3y,q3z,q3w,"
                "q4x,q4y,q4z,q4w\n");
            fflush(g_log);
        }
    } else if (reason == DLL_PROCESS_DETACH) {
        if (g_log) { fflush(g_log); fclose(g_log); g_log = NULL; }
    }
    return TRUE;
}
