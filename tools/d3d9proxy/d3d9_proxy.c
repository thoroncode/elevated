/*
 * d3d9_proxy.c  —  thin D3D9 proxy for elevated.exe
 *
 * Goal: intercept the 2×1 "camera" render target that the m1 shader writes to
 * (pixel 0 = camPos.xyz, pixel 1 = camTarget.xyz) and log every frame to a CSV.
 *
 * Strategy: vtable-patching (no 119-method forwarder needed).
 *   1. Direct3DCreate9 → call real, patch vtable[16] (CreateDevice)
 *   2. CreateDevice     → call real, patch vtable[28] (CreateRenderTarget)
 *                                             vtable[17] (Present)
 *   3. CreateRenderTarget → if 2×1, save the surface + create staging surface
 *   4. Present           → GetRenderTargetData → LockRect → log, then call real
 *
 * Build (32-bit, matches elevated_1920_1080.exe):
 *   i686-w64-mingw32-gcc -shared -o d3d9.dll d3d9_proxy.c \
 *       -ld3d9 -Wl,--kill-at -m32 -O2
 *
 * Deploy: copy d3d9.dll next to elevated_1920_1080.exe and run under Wine.
 * Output: camera_log.csv in the exe's working directory.
 */

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d9.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

/* ── Global state ─────────────────────────────────────────────────────────── */
static HMODULE  g_real_d3d9   = NULL;
static FILE    *g_log         = NULL;
static DWORD    g_frame       = 0;

static IDirect3DSurface9 *g_camSurf     = NULL;  /* 2×1 render target */
static IDirect3DSurface9 *g_stagingSurf = NULL;  /* lockable copy     */
static D3DFORMAT          g_camFmt      = D3DFMT_UNKNOWN;

/* saved original vtable entries (before patching) */
static HRESULT (WINAPI *real_CreateDevice)(
    IDirect3D9*, UINT, D3DDEVTYPE, HWND, DWORD,
    D3DPRESENT_PARAMETERS*, IDirect3DDevice9**) = NULL;

static HRESULT (WINAPI *real_CreateRenderTarget)(
    IDirect3DDevice9*, UINT, UINT, D3DFORMAT,
    D3DMULTISAMPLE_TYPE, DWORD, BOOL,
    IDirect3DSurface9**, HANDLE*) = NULL;

static HRESULT (WINAPI *real_Present)(
    IDirect3DDevice9*,
    const RECT*, const RECT*, HWND, const RGNDATA*) = NULL;

/* ── half-float → float conversion ───────────────────────────────────────── */
static float half_to_float(uint16_t h) {
    uint32_t sign = (uint32_t)(h >> 15) << 31;
    uint32_t exp  = (h >> 10) & 0x1f;
    uint32_t mant = h & 0x3ff;
    uint32_t f;
    if (exp == 0) {
        if (mant == 0) { f = sign; }
        else { /* denormal */
            exp = 1;
            while (!(mant & 0x400)) { mant <<= 1; exp--; }
            mant &= 0x3ff;
            f = sign | ((exp + 127 - 15) << 23) | (mant << 13);
        }
    } else if (exp == 31) {
        f = sign | 0x7f800000 | (mant << 13); /* inf/nan */
    } else {
        f = sign | ((exp + 127 - 15) << 23) | (mant << 13);
    }
    float result;
    memcpy(&result, &f, 4);
    return result;
}

/* ── VTable patcher ───────────────────────────────────────────────────────── */
static void patch_vtable(void **vtbl, int idx, void *newFn, void **oldFn) {
    DWORD oldProt;
    VirtualProtect(&vtbl[idx], sizeof(void*), PAGE_READWRITE, &oldProt);
    if (oldFn) *oldFn = vtbl[idx];
    vtbl[idx] = newFn;
    VirtualProtect(&vtbl[idx], sizeof(void*), oldProt, &oldProt);
}

/* ── Log a single frame ───────────────────────────────────────────────────── */
static void log_camera(IDirect3DDevice9 *dev) {
    if (!g_camSurf || !g_stagingSurf || !g_log) return;

    HRESULT hr = IDirect3DDevice9_GetRenderTargetData(dev, g_camSurf, g_stagingSurf);
    if (FAILED(hr)) return;

    D3DLOCKED_RECT lr;
    hr = IDirect3DSurface9_LockRect(g_stagingSurf, &lr, NULL, D3DLOCK_READONLY);
    if (FAILED(hr)) return;

    float p[8] = {0}; /* pixel0.xyzw  pixel1.xyzw */

    if (g_camFmt == D3DFMT_A32B32G32R32F) {
        /* 4×float32 per pixel, 2 pixels → 8 floats */
        memcpy(p, lr.pBits, 8 * sizeof(float));
    } else if (g_camFmt == D3DFMT_A16B16G16R16F) {
        /* 4×float16 per pixel → convert */
        uint16_t *h = (uint16_t*)lr.pBits;
        for (int i = 0; i < 8; i++) p[i] = half_to_float(h[i]);
    } else {
        /* unknown format — dump raw bytes as floats anyway */
        int bytes = (g_camFmt == D3DFMT_R32F)  ? 4 :
                    (g_camFmt == D3DFMT_R16F)   ? 2 : 16;
        memcpy(p, lr.pBits, bytes * 2);
    }

    IDirect3DSurface9_UnlockRect(g_stagingSurf);

    /* In D3D9 RGBA float4, memory order is typically R,G,B,A for float32.
       For the m1 shader output float4(cx,cy,cz,roll):
         pixel0: R=cx, G=cy, B=cz, A=roll  → p[0..3]
         pixel1: R=tarX, G=tarY, B=tarZ, A=? → p[4..7]  */
    fprintf(g_log, "%u,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f\n",
            g_frame,
            p[0], p[1], p[2],   /* camPos  x,y,z */
            p[4], p[5], p[6]);  /* camTar  x,y,z */
    fflush(g_log);
}

