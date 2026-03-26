// main.m — Elevated 4K intro, macOS size-optimized build
//
// One Objective-C file. No Swift runtime. No .metallib.
// Shaders compiled at runtime from inline MSL (shaders.h).
// Synth shared from ../elevated/CSynth/.

#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <QuartzCore/CADisplayLink.h>
#import <AudioUnit/AudioUnit.h>
#import <CoreAudio/CoreAudio.h>
#import <simd/simd.h>
#import <math.h>
#import <pthread.h>
#import "shaders.h"
#import "../elevated/CSynth/include/synth.h"

// ── Uniforms (must match Shaders.metal layout exactly) ───────────────────────

typedef struct {
    simd_float4   q[16];
    simd_float4x4 v;
    simd_float4x4 vi;
    simd_float2   resolution;
    float         time;
    float         _pad;
} Uniforms;

// ── Sync data — packed 3 bytes/key (was 12) ──────────────────────────────────
// Format: byte0=(interp<<7)|(row>>8), byte1=row&0xFF, byte2=value(0-255)
// 203 keys × 3 bytes = 609 bytes (was 2436)

static const uint8_t kSyncCount[12] = {28,6,15,20,20,16,24,13,8,23,21,9};

#define SYNC_CAMSEEDX    0
#define SYNC_CAMSEEDY   28
#define SYNC_CAMSPEED   34
#define SYNC_CAMFOV     49
#define SYNC_CAMPOSY    69
#define SYNC_CAMTARY    89
#define SYNC_SUNANGLE  105
#define SYNC_WLEVEL    129
#define SYNC_SEASON    142
#define SYNC_BRIGHT    150
#define SYNC_CONTRAST  173
#define SYNC_TERSCALE  194

