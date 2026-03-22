/*
 * Minimal d3d9.dll stub for Elevated (rgba 4KB intro, 2009)
 * Purpose: let the demo get past D3D setup so music synthesis runs.
 *
 * Design:
 *  - All vtable entries are noop (returns S_OK).
 *  - "Create*" device methods that return an object pointer via ppOut
 *    need to write a non-null value so the demo doesn't null-deref.
 *    We write &fake_device (our same fake COM object) for those.
 *  - Music buffer address is patched: 0xfbf70500 → MUSIC_BUF (0x10400000)
 *    because macOS won't map the upper 32-bit address space.
 *
 * Vtable offsets confirmed via disassembly:
 *  IDirect3D9    +0x40  CreateDevice
 *  IDirect3DDevice9:
 *    +0x16c CreateVertexShader   (3 params: this, pFn, ppShader)
 *    +0x170 SetVertexShader
 *    +0x1a8 CreatePixelShader    (3 params: this, pFn, ppShader)
 *    +0x1ac SetPixelShader
 *    +0x0c4 CreateVertexDeclaration  (3 params: this, pElems, ppDecl)
 *    +0x104 SetVertexDeclaration
 *    +0x094 SetStreamSource
 *    +0x0a4 BeginScene
 *    +0x0a8 EndScene
 *    +0x0ac Clear
 *    +0x14c DrawIndexedPrimitive
 *    +0x164 SetIndices
 *    +0x178 SetVertexShaderConstantF
 *    +0x1b4 SetPixelShaderConstantF
 */

#include <windows.h>
#include <stddef.h>
#include <stdio.h>

#define IDirect3D9 void

#define VTABLE_SIZE 128

/*
 * Music buffer: the synthesis places N operator buffers sequentially
 * starting at MUSIC_BUF (each 0x4900000 = 76.5 MB).  We allocate
 * 640 MB contiguously via VirtualAlloc(NULL,...) to cover the main
 * output buffer + up to 7 operator working buffers.
 * Fallback: 0x08800000 (may crash if N > 1).
 */
#define MUSIC_BUF_FALLBACK  ((DWORD)0x08800000)
#define SYNTH_TOTAL_SIZE    0x28000000  /* 640 MB: 8 × 76.5 MB + slack */
static DWORD music_buf_addr = MUSIC_BUF_FALLBACK;

/* Generic no-op: returns 0 (S_OK) */
static HRESULT __stdcall noop() { return 0; }

typedef HRESULT (__stdcall *VFN)();
static VFN device_vtable[VTABLE_SIZE];
static VFN d3d_vtable[VTABLE_SIZE];

/* Fake objects: first member is vtable pointer (COM convention) */
static VFN *fake_device = device_vtable;
static VFN *fake_d3d    = d3d_vtable;

/* ------------------------------------------------------------------ */
/* Logging                                                             */
/* ------------------------------------------------------------------ */

