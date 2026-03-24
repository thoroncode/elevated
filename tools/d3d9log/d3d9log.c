/*
 * d3d9log.c — D3D9 transparent proxy that logs shader constants to CSV
 *
 * Strategy: patch vtable ENTRIES IN-PLACE using VirtualProtect to make the
 * original read-only vtable in d3d9.dll's .rdata temporarily writable.
 * This never changes the lpVtbl pointer on any COM object — D3D9's internal
 * validation sees the same vtable address as always.
 *
 * Build (32-bit, cross-compiled on Mac):
 *   i686-w64-mingw32-gcc -shared -nostdlib -o d3d9.dll d3d9log.c \
 *       -ld3d9 -lkernel32 -lgcc -Wl,--kill-at -O2
 *
 * Deploy: place d3d9.dll alongside elevated_1920_1080.exe
 * Output: elevated_q.csv in the same directory as the exe
 *
 * CSV columns:
 *   frame, q0..q4 (each as x,y,z,w)  — q[2].w = terScale
 */

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d9.h>

/* ── Debug helper — forward declaration ────────────────────────────────── */
static void dbg(const char *msg);

/* ── sprintf from msvcrt.dll (loaded at startup) ───────────────────────── */
typedef int (__cdecl *sprintf_fn)(char *, const char *, ...);
static sprintf_fn g_sprintf = NULL;

/* ── Real d3d9.dll ─────────────────────────────────────────────────────── */
static HMODULE g_real = NULL;
static IDirect3D9 *(WINAPI *real_Direct3DCreate9)(UINT) = NULL;

static void ensure_real(void) {
    if (g_real) return;
    char path[MAX_PATH];
    GetSystemDirectoryA(path, MAX_PATH);
    lstrcatA(path, "\\d3d9.dll");
    g_real = LoadLibraryA(path);
    real_Direct3DCreate9 = (void*)GetProcAddress(g_real, "Direct3DCreate9");
}

/* ── Log file (Win32 HANDLE, no CRT) ──────────────────────────────────── */
static HANDLE g_log   = INVALID_HANDLE_VALUE;
static DWORD  g_frame = 0;

static void log_write(const char *s) {
    DWORD n;
    WriteFile(g_log, s, lstrlenA(s), &n, NULL);
}

/* ── Captured q[0..4] ─────────────────────────────────────────────────── */
static float g_q[5][4];

/* ══════════════════════════════════════════════════════════════════════════
 * Device vtable patch
 * We write our hooks into the REAL vtable (temporarily RW via VirtualProtect).
 * dev->lpVtbl is never changed — D3D9 internal code sees the same pointer.
 * ══════════════════════════════════════════════════════════════════════════ */

static int g_dev_patched = 0;

/* Original function pointers (saved so we can call through) */
static HRESULT (WINAPI *orig_Present)(IDirect3DDevice9*, const RECT*,
                                       const RECT*, HWND, const RGNDATA*);
static HRESULT (WINAPI *orig_SetPSConstF)(IDirect3DDevice9*, UINT,
                                           const float*, UINT);

static HRESULT WINAPI hook_SetPSConstF(IDirect3DDevice9 *dev,
    UINT startReg, const float *data, UINT count)
{
    for (UINT i = 0; i < count && (startReg + i) < 5; i++)
        __builtin_memcpy(g_q[startReg + i], data + i*4, sizeof(float)*4);
    return orig_SetPSConstF(dev, startReg, data, count);
}

static HRESULT WINAPI hook_Present(IDirect3DDevice9 *dev,
    const RECT *src, const RECT *dst, HWND hwnd, const RGNDATA *dirty)
{
    if (g_log != INVALID_HANDLE_VALUE && g_sprintf) {
        char buf[512];
        int len = g_sprintf(buf, "%lu", g_frame++);
        for (int r = 0; r < 5; r++)
            len += g_sprintf(buf + len, ",%.6f,%.6f,%.6f,%.6f",
                             g_q[r][0], g_q[r][1], g_q[r][2], g_q[r][3]);
        buf[len++] = '\n';
        DWORD written;
        WriteFile(g_log, buf, len, &written, NULL);
        if ((g_frame % 60) == 0) FlushFileBuffers(g_log);
    }
    return orig_Present(dev, src, dst, hwnd, dirty);
}

static void patch_device(IDirect3DDevice9 *dev) {
    if (g_dev_patched) return;
    g_dev_patched = 1;
    dbg("L: patch_device\n");

    IDirect3DDevice9Vtbl *vt = dev->lpVtbl;
    DWORD old;
    VirtualProtect(vt, sizeof(IDirect3DDevice9Vtbl), PAGE_READWRITE, &old);
    orig_Present     = vt->Present;
    orig_SetPSConstF = vt->SetPixelShaderConstantF;
    vt->Present                 = hook_Present;
    vt->SetPixelShaderConstantF = hook_SetPSConstF;
    VirtualProtect(vt, sizeof(IDirect3DDevice9Vtbl), old, &old);
    dbg("M: device patched\n");
}

/* ══════════════════════════════════════════════════════════════════════════
 * IDirect3D9 CreateDevice intercept — same in-place vtable entry patch
 * ══════════════════════════════════════════════════════════════════════════ */

static int g_d3d_patched = 0;
static HRESULT (WINAPI *orig_CreateDevice)(IDirect3D9*, UINT, D3DDEVTYPE,
    HWND, DWORD, D3DPRESENT_PARAMETERS*, IDirect3DDevice9**);