static const uint8_t kSyncData[] = {
    /* camSeedX */
    0x00,0x00,0x62, 0x00,0x10,0x05, 0x00,0x20,0x11, 0x00,0x2c,0x71,
    0x00,0x38,0x6c, 0x00,0x3e,0x12, 0x00,0x48,0x09, 0x00,0x50,0x69,
    0x00,0x58,0x06, 0x00,0x5c,0x65, 0x00,0x68,0xba, 0x00,0x78,0x0c,
    0x00,0x8c,0x51, 0x00,0x96,0x62, 0x00,0xa8,0x99, 0x00,0xc4,0x72,
    0x00,0xd4,0x30, 0x00,0xe4,0x53, 0x01,0x04,0x0b, 0x01,0x0c,0x08,
    0x01,0x14,0x16, 0x01,0x24,0x0b, 0x01,0x34,0x03, 0x01,0x48,0x09,
    0x01,0x58,0x32, 0x01,0x68,0x01, 0x01,0x88,0x7d, 0x02,0x00,0x00,
    /* camSeedY */
    0x00,0x00,0x00, 0x00,0x96,0x01, 0x01,0x34,0x00, 0x01,0x58,0x01,
    0x01,0x68,0x00, 0x02,0x00,0x00,
    /* camSpeed */
    0x00,0x00,0x01, 0x00,0x5c,0x05, 0x00,0x68,0x04, 0x00,0x8c,0x18,
    0x00,0x96,0x3a, 0x00,0xa8,0x57, 0x00,0xc4,0xff, 0x00,0xe4,0xbc,
    0x01,0x04,0xff, 0x01,0x24,0x10, 0x01,0x34,0x40, 0x01,0x48,0xb3,
    0x01,0x68,0xe2, 0x01,0x88,0x1e, 0x02,0x00,0x00,
    /* camFov */
    0x00,0x00,0x35, 0x00,0x10,0xa0, 0x00,0x1a,0x08, 0x00,0x3e,0x04,
    0x00,0x4b,0x02, 0x00,0x50,0x14, 0x00,0x53,0x0c, 0x00,0x58,0x08,
    0x00,0x5c,0x3c, 0x00,0x78,0x18, 0x00,0x8c,0x12, 0x00,0x96,0x1c,
    0x00,0xa8,0x30, 0x00,0xc4,0xa0, 0x00,0xd4,0x78, 0x00,0xe4,0x40,
    0x01,0x04,0x80, 0x01,0x24,0x35, 0x01,0x48,0x78, 0x02,0x00,0x00,
    /* camPosY */
    0x00,0x00,0x04, 0x00,0x10,0x80, 0x00,0x1a,0x09, 0x00,0x20,0x04,
    0x00,0x2c,0x05, 0x00,0x48,0x0e, 0x00,0x58,0x20, 0x00,0x5c,0x08,
    0x00,0x8c,0x50, 0x00,0x96,0x8c, 0x00,0xa8,0x10, 0x00,0xc4,0x08,
    0x01,0x0c,0x04, 0x01,0x14,0x10, 0x01,0x2c,0x30, 0x01,0x34,0xbe,
    0x01,0x48,0x0e, 0x01,0x58,0x14, 0x01,0x68,0x0e, 0x02,0x00,0x00,
    /* camTarY */
    0x00,0x00,0x20, 0x00,0x10,0xff, 0x00,0x1a,0x80, 0x00,0x48,0x7f,
    0x00,0x58,0x80, 0x00,0x8c,0x6a, 0x00,0x96,0x6c, 0x00,0xa8,0x73,
    0x00,0xc4,0x80, 0x01,0x0c,0xc8, 0x01,0x14,0x80, 0x01,0x2c,0x6f,
    0x01,0x34,0x50, 0x01,0x58,0x64, 0x01,0x68,0x78, 0x02,0x00,0x00,
    /* sunAngle */
    0x00,0x00,0x40, 0x00,0x1a,0x5a, 0x00,0x20,0x20, 0x00,0x3e,0x38,
    0x00,0x48,0xa0, 0x00,0x50,0x40, 0x00,0x58,0xa0, 0x00,0x5c,0xb4,
    0x00,0x68,0x8c, 0x00,0x78,0xa5, 0x00,0x8c,0x6e, 0x00,0x96,0x50,
    0x00,0xa8,0x69, 0x00,0xc4,0x32, 0x00,0xe4,0x0a, 0x01,0x04,0x96,
    0x01,0x14,0x55, 0x01,0x24,0x40, 0x01,0x34,0xaa, 0x01,0x48,0x64,
    0x01,0x58,0xaa, 0x01,0x68,0x00, 0x01,0x88,0x23, 0x02,0x00,0x00,
    /* waterLevel */
    0x00,0x00,0x9a, 0x00,0x1a,0xc8, 0x00,0x20,0x00, 0x00,0x48,0xaa,
    0x00,0x5c,0x00, 0x00,0xa8,0x78, 0x00,0xc4,0xa0, 0x00,0xd4,0x28,
    0x01,0x34,0xb4, 0x01,0x58,0x00, 0x01,0x68,0xc1, 0x01,0x88,0xaa,
    0x02,0x00,0x00,
    /* season */
    0x00,0x00,0x00, 0x81,0x24,0x00, 0x81,0x2c,0x40, 0x81,0x34,0x80,
    0x01,0x42,0xff, 0x81,0x88,0xff, 0x01,0xa8,0x00, 0x02,0x00,0x00,
    /* brightness */
    0x80,0x00,0x00, 0x00,0x08,0x80, 0x00,0x1a,0x6e, 0x00,0x3e,0x20,
    0x00,0x48,0x5a, 0x00,0x5c,0x6e, 0x00,0x78,0x80, 0x00,0x8c,0x5a,
    0x80,0xa0,0x5a, 0x00,0xa7,0x00, 0x00,0xa8,0x80, 0x00,0xc4,0x78,
    0x00,0xe4,0x69, 0x80,0xfa,0x69, 0x00,0xfb,0x80, 0x01,0x04,0x64,
    0x01,0x34,0x18, 0x01,0x48,0x78, 0x01,0x68,0x6e, 0x01,0x88,0x64,
    0x81,0xa8,0x64, 0x01,0xc0,0x00, 0x02,0x00,0x00,
    /* contrast */
    0x00,0x00,0x96, 0x00,0x3e,0xfa, 0x00,0x48,0xb4, 0x80,0x5c,0x00,
    0x00,0x66,0xa0, 0x00,0x78,0x80, 0x00,0x8c,0xbe, 0x80,0xa0,0xbe,
    0x00,0xa7,0x82, 0x00,0xa8,0xa0, 0x00,0xc4,0x8c, 0x00,0xe4,0xb4,
    0x81,0x24,0x00, 0x01,0x25,0xbe, 0x01,0x34,0xff, 0x01,0x48,0x96,
    0x01,0x68,0xaa, 0x01,0x88,0xb4, 0x81,0xa8,0xb4, 0x01,0xc0,0x80,
    0x02,0x00,0x00,
    /* terScale */
    0x00,0x00,0xc8, 0x00,0x1a,0x8c, 0x00,0x20,0xc8, 0x00,0x78,0xff,
    0x01,0x04,0xdc, 0x01,0x24,0xff, 0x01,0x48,0x14, 0x01,0x68,0xe6,
    0x02,0x00,0x00,
};

