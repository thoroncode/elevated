// main.m — Elevated 4K intro, macOS size-optimized build
//
// One Objective-C file. No Swift runtime. No .metallib.
// Shaders compiled at runtime from inline MSL (shaders.h).
// Synth shared from ../elevated/CSynth/.

#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <AudioUnit/AudioUnit.h>
#import <simd/simd.h>
#import <math.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "shaders.h"
#import "../elevated/CSynth/include/synth.h"

#define CLS(name) ((id)objc_getClass(name))
#define S(name) sel_registerName(name)
#define M0(ret, obj, name) ((ret (*)(id, SEL))objc_msgSend)((id)(obj), S(name))
#define M1(ret, obj, name, t1, a1) ((ret (*)(id, SEL, t1))objc_msgSend)((id)(obj), S(name), (t1)(a1))
#define M2(ret, obj, name, t1, a1, t2, a2) ((ret (*)(id, SEL, t1, t2))objc_msgSend)((id)(obj), S(name), (t1)(a1), (t2)(a2))
#define M3(ret, obj, name, t1, a1, t2, a2, t3, a3) ((ret (*)(id, SEL, t1, t2, t3))objc_msgSend)((id)(obj), S(name), (t1)(a1), (t2)(a2), (t3)(a3))
#define M4(ret, obj, name, t1, a1, t2, a2, t3, a3, t4, a4) ((ret (*)(id, SEL, t1, t2, t3, t4))objc_msgSend)((id)(obj), S(name), (t1)(a1), (t2)(a2), (t3)(a3), (t4)(a4))
#define M5(ret, obj, name, t1, a1, t2, a2, t3, a3, t4, a4, t5, a5) ((ret (*)(id, SEL, t1, t2, t3, t4, t5))objc_msgSend)((id)(obj), S(name), (t1)(a1), (t2)(a2), (t3)(a3), (t4)(a4), (t5)(a5))

static inline id attachmentAt(id owner, NSUInteger index) {
    return M1(id, M0(id, owner, "colorAttachments"), "objectAtIndexedSubscript:", NSUInteger, index);
}

static inline id mkstr(const char *text) {
    return M1(id, CLS("NSString"), "stringWithUTF8String:", const char *, text);
}

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
static AudioUnit        gAudioUnit;