static HRESULT WINAPI hook_CreateDevice(IDirect3D9 *d3d,
    UINT adapter, D3DDEVTYPE type, HWND focus,
    DWORD flags, D3DPRESENT_PARAMETERS *pp, IDirect3DDevice9 **out)
{
    dbg("J: hook_CreateDevice\n");
    HRESULT hr = orig_CreateDevice(d3d, adapter, type, focus, flags, pp, out);
    dbg(SUCCEEDED(hr) ? "K: CreateDevice OK\n" : "K: CreateDevice FAILED\n");
    if (SUCCEEDED(hr) && *out)
        patch_device(*out);
    return hr;
}

static void patch_d3d(IDirect3D9 *d3d) {
    if (g_d3d_patched) return;
    g_d3d_patched = 1;

    IDirect3D9Vtbl *vt = d3d->lpVtbl;
    DWORD old;
    VirtualProtect(vt, sizeof(IDirect3D9Vtbl), PAGE_READWRITE, &old);
    orig_CreateDevice = vt->CreateDevice;
    vt->CreateDevice  = hook_CreateDevice;
    VirtualProtect(vt, sizeof(IDirect3D9Vtbl), old, &old);
    dbg("I2: d3d vtable entry patched\n");
}

/* ── Exports ─────────────────────────────────────────────────────────── */

IDirect3D9 *WINAPI Direct3DCreate9(UINT sdk) {
    dbg("H: Direct3DCreate9\n");
    ensure_real();
    dbg(real_Direct3DCreate9 ? "I: real fn OK\n" : "I: real fn NULL\n");
    IDirect3D9 *d3d = real_Direct3DCreate9(sdk);
    if (d3d) {
        patch_d3d(d3d);
        if (g_log != INVALID_HANDLE_VALUE) {
            log_write("# Direct3DCreate9 called\n");
            FlushFileBuffers(g_log);
        }
    }
    return d3d;
}

HRESULT WINAPI Direct3DCreate9Ex(UINT sdk, IDirect3D9Ex **out) {
    ensure_real();
    typedef HRESULT (WINAPI *Fn)(UINT, IDirect3D9Ex**);
    Fn fn = (Fn)GetProcAddress(g_real, "Direct3DCreate9Ex");
    if (!fn) return E_NOTIMPL;
    HRESULT hr = fn(sdk, out);
    if (SUCCEEDED(hr) && *out) patch_d3d((IDirect3D9*)*out);
    return hr;
}

/* ── Debug helper — writes checkpoints to d3d9dbg.txt next to the exe ── */
static char g_dir[MAX_PATH];

static void dbg(const char *msg) {
    char path[MAX_PATH];
    lstrcpyA(path, g_dir);
    lstrcatA(path, "d3d9dbg.txt");
    HANDLE h = CreateFileA(path, GENERIC_WRITE, FILE_SHARE_READ,
                           NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) return;
    SetFilePointer(h, 0, NULL, FILE_END);
    DWORD n; WriteFile(h, msg, lstrlenA(msg), &n, NULL);
    CloseHandle(h);
}

/* ── DLL entry ───────────────────────────────────────────────────────── */

BOOL WINAPI _DllMainCRTStartup(HINSTANCE inst, DWORD reason, LPVOID reserved);

BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, LPVOID reserved) {
    (void)inst; (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) {
        /* Build exe directory first so dbg() has a valid path */
        GetModuleFileNameA(NULL, g_dir, MAX_PATH);
        char *p = g_dir, *slash = NULL;
        while (*p) { if (*p == '\\') slash = p; p++; }
        if (slash) *(slash + 1) = '\0';

        dbg("A: DllMain PROCESS_ATTACH\n");

        HMODULE crt = LoadLibraryA("msvcrt.dll");
        if (crt) {
            g_sprintf = (sprintf_fn)GetProcAddress(crt, "sprintf");
            dbg(g_sprintf ? "B: sprintf OK\n" : "B: sprintf FAILED\n");
        } else {
            dbg("B: msvcrt.dll FAILED\n");
        }

        char path[MAX_PATH];
        lstrcpyA(path, g_dir);
        lstrcatA(path, "elevated_q.csv");
        dbg("C: csv path built\n");
        dbg(path); dbg("\n");

        g_log = CreateFileA(path, GENERIC_WRITE, FILE_SHARE_READ, NULL,
                            CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
        if (g_log != INVALID_HANDLE_VALUE) {
            dbg("E: log file opened\n");
            log_write("frame,"
                      "q0x,q0y,q0z,q0w,"
                      "q1x,q1y,q1z,q1w,"
                      "q2x,q2y,q2z,q2w,"
                      "q3x,q3y,q3z,q3w,"
                      "q4x,q4y,q4z,q4w\n");
            FlushFileBuffers(g_log);
            dbg("F: header written\n");
        } else {
            dbg("E: log file FAILED\n");
        }
        dbg("G: DllMain done\n");
    } else if (reason == DLL_PROCESS_DETACH) {
        dbg("Z: DllMain PROCESS_DETACH\n");
        if (g_log != INVALID_HANDLE_VALUE) {
            FlushFileBuffers(g_log);
            CloseHandle(g_log);
            g_log = INVALID_HANDLE_VALUE;
        }
    }
    return TRUE;
}

BOOL WINAPI _DllMainCRTStartup(HINSTANCE inst, DWORD reason, LPVOID reserved) {
    return DllMain(inst, reason, reserved);
}