static float syncParam(int position, int trackOffset, int count) {
    float ro  = (float)position / 20840.0f;
    int   iri = (int)floorf(ro);
    const uint8_t *d = kSyncData + trackOffset * 3;
    int r = 0;
    while (r < count) {
        int row = (((int)(d[r*3] & 0x03)) << 8) | d[r*3+1];
        if (row >= iri) break;
        r++;
    }
    if (r >= count) r = count - 1;
    if (r > 0) r--;
    int interp = d[r*3] >> 7;
    float val  = d[r*3+2];
    if (!interp) return val;
    int row0 = (((int)(d[r*3]     & 0x03)) << 8) | d[r*3+1];
    int row1 = (((int)(d[r*3+3]   & 0x03)) << 8) | d[r*3+4];
    float val1 = d[r*3+5];
    return val + (val1 - val) * (ro - (float)row0) / (float)(row1 - row0);
}
// Track index enum matching kSyncCount order
enum { TR_CAMSEEDX=0,TR_CAMSEEDY,TR_CAMSPEED,TR_CAMFOV,TR_CAMPOSY,
       TR_CAMTARY,TR_SUNANGLE,TR_WLEVEL,TR_SEASON,TR_BRIGHT,TR_CONTRAST,TR_TERSCALE };
static const int kSyncOffset[12] = {0,28,34,49,69,89,105,129,142,150,173,194};
#define SYNC(pos, idx) syncParam(pos, kSyncOffset[idx], kSyncCount[idx])

// ── Audio ─────────────────────────────────────────────────────────────────────

static float          *gAudioBuf   = NULL;
static _Atomic uint32_t gAudioPos  = 0;
static _Atomic int      gAudioReady = 0;
static AudioUnit        gAudioUnit;

static OSStatus audioCallback(void *ref, AudioUnitRenderActionFlags *flags,
                               const AudioTimeStamp *ts, UInt32 bus,
                               UInt32 nFrames, AudioBufferList *ioData)
{
    (void)ref;(void)flags;(void)ts;(void)bus;
    float *L = (float *)ioData->mBuffers[0].mData;
    float *R = (float *)ioData->mBuffers[1].mData;
    uint32_t pos = gAudioPos;
    if (!gAudioReady) {
        memset(L, 0, nFrames * 4); memset(R, 0, nFrames * 4);
        return noErr;
    }
    for (UInt32 i = 0; i < nFrames; i++) {
        uint32_t p = pos + i;
        if (p < ELEVATED_TOTAL_SAMPLES) { L[i] = gAudioBuf[p*2]; R[i] = gAudioBuf[p*2+1]; }
        else { L[i] = R[i] = 0.0f; }
    }
    gAudioPos = pos + nFrames;
    return noErr;
}