/* ── Patched IDirect3DDevice9::CreateRenderTarget (vtable index 28) ───────── */
static HRESULT WINAPI my_CreateRenderTarget(
    IDirect3DDevice9 *self, UINT w, UINT h, D3DFORMAT fmt,
    D3DMULTISAMPLE_TYPE ms, DWORD msq, BOOL lockable,
    IDirect3DSurface9 **ppSurf, HANDLE *shared)
{
    HRESULT hr = real_CreateRenderTarget(self, w, h, fmt, ms, msq, lockable, ppSurf, shared);
    if (SUCCEEDED(hr) && w == 2 && h == 1 && ppSurf && *ppSurf) {
        g_camSurf = *ppSurf;
        g_camFmt  = fmt;
        /* create a matching lockable staging surface in SYSTEMMEM */
        if (g_stagingSurf) {
            IDirect3DSurface9_Release(g_stagingSurf);
            g_stagingSurf = NULL;
        }
        IDirect3DDevice9_CreateOffscreenPlainSurface(
            self, 2, 1, fmt, D3DPOOL_SYSTEMMEM, &g_stagingSurf, NULL);
        if (g_log)
            fprintf(g_log, "# 2x1 RT created, fmt=%d, staging=%p\n",
                    (int)fmt, (void*)g_stagingSurf);
    }
    return hr;
}

/* ── Patched IDirect3DDevice9::Present (vtable index 17) ─────────────────── */
static HRESULT WINAPI my_Present(
    IDirect3DDevice9 *self,
    const RECT *src, const RECT *dst, HWND hwnd, const RGNDATA *dirty)
{
    g_frame++;
    log_camera(self);
    return real_Present(self, src, dst, hwnd, dirty);
}

/* ── Patched IDirect3D9::CreateDevice (vtable index 16) ──────────────────── */
static HRESULT WINAPI my_CreateDevice(
    IDirect3D9 *self, UINT adapter, D3DDEVTYPE dtype,
    HWND hwnd, DWORD flags, D3DPRESENT_PARAMETERS *pp,
    IDirect3DDevice9 **ppDev)
{
    HRESULT hr = real_CreateDevice(self, adapter, dtype, hwnd, flags, pp, ppDev);
    if (SUCCEEDED(hr) && ppDev && *ppDev) {
        void **vtbl = *(void***)(*ppDev);
        patch_vtable(vtbl, 28, my_CreateRenderTarget, (void**)&real_CreateRenderTarget);
        patch_vtable(vtbl, 17, my_Present,            (void**)&real_Present);
        if (g_log) fprintf(g_log, "# Device created, vtable patched\n");
    }
    return hr;
}

/* ── DLL entry point ─────────────────────────────────────────────────────── */
BOOL WINAPI DllMain(HINSTANCE hDLL, DWORD reason, LPVOID reserved) {
    if (reason == DLL_PROCESS_ATTACH) {
        /* load the real d3d9 from system32, not ourselves */
        char sysDir[MAX_PATH];
        GetSystemDirectoryA(sysDir, MAX_PATH);
        char realPath[MAX_PATH];
        snprintf(realPath, MAX_PATH, "%s\\d3d9.dll", sysDir);
        g_real_d3d9 = LoadLibraryA(realPath);

        /* open log */
        g_log = fopen("camera_log.csv", "w");
        if (g_log) {
            fprintf(g_log, "frame,camX,camY,camZ,tarX,tarY,tarZ\n");
            fflush(g_log);
        }
    } else if (reason == DLL_PROCESS_DETACH) {
        if (g_log) { fclose(g_log); g_log = NULL; }
    }
    return TRUE;
}

/* ── Exported Direct3DCreate9 ─────────────────────────────────────────────── */
IDirect3D9 * WINAPI Direct3DCreate9(UINT sdkVersion) {
    if (!g_real_d3d9) return NULL;

    typedef IDirect3D9* (WINAPI *PFN)(UINT);
    PFN real = (PFN)GetProcAddress(g_real_d3d9, "Direct3DCreate9");
    if (!real) return NULL;

    IDirect3D9 *d3d = real(sdkVersion);
    if (d3d) {
        void **vtbl = *(void***)d3d;
        patch_vtable(vtbl, 16, my_CreateDevice, (void**)&real_CreateDevice);
    }
    return d3d;
}