static OSStatus audioCallback(void *ref, AudioUnitRenderActionFlags *flags,
                               const AudioTimeStamp *ts, UInt32 bus,
                               UInt32 nFrames, AudioBufferList *ioData)
{
    (void)ref;(void)flags;(void)ts;(void)bus;
    float *L = (float *)ioData->mBuffers[0].mData;
    float *R = (float *)ioData->mBuffers[1].mData;
    uint32_t pos = gAudioPos;
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

static void generateAudio(void) {
    gAudioBuf = malloc(ELEVATED_TOTAL_SAMPLES * 2 * sizeof(float));
    elevated_generate_music(gAudioBuf);
}

// ── Math helpers ──────────────────────────────────────────────────────────────

static simd_float4x4 lookAtLH(simd_float3 eye, simd_float3 center, simd_float3 up, simd_float4x4 *invOut) {
    simd_float3 z = simd_normalize(center - eye);
    simd_float3 x = simd_normalize(simd_cross(up, z));
    simd_float3 y = simd_cross(z, x);
    if (invOut) {
        *invOut = (simd_float4x4){.columns = {
            {x.x, x.y, x.z, 0},
            {y.x, y.y, y.z, 0},
            {z.x, z.y, z.z, 0},
            {eye.x, eye.y, eye.z, 1}
        }};
    }
    return (simd_float4x4){.columns = {
        {x.x, y.x, z.x, 0},
        {x.y, y.y, z.y, 0},
        {x.z, y.z, z.z, 0},
        {-simd_dot(x,eye), -simd_dot(y,eye), -simd_dot(z,eye), 1}
    }};
}

static simd_float4x4 projLH(float fovY, float aspect, float near, float far, simd_float4x4 *invOut) {
    float y = 1.0f / tanf(fovY * 0.5f);
    float x = y / aspect;
    float z = far / (far - near);
    if (invOut) {
        *invOut = (simd_float4x4){.columns = {
            {1.0f / x, 0, 0, 0},
            {0, 1.0f / y, 0, 0},
            {0, 0, 0, -1.0f / (near * z)},
            {0, 0, 1, 1.0f / near}
        }};
    }
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
    simd_float4x4 invProj, invView;
    simd_float4x4 proj = projLH(camFov, aspect, 0.03125f, 256.0f, &invProj);
    simd_float4x4 view = lookAtLH(camPos, camTarget, up, &invView);
    u->v  = simd_mul(proj, view);
    u->vi = simd_mul(invView, invProj);
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
static int      gRunning = 1;

static void rebuildOffscreen(CGSize size) {
    NSUInteger w = (NSUInteger)size.width, h = (NSUInteger)size.height;
    if (!w || !h) return;

    MTLTextureDescriptor *td;
    td = M4(id, CLS("MTLTextureDescriptor"), "texture2DDescriptorWithPixelFormat:width:height:mipmapped:",
        MTLPixelFormat, MTLPixelFormatRGBA32Float, NSUInteger, w, NSUInteger, h, BOOL, NO);
    M1(void, td, "setUsage:", NSUInteger, MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead);
    M1(void, td, "setStorageMode:", NSUInteger, MTLStorageModePrivate);
    gGbufWorldPos = M1(id, gDevice, "newTextureWithDescriptor:", id, td);

    td = M4(id, CLS("MTLTextureDescriptor"), "texture2DDescriptorWithPixelFormat:width:height:mipmapped:",
        MTLPixelFormat, MTLPixelFormatBGRA8Unorm, NSUInteger, w, NSUInteger, h, BOOL, NO);
    M1(void, td, "setUsage:", NSUInteger, MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead);
    M1(void, td, "setStorageMode:", NSUInteger, MTLStorageModePrivate);
    gSceneColor = M1(id, gDevice, "newTextureWithDescriptor:", id, td);

    td = M4(id, CLS("MTLTextureDescriptor"), "texture2DDescriptorWithPixelFormat:width:height:mipmapped:",
        MTLPixelFormat, MTLPixelFormatDepth32Float, NSUInteger, w, NSUInteger, h, BOOL, NO);
    M1(void, td, "setUsage:", NSUInteger, MTLTextureUsageRenderTarget);
    M1(void, td, "setStorageMode:", NSUInteger, MTLStorageModePrivate);
    gGbufDepth = M1(id, gDevice, "newTextureWithDescriptor:", id, td);
}

static BOOL buildPipelines(void) {
    id shaderSource = mkstr(kMSLSource);
    id sa = mkstr("a");
    id sb = mkstr("b");
    id sc = mkstr("c");
    id sd = mkstr("d");
    id se = mkstr("e");
    id<MTLLibrary> lib =
        M3(id, gDevice, "newLibraryWithSource:options:error:", id, shaderSource, id, nil, NSError **, NULL);
    if (!lib) { return NO; }

    MTLRenderPipelineDescriptor *d;
    id ca0;

    d = M0(id, CLS("MTLRenderPipelineDescriptor"), "new");
    M1(void, d, "setVertexFunction:", id, M1(id, lib, "newFunctionWithName:", id, sa));
    M1(void, d, "setFragmentFunction:", id, M1(id, lib, "newFunctionWithName:", id, sb));
    ca0 = attachmentAt(d, 0);
    M1(void, ca0, "setPixelFormat:", NSUInteger, MTLPixelFormatRGBA32Float);
    M1(void, d, "setDepthAttachmentPixelFormat:", NSUInteger, MTLPixelFormatDepth32Float);
    gGbufPSO = M2(id, gDevice, "newRenderPipelineStateWithDescriptor:error:", id, d, NSError **, NULL);
    if (!gGbufPSO) { return NO; }

    d = M0(id, CLS("MTLRenderPipelineDescriptor"), "new");
    M1(void, d, "setVertexFunction:", id, M1(id, lib, "newFunctionWithName:", id, sc));
    M1(void, d, "setFragmentFunction:", id, M1(id, lib, "newFunctionWithName:", id, sd));
    M1(void, attachmentAt(d, 0), "setPixelFormat:", NSUInteger, MTLPixelFormatBGRA8Unorm);
    gDeferredPSO = M2(id, gDevice, "newRenderPipelineStateWithDescriptor:error:", id, d, NSError **, NULL);
    if (!gDeferredPSO) { return NO; }

    d = M0(id, CLS("MTLRenderPipelineDescriptor"), "new");
    M1(void, d, "setVertexFunction:", id, M1(id, lib, "newFunctionWithName:", id, sc));
    M1(void, d, "setFragmentFunction:", id, M1(id, lib, "newFunctionWithName:", id, se));
    M1(void, attachmentAt(d, 0), "setPixelFormat:", NSUInteger, MTLPixelFormatBGRA8Unorm);
    gPostPSO = M2(id, gDevice, "newRenderPipelineStateWithDescriptor:error:", id, d, NSError **, NULL);
    if (!gPostPSO) { return NO; }

    MTLDepthStencilDescriptor *ds = M0(id, CLS("MTLDepthStencilDescriptor"), "new");
    M1(void, ds, "setDepthCompareFunction:", NSUInteger, MTLCompareFunctionLess);
    M1(void, ds, "setDepthWriteEnabled:", BOOL, YES);
    gDepthState = M1(id, gDevice, "newDepthStencilStateWithDescriptor:", id, ds);

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
            M4(id, CLS("MTLTextureDescriptor"), "texture2DDescriptorWithPixelFormat:width:height:mipmapped:",
                MTLPixelFormat, MTLPixelFormatR32Float, NSUInteger, 256, NSUInteger, 256, BOOL, NO);
        M1(void, td, "setUsage:", NSUInteger, MTLTextureUsageShaderRead);
        M1(void, td, "setStorageMode:", NSUInteger, MTLStorageModeShared);
        gNoiseTex = M1(id, gDevice, "newTextureWithDescriptor:", id, td);
        M4(void, gNoiseTex, "replaceRegion:mipmapLevel:withBytes:bytesPerRow:",
            MTLRegion, MTLRegionMake2D(0,0,256,256), NSUInteger, 0, const void *, gNoisePixels,
            NSUInteger, 256*sizeof(float));
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
        gTerrainVBuf = M3(id, gDevice, "newBufferWithBytes:length:options:",
            const void *, verts, NSUInteger, nverts*sizeof(simd_float2), NSUInteger, MTLResourceStorageModeShared);
        gTerrainIBuf = M3(id, gDevice, "newBufferWithBytes:length:options:",
            const void *, indices, NSUInteger, idx*sizeof(uint32_t), NSUInteger, MTLResourceStorageModeShared);
        free(verts); free(indices);
    }
}

// ── Render loop ───────────────────────────────────────────────────────────────


static void renderFrame(void) {

    id<CAMetalDrawable> drawable = M0(id, gMetalLayer, "nextDrawable");
    if (!drawable) return;

    CGSize sz = M0(CGSize, gMetalLayer, "drawableSize");

    // Time is driven directly by consumed audio samples for A/V sync.
    float t = (float)gAudioPos / 44100.0f;

    // End of demo
    if (t >= (float)(ELEVATED_TOTAL_SAMPLES) / 44100.0f) {
        gRunning = 0;
        return;
    }

    gUniforms.time = t;
    updateUniforms(&gUniforms, sz);

    id<MTLCommandBuffer> cmd = M0(id, gQueue, "commandBuffer");

    // ── Pass 1: G-buffer ─────────────────────────────────────────────────────
    {
        MTLRenderPassDescriptor *rpd = M0(id, CLS("MTLRenderPassDescriptor"), "renderPassDescriptor");
        id ca0 = attachmentAt(rpd, 0);
        id da  = M0(id, rpd, "depthAttachment");
        M1(void, ca0, "setTexture:", id, gGbufWorldPos);
        M1(void, ca0, "setLoadAction:", NSUInteger, MTLLoadActionClear);
        M1(void, ca0, "setStoreAction:", NSUInteger, MTLStoreActionStore);
        M1(void, ca0, "setClearColor:", MTLClearColor, MTLClearColorMake(0,0,0,0));
        M1(void, da, "setTexture:", id, gGbufDepth);
        M1(void, da, "setLoadAction:", NSUInteger, MTLLoadActionClear);
        M1(void, da, "setStoreAction:", NSUInteger, MTLStoreActionDontCare);
        M1(void, da, "setClearDepth:", double, 1.0);

        id<MTLRenderCommandEncoder> enc = M1(id, cmd, "renderCommandEncoderWithDescriptor:", id, rpd);
        M1(void, enc, "setRenderPipelineState:", id, gGbufPSO);
        M1(void, enc, "setCullMode:", NSUInteger, MTLCullModeFront);
        M1(void, enc, "setDepthStencilState:", id, gDepthState);
        M3(void, enc, "setVertexBuffer:offset:atIndex:", id, gTerrainVBuf, NSUInteger, 0, NSUInteger, 0);
        M3(void, enc, "setVertexBytes:length:atIndex:",
            const void *, &gUniforms, NSUInteger, sizeof(gUniforms), NSUInteger, 1);
        M2(void, enc, "setVertexTexture:atIndex:", id, gNoiseTex, NSUInteger, 0);
        M5(void, enc, "drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:",
            NSUInteger, MTLPrimitiveTypeTriangle, NSUInteger, gTerrainIndexCount, NSUInteger, MTLIndexTypeUInt32,
            id, gTerrainIBuf, NSUInteger, 0);
        M0(void, enc, "endEncoding");
    }

    // ── Pass 2: Deferred shading ──────────────────────────────────────────────
    {
        MTLRenderPassDescriptor *rpd = M0(id, CLS("MTLRenderPassDescriptor"), "renderPassDescriptor");
        id ca0 = attachmentAt(rpd, 0);
        M1(void, ca0, "setTexture:", id, gSceneColor);
        M1(void, ca0, "setLoadAction:", NSUInteger, MTLLoadActionDontCare);
        M1(void, ca0, "setStoreAction:", NSUInteger, MTLStoreActionStore);

        id<MTLRenderCommandEncoder> enc = M1(id, cmd, "renderCommandEncoderWithDescriptor:", id, rpd);
        M1(void, enc, "setRenderPipelineState:", id, gDeferredPSO);
        M3(void, enc, "setFragmentBytes:length:atIndex:",
            const void *, &gUniforms, NSUInteger, sizeof(gUniforms), NSUInteger, 0);
        M2(void, enc, "setFragmentTexture:atIndex:", id, gNoiseTex, NSUInteger, 0);
        M2(void, enc, "setFragmentTexture:atIndex:", id, gGbufWorldPos, NSUInteger, 1);
        M3(void, enc, "drawPrimitives:vertexStart:vertexCount:",
            NSUInteger, MTLPrimitiveTypeTriangle, NSUInteger, 0, NSUInteger, 3);
        M0(void, enc, "endEncoding");
    }

    // ── Pass 3: Post-processing → screen ──────────────────────────────────────
    {
        MTLRenderPassDescriptor *rpd = M0(id, CLS("MTLRenderPassDescriptor"), "renderPassDescriptor");
        id ca0 = attachmentAt(rpd, 0);
        M1(void, ca0, "setTexture:", id, M0(id, drawable, "texture"));
        M1(void, ca0, "setLoadAction:", NSUInteger, MTLLoadActionDontCare);
        M1(void, ca0, "setStoreAction:", NSUInteger, MTLStoreActionStore);

        id<MTLRenderCommandEncoder> enc = M1(id, cmd, "renderCommandEncoderWithDescriptor:", id, rpd);
        M1(void, enc, "setRenderPipelineState:", id, gPostPSO);
        M3(void, enc, "setFragmentBytes:length:atIndex:",
            const void *, &gUniforms, NSUInteger, sizeof(gUniforms), NSUInteger, 0);
        M2(void, enc, "setFragmentTexture:atIndex:", id, gNoiseTex, NSUInteger, 0);
        M2(void, enc, "setFragmentTexture:atIndex:", id, gGbufWorldPos, NSUInteger, 1);
        M2(void, enc, "setFragmentTexture:atIndex:", id, gSceneColor, NSUInteger, 2);
        M3(void, enc, "drawPrimitives:vertexStart:vertexCount:",
            NSUInteger, MTLPrimitiveTypeTriangle, NSUInteger, 0, NSUInteger, 3);
        M0(void, enc, "endEncoding");
    }

    M1(void, cmd, "presentDrawable:", id, drawable);
    M0(void, cmd, "commit");
}

// ── App ───────────────────────────────────────────────────────────────────────

int main(void) {
    @autoreleasepool {
        NSApplication *app = M0(id, CLS("NSApplication"), "sharedApplication");
        M1(void, app, "setActivationPolicy:", NSInteger, NSApplicationActivationPolicyRegular);

        gDevice = MTLCreateSystemDefaultDevice();
        gQueue  = M0(id, gDevice, "newCommandQueue");
        NSScreen *screen = M0(id, CLS("NSScreen"), "mainScreen");
        if (!screen) return 1;
        NSRect frame = M0(NSRect, screen, "frame");
        CGFloat scale = M0(CGFloat, screen, "backingScaleFactor");

        NSWindow *window = M4(id, M0(id, CLS("NSWindow"), "alloc"),
            "initWithContentRect:styleMask:backing:defer:",
            NSRect, frame, NSUInteger, NSWindowStyleMaskBorderless,
            NSUInteger, NSBackingStoreBuffered, BOOL, NO);
        NSView *view = M1(id, M0(id, CLS("NSView"), "alloc"), "initWithFrame:", NSRect, frame);
        M1(void, view, "setWantsLayer:", BOOL, YES);
        M1(void, window, "setContentView:", id, view);

        gMetalLayer = M0(id, CLS("CAMetalLayer"), "layer");
        M1(void, gMetalLayer, "setDevice:", id, gDevice);
        M1(void, gMetalLayer, "setPixelFormat:", NSUInteger, MTLPixelFormatBGRA8Unorm);
        M1(void, gMetalLayer, "setFrame:", NSRect, M0(NSRect, view, "bounds"));
        M1(void, gMetalLayer, "setContentsScale:", CGFloat, scale);
        M1(void, gMetalLayer, "setDrawableSize:", CGSize, CGSizeMake(NSWidth(frame) * scale, NSHeight(frame) * scale));
        M1(void, view, "setLayer:", id, gMetalLayer);

        rebuildOffscreen(M0(CGSize, gMetalLayer, "drawableSize"));
        if (!buildPipelines()) return 1;
        buildGeometry();

        M1(void, window, "makeKeyAndOrderFront:", id, nil);
        M1(void, app, "activateIgnoringOtherApps:", BOOL, YES);

        generateAudio();
        startAudioUnit();
        id runLoop = M0(id, CLS("NSRunLoop"), "currentRunLoop");
        id runMode = mkstr("kCFRunLoopDefaultMode");
        id pastDate = M0(id, CLS("NSDate"), "distantPast");

        while (gRunning) {
            renderFrame();
            M2(BOOL, runLoop, "runMode:beforeDate:", id, runMode, id, pastDate);
        }
    }
    return 0;
}