static void startAudioUnit(void) {
    AudioComponentDescription desc = {kAudioUnitType_Output, kAudioUnitSubType_DefaultOutput,
                                      kAudioUnitManufacturer_Apple, 0, 0};
    AudioComponentInstanceNew(AudioComponentFindNext(NULL, &desc), &gAudioUnit);
    AURenderCallbackStruct cb = {audioCallback, NULL};
    AudioUnitSetProperty(gAudioUnit, kAudioUnitProperty_SetRenderCallback,
                         kAudioUnitScope_Input, 0, &cb, sizeof(cb));
    AudioStreamBasicDescription fmt = {44100.0, kAudioFormatLinearPCM,
        kAudioFormatFlagIsFloat|kAudioFormatFlagIsNonInterleaved, 4,1,4,2,32,0};
    AudioUnitSetProperty(gAudioUnit, kAudioUnitProperty_StreamFormat,
                         kAudioUnitScope_Input, 0, &fmt, sizeof(fmt));
    AudioUnitInitialize(gAudioUnit);
    AudioOutputUnitStart(gAudioUnit);
}

static void *synthThread(void *arg) {
    (void)arg;
    gAudioBuf = malloc(ELEVATED_TOTAL_SAMPLES * 2 * sizeof(float));
    elevated_generate_music(gAudioBuf);
    gAudioReady = 1;
    return NULL;
}

// ── Math helpers ──────────────────────────────────────────────────────────────

static simd_float4x4 lookAtLH(simd_float3 eye, simd_float3 center, simd_float3 up) {
    simd_float3 z = simd_normalize(center - eye);
    simd_float3 x = simd_normalize(simd_cross(up, z));
    simd_float3 y = simd_cross(z, x);
    return (simd_float4x4){.columns = {
        {x.x, y.x, z.x, 0},
        {x.y, y.y, z.y, 0},
        {x.z, y.z, z.z, 0},
        {-simd_dot(x,eye), -simd_dot(y,eye), -simd_dot(z,eye), 1}
    }};
}

static simd_float4x4 projLH(float fovY, float aspect, float near, float far) {
    float y = 1.0f / tanf(fovY * 0.5f);
    float x = y / aspect;
    float z = far / (far - near);
    return (simd_float4x4){.columns = {
        {x,0,0,0},{0,y,0,0},{0,0,z,1},{0,0,-near*z,0}
    }};
}

// ── CPU noise (matches shader no() / fbm() exactly) ──────────────────────────

static float gNoisePixels[256*256];

static float sampleNoise(float ux, float uy) {
    int x = (int)floorf((ux - floorf(ux)) * 256.0f) & 255;
    int y = (int)floorf((uy - floorf(uy)) * 256.0f) & 255;
    return gNoisePixels[y * 256 + x];
}

// Returns (value, gradX, gradY)
static simd_float3 cpuNo(float px, float py) {
    float ipx = floorf(px), ipy = floorf(py);
    float fx = px - ipx, fy = py - ipy;
    float fx2=fx*fx, fx3=fx2*fx, fx4=fx3*fx, fx5=fx4*fx;
    float fy2=fy*fy, fy3=fy2*fy, fy4=fy3*fy, fy5=fy4*fy;
    float ux = fx5*6 - fx4*15 + fx3*10;
    float uy = fy5*6 - fy4*15 + fy3*10;
    float a = sampleNoise(ipx/256,     ipy/256);
    float b = sampleNoise((ipx+1)/256, ipy/256);
    float c = sampleNoise(ipx/256,     (ipy+1)/256);
    float d = sampleNoise((ipx+1)/256, (ipy+1)/256);
    float abcd = a - b - c + d;
    float v  = a + (b-a)*ux + (c-a)*uy + abcd*ux*uy;
    float dux = (fx4 - fx3*2 + fx2)*30;
    float duy = (fy4 - fy3*2 + fy2)*30;
    float gx = dux * ((b-a) + abcd*uy);
    float gy = duy * ((c-a) + abcd*ux);
    return (simd_float3){v, gx, gy};
}