static void write_log(const char *msg)
{
    HANDLE f = CreateFileA("C:\\stub_log.txt",
        FILE_APPEND_DATA, FILE_SHARE_READ, NULL,
        OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (f != INVALID_HANDLE_VALUE) {
        DWORD w;
        WriteFile(f, msg, lstrlenA(msg), &w, NULL);
        CloseHandle(f);
    }
}

/* ------------------------------------------------------------------ */
/* Device stub methods that must write an output pointer               */
/* ------------------------------------------------------------------ */

/*
 * Generic "create" stub: the output pointer (ppOut) is the 3rd parameter.
 * Works for CreateVertexShader, CreatePixelShader, CreateVertexDeclaration.
 * Signature: HRESULT __stdcall Fn(this_, arg1, void **ppOut)
 */
static HRESULT __stdcall stub_create3(void *this_, void *arg1, void **ppOut)
{
    (void)this_; (void)arg1;
    if (ppOut) *ppOut = &fake_device;
    return 0;
}

/*
 * Dump music buffer to file (called once from stub_BeginScene).
 * Synthesis output: floats at MUSIC_BUF, then int16 conversion starts
 * at 0x870500.  We write both.
 */
static int music_dumped = 0;

static void dump_music(void)
{
    if (music_dumped) return;
    music_dumped = 1;
    write_log("dumping music buf...\r\n");

    /* Raw float32 synthesis output: ~76 MB */
    {
        HANDLE f = CreateFileA("C:\\music_float.bin",
            GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
        if (f != INVALID_HANDLE_VALUE) {
            /* Write in 1MB chunks to avoid timeout */
            DWORD total = 0x4900000; /* 76.5 MB */
            DWORD chunk = 0x100000;  /* 1 MB */
            BYTE *src = (BYTE *)music_buf_addr;
            DWORD written, offset = 0;
            while (offset < total) {
                DWORD sz = (offset + chunk <= total) ? chunk : (total - offset);
                WriteFile(f, src + offset, sz, &written, NULL);
                offset += sz;
            }
            CloseHandle(f);
            write_log("music_float.bin written\r\n");
        }
    }
}

/*
 * stub_BeginScene: render-loop call — also triggers music dump.
 */
static HRESULT __stdcall stub_BeginScene(void *this_)
{
    (void)this_;
    dump_music();
    return 0;
}

/*
 * Hook ExitProcess via [0x430000] so we dump before the demo exits.
 * The demo never calls BeginScene because the waveOut position check
 * fails (no real audio device), so we must catch ExitProcess instead.
 */
typedef void (__stdcall *ExitProcessFn)(UINT);
static ExitProcessFn real_ExitProcess = NULL;

static void __stdcall stub_ExitProcess(UINT code)
{
    write_log("stub_ExitProcess called\r\n");
    dump_music();
    if (real_ExitProcess) real_ExitProcess(code);
    /* fallback */
    ExitProcess(code);
}

static void hook_exit_process(void)
{
    DWORD *slot = (DWORD *)0x430000;
    real_ExitProcess = (ExitProcessFn)*slot;

    DWORD old;
    VirtualProtect(slot, 4, PAGE_READWRITE, &old);
    *slot = (DWORD)stub_ExitProcess;
    VirtualProtect(slot, 4, old, &old);
    write_log("ExitProcess hook OK\r\n");
}

/*
 * IDirect3D9::CreateDevice — writes *ppDevice.
 * vtable offset 0x40 (entry 16).
 */
static HRESULT __stdcall stub_CreateDevice(
    void *this_,
    UINT adapter, int devtype, HWND hwnd, DWORD flags,
    void *pPP, void **ppDevice)
{
    (void)this_; (void)adapter; (void)devtype;
    (void)hwnd;  (void)flags;   (void)pPP;
    write_log("stub_CreateDevice called\r\n");
    dump_music();          /* synthesis is done by the time CreateDevice is called */
    *ppDevice = &fake_device;
    return 0;
}

/* ------------------------------------------------------------------ */
/* Music buffer address patch                                           */
/* ------------------------------------------------------------------ */

/*
 * The decompressed code has:
 *   0x420152: BF 00 05 F7 FB  (mov edi, 0xfbf70500)
 * We overwrite the 4-byte immediate with MUSIC_BUF.
 * Code pages are rwx in Wine, so no VirtualProtect needed in practice,
 * but we call it for correctness.
 */
static void alloc_synth_mem(void)
{
    void *p = VirtualAlloc(NULL, SYNTH_TOTAL_SIZE,
                           MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
    if (p) {
        music_buf_addr = (DWORD)p;
        char msg[64];
        wsprintfA(msg, "synth alloc OK at 0x%08lx\r\n", music_buf_addr);
        write_log(msg);
    } else {
        music_buf_addr = MUSIC_BUF_FALLBACK;
        write_log("synth alloc FAIL, using fallback\r\n");
    }
}

static void patch_music_buf(void)
{
    BYTE *p = (BYTE *)0x420152;
    if (p[0] == 0xBF &&
        p[1] == 0x00 && p[2] == 0x05 &&
        p[3] == 0xF7 && p[4] == 0xFB)
    {
        DWORD old;
        VirtualProtect(p, 5, PAGE_EXECUTE_READWRITE, &old);
        DWORD newaddr = music_buf_addr;
        p[1] = (BYTE)(newaddr);
        p[2] = (BYTE)(newaddr >>  8);
        p[3] = (BYTE)(newaddr >> 16);
        p[4] = (BYTE)(newaddr >> 24);
        VirtualProtect(p, 5, old, &old);
        FlushInstructionCache(GetCurrentProcess(), p, 5);
        write_log("music buf patch OK\r\n");
    } else {
        write_log("music buf patch: unexpected bytes, skip\r\n");
    }
}

/*
 * Patch the D3D setup function at 0x420500 to be a no-op.
 *
 * The function starts with `pushal` (0x60) and ends with `popal; ret`.
 * We overwrite the 2 bytes immediately after `pushal` with `popal; ret`
 * (0x61 0xC3), making the function body: pushal; popal; ret.
 *
 * This is safe because music synthesis does not use any D3D objects
 * set up by this function.
 */
static void patch_d3d_setup(void)
{
    BYTE *p = (BYTE *)0x420500;
    /* Expect: 60 (pushal), BE (mov esi, ...) */
    if (p[0] == 0x60 && p[1] == 0xBE) {
        DWORD old;
        VirtualProtect(p, 3, PAGE_EXECUTE_READWRITE, &old);
        p[1] = 0x61;  /* popal */
        p[2] = 0xC3;  /* ret   */
        VirtualProtect(p, 3, old, &old);
        FlushInstructionCache(GetCurrentProcess(), p, 3);
        write_log("d3d_setup patch OK\r\n");
    } else {
        write_log("d3d_setup patch: unexpected bytes, skip\r\n");
    }
}

/* ------------------------------------------------------------------ */
/* Direct3DCreate9 — sole export                                        */
/* ------------------------------------------------------------------ */

IDirect3D9 * __stdcall Direct3DCreate9(UINT sdk_version)
{
    (void)sdk_version;
    write_log("Direct3DCreate9 called\r\n");

    alloc_synth_mem();
    patch_music_buf();
    patch_d3d_setup();
    hook_exit_process();

    /* Dump decompressed code for analysis */
    {
        HANDLE f = CreateFileA("C:\\d3d_code.bin",
            GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
        if (f != INVALID_HANDLE_VALUE) {
            DWORD w;
            WriteFile(f, (void*)0x420500, 1024, &w, NULL);
            CloseHandle(f);
            write_log("code dump OK\r\n");
        }
    }

    /* Dump synthesis init code (0x420100-0x420500) for analysis */
    {
        HANDLE f = CreateFileA("C:\\synth_code.bin",
            GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
        if (f != INVALID_HANDLE_VALUE) {
            DWORD w;
            WriteFile(f, (void*)0x420100, 0x400, &w, NULL);
            CloseHandle(f);
            write_log("synth dump OK\r\n");
        }
    }


    /* All vtable entries → noop */
    for (int i = 0; i < VTABLE_SIZE; i++) {
        device_vtable[i] = noop;
        d3d_vtable[i]    = noop;
    }

    /* IDirect3D9::CreateDevice at offset 0x40 */
    d3d_vtable[0x40/4] = (VFN)stub_CreateDevice;

    /* Device create methods that must write output pointers */
    device_vtable[0x16c/4] = (VFN)stub_create3;  /* CreateVertexShader  */
    device_vtable[0x1a8/4] = (VFN)stub_create3;  /* CreatePixelShader   */
    device_vtable[0x0c4/4] = (VFN)stub_create3;  /* CreateVertexDeclaration */

    /* BeginScene triggers music dump */
    device_vtable[0x0a4/4] = (VFN)stub_BeginScene;

    return (void*)&fake_d3d;
}

BOOL WINAPI DllMain(HINSTANCE h, DWORD reason, LPVOID r)
{
    (void)h; (void)reason; (void)r;
    return TRUE;
}