static float cpuFbm(float px, float py, int octaves) {
    simd_float2 d = {0,0}; float a=0, bv=3;
    for (int i=0; i<octaves; i++) {
        simd_float3 n = cpuNo(0.25f*px, 0.25f*py);
        d.x += n.y; d.y += n.z;
        bv *= 0.5f;
        a += bv * n.x / (1 + d.x*d.x + d.y*d.y);
        float nx = 1.6f*px - 1.2f*py;
        float ny = 1.2f*px + 1.6f*py;
        px = nx; py = ny;
    }
    return a;
}

static simd_float3 m1Camera(Uniforms *u, float xdot) {
    float camSeedX = u->q[0].x, camSeedY = u->q[0].y;
    float camSpeed = u->q[0].z;
    float terScale = u->q[2].w;
    float camPosY  = u->q[1].x, camTarY  = u->q[1].y;
    float t        = u->q[3].w;

    float ox = camSeedX + xdot*0.37f;
    float oy = camSeedY + xdot*0.37f;
    float tt = t * camSpeed;

#define SNXT(ox,oy) ({ ox+=0.1f; oy+=0.1f; sampleNoise(ox,oy); })
    float s1=SNXT(ox,oy), s2=SNXT(ox,oy), s3=SNXT(ox,oy), s4=SNXT(ox,oy);
    float cx = 16*cosf(tt*s1 + 3*s2) + 8*cosf(tt*s3*2 + 3*s4);
    float s5=SNXT(ox,oy), s6=SNXT(ox,oy), s7=SNXT(ox,oy), s8=SNXT(ox,oy);
    float cz = 16*cosf(tt*s5 + 3*s6) + 8*cosf(tt*s7*2 + 3*s8);
#undef SNXT

    float cy = terScale * cpuFbm(cx, cz, 3) + camPosY + camTarY * xdot;

    ox += t*0.5f; oy += t*0.5f;
    ox+=0.1f; oy+=0.1f; cx += 0.002f * cpuNo(ox,oy).x;
    ox+=0.1f; oy+=0.1f; cy += 0.002f * cpuNo(ox,oy).x;
    ox+=0.1f; oy+=0.1f; cz += 0.002f * cpuNo(ox,oy).x;

    return (simd_float3){cx, cy, cz};
}

static void updateUniforms(Uniforms *u, CGSize sz) {
    float t = u->time;
    int   pos = (int)(t * 44100.0f);

    float camSeedX   = SYNC(pos, TR_CAMSEEDX)  / 256.0f;
    float camSeedY   = SYNC(pos, TR_CAMSEEDY)  / 256.0f;
    float camSpeed   = SYNC(pos, TR_CAMSPEED)  / 4096.0f;
    float camFov     = SYNC(pos, TR_CAMFOV)    / 96.0f;
    u->q[0] = (simd_float4){camSeedX, camSeedY, camSpeed, camFov};

    float camPosY    = SYNC(pos, TR_CAMPOSY)   / 64.0f;
    float camTarY    = (SYNC(pos, TR_CAMTARY)  - 128.0f) / 4.0f;
    float sunAngle   = SYNC(pos, TR_SUNANGLE)  / 32.0f;
    float waterLevel = (SYNC(pos, TR_WLEVEL)   - 192.0f) / 128.0f;
    u->q[1] = (simd_float4){camPosY, camTarY, sunAngle, waterLevel};

    float season     = SYNC(pos, TR_SEASON)    / 256.0f;
    float brightness = (SYNC(pos, TR_BRIGHT)   - 128.0f) / 128.0f;
    float contrast   = SYNC(pos, TR_CONTRAST)  / 128.0f;
    float terScale   = (SYNC(pos, TR_TERSCALE) - 128.0f) / 128.0f;
    u->q[2] = (simd_float4){season, brightness, contrast, terScale};

    u->q[3] = (simd_float4){cosf(sunAngle), 0.3125f, sinf(sunAngle), t};

    simd_float3 camPos    = m1Camera(u, 0.0f);
    simd_float3 camTarget = m1Camera(u, 1.0f);
    u->q[4] = (simd_float4){camPos.x, camPos.y, camPos.z, 1.0f};

    int32_t syncPos = (int32_t)(pos < 0 ? 0 : pos > ELEVATED_TOTAL_SAMPLES ? ELEVATED_TOTAL_SAMPLES : pos);
    float   syncVals[8];
    elevated_instrument_sync(syncPos, syncVals);
    for (int i=0; i<8; i++) u->q[5+i] = (simd_float4){syncVals[i],0,0,0};

    float roll   = 0.3f * cosf(t * camSpeed * 2.0f);
    simd_float3 up = {sinf(roll), cosf(roll), 0};
    float aspect = (float)sz.width / (float)sz.height;
    simd_float4x4 proj = projLH(camFov, aspect, 0.03125f, 256.0f);
    simd_float4x4 view = lookAtLH(camPos, camTarget, up);
    u->v  = simd_mul(proj, view);
    u->vi = simd_inverse(u->v);
    u->resolution = (simd_float2){(float)sz.width, (float)sz.height};
}

// ── Metal state ──────────────────────────────────────────────────────────────

static id<MTLDevice>              gDevice;
static id<MTLCommandQueue>        gQueue;
static id<MTLRenderPipelineState> gGbufPSO;
static id<MTLRenderPipelineState> gDeferredPSO;
static id<MTLRenderPipelineState> gPostPSO;
static id<MTLDepthStencilState>   gDepthState;
static CAMetalLayer              *gMetalLayer;

static id<MTLTexture> gGbufWorldPos;
static id<MTLTexture> gGbufDepth;
static id<MTLTexture> gSceneColor;
static id<MTLTexture> gNoiseTex;

static id<MTLBuffer> gTerrainVBuf;
static id<MTLBuffer> gTerrainIBuf;
static int           gTerrainIndexCount;

static Uniforms gUniforms;

static void rebuildOffscreen(CGSize size) {
    NSUInteger w = (NSUInteger)size.width, h = (NSUInteger)size.height;
    if (!w || !h) return;

    MTLTextureDescriptor *td;
    td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                                            width:w height:h mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModePrivate;
    gGbufWorldPos = [gDevice newTextureWithDescriptor:td];

    td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                            width:w height:h mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModePrivate;
    gSceneColor = [gDevice newTextureWithDescriptor:td];

    td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
                                                            width:w height:h mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget;
    td.storageMode = MTLStorageModePrivate;
    gGbufDepth = [gDevice newTextureWithDescriptor:td];
}

static BOOL buildPipelines(void) {
    id<MTLLibrary> lib = [gDevice newLibraryWithSource:@(kMSLSource) options:nil error:NULL];
    if (!lib) { return NO; }

    MTLRenderPipelineDescriptor *d;

    d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction   = [lib newFunctionWithName:@"a"];
    d.fragmentFunction = [lib newFunctionWithName:@"b"];
    d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA32Float;
    d.depthAttachmentPixelFormat      = MTLPixelFormatDepth32Float;
    gGbufPSO = [gDevice newRenderPipelineStateWithDescriptor:d error:NULL];
    if (!gGbufPSO) { return NO; }

    d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction   = [lib newFunctionWithName:@"c"];
    d.fragmentFunction = [lib newFunctionWithName:@"d"];
    d.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    gDeferredPSO = [gDevice newRenderPipelineStateWithDescriptor:d error:NULL];
    if (!gDeferredPSO) { return NO; }

    d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction   = [lib newFunctionWithName:@"c"];
    d.fragmentFunction = [lib newFunctionWithName:@"e"];
    d.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    gPostPSO = [gDevice newRenderPipelineStateWithDescriptor:d error:NULL];
    if (!gPostPSO) { return NO; }

    MTLDepthStencilDescriptor *ds = [MTLDepthStencilDescriptor new];
    ds.depthCompareFunction = MTLCompareFunctionLess;
    ds.depthWriteEnabled    = YES;
    gDepthState = [gDevice newDepthStencilStateWithDescriptor:ds];

    return YES;
}

static void buildGeometry(void) {
    // Noise texture: 256×256 R32Float, frandom() LCG matching D3DXFillTexture
    {
        uint32_t seed = 0;
        for (int i = 0; i < 256*256; i++) {
            seed = seed * 16307u + 17u;
            int16_t v = (int16_t)(seed >> 14);
            gNoisePixels[i] = (float)v / 32768.0f;
        }
        MTLTextureDescriptor *td =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Float
                                                               width:256 height:256 mipmapped:NO];
        td.usage = MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModeShared;
        gNoiseTex = [gDevice newTextureWithDescriptor:td];
        [gNoiseTex replaceRegion:MTLRegionMake2D(0,0,256,256) mipmapLevel:0
                       withBytes:gNoisePixels bytesPerRow:256*sizeof(float)];
    }

    // Terrain mesh: 1024×1024 grid, scale=104 (±52 world units)
    {
        int size = 1024; float scale = 104.0f;
        int nverts = size * size;
        int ntris  = (size-1)*(size-1)*2;
        simd_float2 *verts   = malloc(nverts * sizeof(simd_float2));
        uint32_t    *indices = malloc(ntris * 3 * sizeof(uint32_t));
        for (int z=0; z<size; z++)
            for (int x=0; x<size; x++) {
                verts[z*size+x] = (simd_float2){
                    ((float)x/(size-1) - 0.5f) * scale,
                    ((float)z/(size-1) - 0.5f) * scale
                };
            }
        int idx = 0;
        for (int z=0; z<size-1; z++)
            for (int x=0; x<size-1; x++) {
                uint32_t i = z*size+x, r = size;
                if (((x+z)&1)==0) {
                    indices[idx++]=i; indices[idx++]=i+1;   indices[idx++]=i+r;
                    indices[idx++]=i+1; indices[idx++]=i+r+1; indices[idx++]=i+r;
                } else {
                    indices[idx++]=i;   indices[idx++]=i+1;   indices[idx++]=i+r+1;
                    indices[idx++]=i;   indices[idx++]=i+r+1; indices[idx++]=i+r;
                }
            }
        gTerrainIndexCount = idx;
        gTerrainVBuf = [gDevice newBufferWithBytes:verts length:nverts*sizeof(simd_float2)
                                           options:MTLResourceStorageModeShared];
        gTerrainIBuf = [gDevice newBufferWithBytes:indices length:idx*sizeof(uint32_t)
                                           options:MTLResourceStorageModeShared];
        free(verts); free(indices);
    }
}

// ── Render loop ───────────────────────────────────────────────────────────────

static CFTimeInterval gStartTime = 0;

static void renderFrame(void) {

    id<CAMetalDrawable> drawable = [gMetalLayer nextDrawable];
    if (!drawable) return;

    CGSize sz = gMetalLayer.drawableSize;

    // Time driven by audio position for A/V sync; fall back to wall clock before synth is ready
    float t = gAudioReady
        ? (float)gAudioPos / 44100.0f
        : (float)(CACurrentMediaTime() - gStartTime);

    // End of demo
    if (t >= (float)(ELEVATED_TOTAL_SAMPLES) / 44100.0f) {
        [NSApp terminate:nil];
        return;
    }

    gUniforms.time = t;
    updateUniforms(&gUniforms, sz);

    id<MTLCommandBuffer> cmd = [gQueue commandBuffer];

    // ── Pass 1: G-buffer ─────────────────────────────────────────────────────
    {
        MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
        rpd.colorAttachments[0].texture     = gGbufWorldPos;
        rpd.colorAttachments[0].loadAction  = MTLLoadActionClear;
        rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
        rpd.colorAttachments[0].clearColor  = MTLClearColorMake(0,0,0,0);
        rpd.depthAttachment.texture         = gGbufDepth;
        rpd.depthAttachment.loadAction      = MTLLoadActionClear;
        rpd.depthAttachment.storeAction     = MTLStoreActionDontCare;
        rpd.depthAttachment.clearDepth      = 1.0;

        id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:rpd];
        [enc setRenderPipelineState:gGbufPSO];
        [enc setCullMode:MTLCullModeFront];
        [enc setDepthStencilState:gDepthState];
        [enc setVertexBuffer:gTerrainVBuf offset:0 atIndex:0];
        [enc setVertexBytes:&gUniforms length:sizeof(gUniforms) atIndex:1];
        [enc setVertexTexture:gNoiseTex atIndex:0];
        [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                        indexCount:gTerrainIndexCount
                         indexType:MTLIndexTypeUInt32
                       indexBuffer:gTerrainIBuf
                 indexBufferOffset:0];
        [enc endEncoding];
    }

    // ── Pass 2: Deferred shading ──────────────────────────────────────────────
    {
        MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
        rpd.colorAttachments[0].texture     = gSceneColor;
        rpd.colorAttachments[0].loadAction  = MTLLoadActionDontCare;
        rpd.colorAttachments[0].storeAction = MTLStoreActionStore;

        id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:rpd];
        [enc setRenderPipelineState:gDeferredPSO];
        [enc setFragmentBytes:&gUniforms length:sizeof(gUniforms) atIndex:0];
        [enc setFragmentTexture:gNoiseTex    atIndex:0];
        [enc setFragmentTexture:gGbufWorldPos atIndex:1];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [enc endEncoding];
    }

    // ── Pass 3: Post-processing → screen ──────────────────────────────────────
    {
        MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
        rpd.colorAttachments[0].texture     = drawable.texture;
        rpd.colorAttachments[0].loadAction  = MTLLoadActionDontCare;
        rpd.colorAttachments[0].storeAction = MTLStoreActionStore;

        id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:rpd];
        [enc setRenderPipelineState:gPostPSO];
        [enc setFragmentBytes:&gUniforms length:sizeof(gUniforms) atIndex:0];
        [enc setFragmentTexture:gNoiseTex    atIndex:0];
        [enc setFragmentTexture:gGbufWorldPos atIndex:1];
        [enc setFragmentTexture:gSceneColor   atIndex:2];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [enc endEncoding];
    }

    [cmd presentDrawable:drawable];
    [cmd commit];
}

// ── App ───────────────────────────────────────────────────────────────────────

@interface T : NSObject
@end

@implementation T

- (void)tick:(CADisplayLink *)link { (void)link; renderFrame(); }

@end

int main(void) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];

    gDevice = MTLCreateSystemDefaultDevice();
    gQueue  = [gDevice newCommandQueue];
    NSScreen *screen = NSScreen.mainScreen;
        if (!screen) return 1;
    NSRect frame = screen.frame;
    CGFloat scale = screen.backingScaleFactor;

    NSWindow *window = [[NSWindow alloc]
        initWithContentRect:frame
                  styleMask:NSWindowStyleMaskBorderless
                    backing:NSBackingStoreBuffered defer:NO];
    NSView *view = [[NSView alloc] initWithFrame:frame];
    view.wantsLayer = YES;
    window.contentView = view;

    gMetalLayer = [CAMetalLayer layer];
    gMetalLayer.device = gDevice;
    gMetalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    gMetalLayer.frame = view.bounds;
    gMetalLayer.contentsScale = scale;
    gMetalLayer.drawableSize = CGSizeMake(NSWidth(frame) * scale, NSHeight(frame) * scale);
    view.layer = gMetalLayer;

    rebuildOffscreen(gMetalLayer.drawableSize);
        if (!buildPipelines()) return 1;
    buildGeometry();

    [window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];

    pthread_t tid;
    pthread_create(&tid, NULL, synthThread, NULL);
    pthread_detach(tid);
    startAudioUnit();

    gStartTime = CACurrentMediaTime();
        T *t = [T new];
    CADisplayLink *dl = [screen displayLinkWithTarget:t selector:@selector(tick:)];
    [dl addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        [app run];
    }
}
