// Shaders.metal
// Elevated — Mac/Metal port of the rgba 4KB intro (Breakpoint 2009)
// Original HLSL by iq (Inigo Quilez) + mentor
// Metal translation for educational/personal use

#include <metal_stdlib>
using namespace metal;

// ─── Uniform layout (matches HLSL q[16] + v) ────────────────────────────────
struct Uniforms {
    float4 q[16];
    float4x4 v;       // view-projection matrix
    float4x4 vi;      // inverse view-projection matrix (for ray reconstruction)
    float2 resolution;
    float  time;
    float  _pad;
};

// ─── G-buffer pixel output ───────────────────────────────────────────────────
struct GBufferOut {
    float4 worldPos [[color(0)]];  // xyz=world pos, w=1 if hit
    float4 color    [[color(1)]];  // vertex color pass-through
};

// ─── Vertex shader outputs ───────────────────────────────────────────────────
struct TerrainVert {
    float4 pos   [[position]];
    float4 world;              // world-space position
};

struct WaterVert {
    float4 pos   [[position]];
    float4 world;
};

struct PostVert {
    float4 pos [[position]];
    float2 uv;
};

// ────────────────────────────────────────────────────────────────────────────
// NOISE FUNCTIONS
// ────────────────────────────────────────────────────────────────────────────

// no(p) — smooth Perlin noise, returns float3(value, gradient.xy)
// Translated from HLSL: tex2Dlod samples a 256x256 hash texture
float3 no(float2 p, texture2d<float> t0, sampler s0) {
    float2 f = fract(p);
    float2 u = f*f*f*(f*(f*6-15)+10);  // quintic smoothstep
    float a = t0.sample(s0, (floor(p)+float2(0,0))/256, level(0)).r;
    float b = t0.sample(s0, (floor(p)+float2(1,0))/256, level(0)).r;
    float c = t0.sample(s0, (floor(p)+float2(0,1))/256, level(0)).r;
    float d = t0.sample(s0, (floor(p)+float2(1,1))/256, level(0)).r;
    return float3(
        a+(b-a)*u.x+(c-a)*u.y+(a-b-c+d)*u.x*u.y,
        30*f*f*(f*(f-2)+1)*(float2(b-a,c-a)+(a-b-c+d)*u.yx)
    );
}

// f(p, o) — FBM terrain, o octaves, domain rotation + derivative damping
float fbm(float2 p, float o, texture2d<float> t0, sampler s0) {
    float2 d = 0;
    float a = 0;
    float bv = 3;
    for (float i = 0; i < o; i++) {
        float3 n = no(0.25*p, t0, s0);
        d += n.yz;
        a += (bv *= 0.5) * n.x / (1 + dot(d, d));
        p = float2x2(1.6,-1.2,1.2,1.6) * p;
    }
    return a;
}

// cn(p, e, o) — terrain normal via finite differences
float3 cn(float2 p, float e, float o, constant Uniforms& u,
          texture2d<float> t0, sampler s0) {
    float a = fbm(p, o, t0, s0);
    return normalize(float3(
        u.q[2].w*(a - fbm(p+float2(e,0), o, t0, s0)),
        e,
        u.q[2].w*(a - fbm(p+float2(0,e), o, t0, s0))
    ));
}

// b(p, c, d) — sky/diffuse light contribution
float3 skyLight(float3 p, float3 c, float3 d, constant Uniforms& u,
                texture2d<float> t0, sampler s0) {
    float a = dot(d, u.q[3].xyz);
    float bv = mix(a, dot(c, u.q[3].xyz), 0.5 + 0.5*u.q[2].x);
    return float3(.13,.18,.22)*(c.y + 0.25*saturate(-bv) - 0.1*no(1024*p.xz, t0, s0).y)
         + float3(1.4,1,.7)*saturate(bv)*saturate(2*a);
}

// ────────────────────────────────────────────────────────────────────────────
// PASS 1 — TERRAIN VERTEX SHADER (m0)
// Displaces a flat mesh by terrain height
// ────────────────────────────────────────────────────────────────────────────
vertex TerrainVert terrainVert(
    uint vid [[vertex_id]],
    constant float2* positions [[buffer(0)]],
    constant Uniforms& u       [[buffer(1)]],
    texture2d<float> t0        [[texture(0)]])
{
    constexpr sampler s0(address::repeat, filter::linear);
    float2 xz = positions[vid];

    // Offset FBM by camera world XZ so terrain is procedurally generated around camera.
    // q[4].xz = camera world position XZ; mesh vertices are camera-relative.
    float2 worldXZ = xz + u.q[4].xz;
    float height = u.q[2].w * fbm(worldXZ.yx, 8, t0, s0);
    float4 world = float4(xz.x, height, xz.y, 1);  // camera-relative world position

    TerrainVert out;
    out.world = world;
    out.pos   = u.v * world;
    return out;
}

// ────────────────────────────────────────────────────────────────────────────
// PASS 1 — TERRAIN / WATER FRAGMENT SHADER (m2 pass-through → writes G-buffer)
// Stores world position + hit flag into G-buffer
// ────────────────────────────────────────────────────────────────────────────
fragment GBufferOut gbufferFrag(TerrainVert in [[stage_in]]) {
    GBufferOut out;
    out.worldPos = float4(in.world.xyz, 1.0);  // w=1 flags geometry hit
    out.color    = in.world;
    return out;
}

// ────────────────────────────────────────────────────────────────────────────
// PASS 1b — WATER VERTEX SHADER (m1)
// Generates water surface world positions using cosine waves
// ────────────────────────────────────────────────────────────────────────────
vertex WaterVert waterVert(
    uint vid [[vertex_id]],
    constant float2* positions [[buffer(0)]],
    constant Uniforms& u       [[buffer(1)]],
    texture2d<float> t0        [[texture(0)]])
{
    constexpr sampler s0(address::repeat, filter::linear);
    float2 x = positions[vid];
    float2 o = u.q[0].xy + x.x * 0.37;
    float3 c;
    float t = u.q[3].w * u.q[0].z;

    // Cosine wave synthesis (matches HLSL m1 exactly, += advances o by 0.1 each sample)
    o += 0.1; c.x  = 16*cos(t * t0.sample(s0, o, level(0)).r + 3*t0.sample(s0, o+0.1, level(0)).r);
    o += 0.1; c.x += 8*cos(t * t0.sample(s0, o, level(0)).r * 2 + 3*t0.sample(s0, o+0.1, level(0)).r);
    o += 0.2;
    o += 0.1; c.z  = 16*cos(t * t0.sample(s0, o, level(0)).r + 3*t0.sample(s0, o+0.1, level(0)).r);
    o += 0.1; c.z += 8*cos(t * t0.sample(s0, o, level(0)).r * 2 + 3*t0.sample(s0, o+0.1, level(0)).r);

    c.y = u.q[2].w * fbm(c.xz, 3, t0, s0) + u.q[1].x + u.q[1].y * x.x;

    o += u.q[3].w * 0.5;
    c.x += 0.002 * no(o+0.1, t0, s0).x;
    c.y += 0.002 * no(o+0.2, t0, s0).x;
    c.z += 0.002 * no(o+0.3, t0, s0).x;

    // Make water position camera-relative (subtract camera world XZ)
    // so it's consistent with the terrain G-buffer and the view matrix origin.
    c.x -= u.q[4].x;
    c.z -= u.q[4].z;

    WaterVert out;
    out.world = float4(c, 1);
    out.pos   = u.v * float4(c, 1);
    return out;
}

// ────────────────────────────────────────────────────────────────────────────
// PASS 2 — DEFERRED SHADING (m3)
// Full-screen quad reads G-buffer, shades terrain + sky + water + fog
// ────────────────────────────────────────────────────────────────────────────
vertex PostVert fullscreenVert(uint vid [[vertex_id]]) {
    // Triangle that covers clip space: vids 0,1,2
    float2 pos[3] = { float2(-1,-1), float2(3,-1), float2(-1,3) };
    float2 uv [3] = { float2(0,1),   float2(2,1),  float2(0,-1) };
    PostVert out;
    out.pos = float4(pos[vid], 0, 1);
    out.uv  = uv[vid];
    return out;
}

fragment float4 deferredFrag(
    PostVert in [[stage_in]],
    constant Uniforms& u    [[buffer(0)]],
    texture2d<float> t0     [[texture(0)]],
    texture2d<float> t1     [[texture(1)]])
{
    constexpr sampler s0(address::repeat, filter::linear);
    constexpr sampler s1(address::clamp_to_edge, filter::linear);

    float2 x = in.uv;
    float2 o = x + 0.5/1280;
    float4 d = t1.sample(s1, o);  // G-buffer world pos

    // Reconstruct world-space ray direction from NDC using inverse VP
    float4 near4 = u.vi * float4(x.x*2-1, 1-x.y*2, 0, 1);
    float4 far4  = u.vi * float4(x.x*2-1, 1-x.y*2, 1, 1);
    float3 nearW = near4.xyz / near4.w;
    float3 farW  = far4.xyz  / far4.w;
    float3 e = normalize(farW - nearW);
    // Guard against rays pointing at/below horizon (avoid divide-by-zero and sky blowout)
    float ey = max(e.y, 0.001);
    float2 s = e.xz / ey;

    // Cloud band index
    float k = fmod(2*s.y + 1000, 8);

    // Sky base colour
    float3 c = float3(.55,.65,.75)
        + 0.1 * fbm(s + u.q[3].w*0.2, 10, t0, s0)
        + 0.5 * pow(1-ey, 8)
        + pow(saturate(dot(e, u.q[3].xyz)), 16) * float3(.4,.3,.1)
        + float4(1+0.4*k, 2, 3+0.5*k, 0).xyz
          * (1 - cos(12.5664*s.y))
          * saturate(1 - abs(s.y)/10 - abs(s.x + u.q[5+(int)k].x*0.0012 - 8)/20)
          * exp(-u.q[5+(int)k].x*0.0002);

    if (d.w > 0.5) {
        // d.xyz is camera-relative. Camera is at (0, q[4].y, 0) in local space.
        float t = length(d.xyz - float3(0, u.q[4].y, 0));
        float w = u.q[1].w - d.y;   // water level - surface.y  (< 0 = above water = terrain)

        // World XZ = camera-relative XZ + camera world XZ offset
        float2 camXZ   = u.q[4].xz;
        float2 worldXZ = d.xz + camXZ;

        if (w < 0) {
            // ── TERRAIN ──────────────────────────────────────────────────
            float3 n = cn(worldXZ, 0.001*t, 12 - log2(t), u, t0, s0);
            float  h = fbm(3*worldXZ, 3, t0, s0);
            float  r = no(666*worldXZ, t0, s0).x;

            c = (0.1 + 0.75*u.q[2].x) * (0.8 + 0.2*r);
            // Snow blend
            c = mix(c,
                    mix(float3(.8,.85,.9), float3(.45,.45,.2)*(0.8+0.2*r), u.q[2].x),
                    smoothstep(0.5 - 0.8*n.y, 1 - 1.1*n.y, h*0.15));
            // Soil blend
            c = mix(c,
                    mix(float3(.37,.23,.08), float3(.42,.4,.2), u.q[2].x) * (0.5+0.5*r),
                    smoothstep(0, 1, 50*(n.y-1) + (h+u.q[2].x)/0.4));
            // Lighting (pass world-space surface position for sky noise sample)
            float3 worldSurfPos = float3(d.x + camXZ.x, d.y, d.z + camXZ.y);
            c *= skyLight(worldSurfPos, n, cn(worldXZ, 0.001*t, 5, u, t0, s0), u, t0, s0);

        } else {
            // ── WATER ────────────────────────────────────────────────────
            t = (u.q[1].w - u.q[4].y) / e.y;
            // Ray-plane hit in camera-relative space from camera eye (0, q[4].y, 0)
            float3 camEye = float3(0, u.q[4].y, 0);
            d.xyz = camEye + e * t;
            float2 wXZ = d.xz + camXZ;  // world XZ of water hit
            float3 n = normalize(cn(float2(512,32)*wXZ
                                    + saturate(w*60)*float2(u.q[3].w, 0),
                                    0.001*t, 4, u, t0, s0) * float3(1,6,1));

            c = 0.12 * (float3(.4,1,1) - float3(.2,.6,.4)*saturate(w*16));
            c *= 0.3 + 0.7*u.q[2].x;
            c += pow(1 - dot(-e, n), 4)
               * (pow(saturate(dot(u.q[3].xyz, reflect(-e,n))), 32) * float3(.32,.31,.3) + 0.1);
            float3 worldWaterPos = float3(d.x + camXZ.x, d.y, d.z + camXZ.y);
            c = mix(c,
                    skyLight(worldWaterPos, n, n, u, t0, s0),
                    smoothstep(1, 0,
                        u.q[2].x + w*60
                        - fbm(666*wXZ + saturate(w*60)*float2(u.q[3].w,0)*2, 5, t0, s0)) * 0.5);
        }

        c *= 0.7 + 0.3*smoothstep(0, 1, 256*abs(w));
        c *= exp(-0.042*t);
        c += (1 - exp(-0.1*t))
           * (float3(.52,.59,.65) + pow(saturate(dot(e, u.q[3].xyz)), 8)*float3(.6,.4,.1));
    }

    return float4(c, 0);
}

// ────────────────────────────────────────────────────────────────────────────
// PASS 3 — POST-PROCESSING (m4)
// Motion blur, gamma, vignette, chromatic aberration, film grain
// ────────────────────────────────────────────────────────────────────────────
fragment float4 postFrag(
    PostVert in [[stage_in]],
    constant Uniforms& u    [[buffer(0)]],
    texture2d<float> t0     [[texture(0)]],   // noise texture
    texture2d<float> t1     [[texture(1)]],   // G-buffer
    texture2d<float> t2     [[texture(2)]])   // scene color
{
    constexpr sampler s0(address::repeat, filter::linear);
    constexpr sampler s1(address::clamp_to_edge, filter::linear);

    float2 o = in.uv + 0.5/1280;
    float4 d = t1.sample(s1, o);
    float3 c = t2.sample(s1, o).rgb;

    if (d.w > 0.5) {
        // Motion blur: reproject world pos to clip, sample along motion vector
        float4 clip = u.v * float4(d.xyz, 1);
        clip.y *= -1;
        c = 0;
        for (float i = 0; i < 16; i++) {
            c.x += t2.sample(s1, o + i*(0.5 + 0.5*clip.xy/clip.w - o)/16 + float2( 2,0)/1280).r;
            c.y += t2.sample(s1, o + i*(0.5 + 0.5*clip.xy/clip.w - o)/16 + float2( 0,0)/1280).g;
            c.z += t2.sample(s1, o + i*(0.5 + 0.5*clip.xy/clip.w - o)/16 + float2(-2,0)/1280).b;
        }
        c /= 16;
    }

    // Gamma + brightness/contrast
    c = pow(c, 0.45) * u.q[2].z + u.q[2].y;

    // Vignette
    c *= 0.4 + 9.6*o.x*o.y*(1-o.x)*(1-o.y);

    // Chromatic aberration (subtle red/blue shift)
    c.xz *= 0.98;

    // Film grain
    float w = t0.sample(s0, u.q[3].w * 0.1).r;
    o += w;
    c -= 0.005*w;
    c.x += 0.01 * t0.sample(s0, o + float2(0.1, 0)).r;
    c.y += 0.01 * t0.sample(s0, o + float2(0.2, 0)).r;
    c.z += 0.01 * t0.sample(s0, o + float2(0.3, 0)).r;

    // ── BEACON glow (pulsating lighthouse, world pos in q[13]) ──────────────
    {
        // Beacon position: q[13].xyz = world XZ,Y.  Convert to camera-relative.
        float3 beaconWorld = u.q[13].xyz;
        float2 camXZ       = u.q[4].xz;
        float3 beaconLocal = float3(beaconWorld.x - camXZ.x, beaconWorld.y, beaconWorld.z - camXZ.y);

        float4 bClip = u.v * float4(beaconLocal, 1.0);
        if (bClip.w > 0.01) {
            float2 bNDC    = bClip.xy / bClip.w;
            float2 bUV     = float2(0.5 + 0.5 * bNDC.x, 0.5 - 0.5 * bNDC.y);
            float2 fragUV  = in.uv + 0.5/1280.0;
            float  aspect  = u.resolution.x / u.resolution.y;
            float2 delta   = (fragUV - bUV) * float2(aspect, 1.0);
            float  dist2   = dot(delta, delta);

            // Pulse at ~0.8 Hz (5.03 rad/s)
            float pulse = 0.5 + 0.5 * sin(u.time * 5.03);
            pulse = pulse * pulse;   // sharpen peaks

            // Occlusion: beacon is occluded if G-buffer geometry is closer
            float beaconDist = length(beaconLocal);
            float4 gbAtB     = t1.sample(s1, bUV);
            float  geomDist  = (gbAtB.w > 0.5) ? length(gbAtB.xyz - float3(0, u.q[4].y, 0)) : 1e6;
            float  occlude   = smoothstep(0.0, 3.0, geomDist - beaconDist);

            // Time-based fade in/out (beacon appears at ~70s)
            float timeFade = smoothstep(65.0, 75.0, u.time) * smoothstep(190.0, 180.0, u.time);

            // Radial glow
            float glow = exp(-dist2 / 0.0025) * pulse * occlude * timeFade;

            // On-screen check
            if (bUV.x > 0.01 && bUV.x < 0.99 && bUV.y > 0.01 && bUV.y < 0.99) {
                c += float3(1.0, 0.85, 0.4) * glow * 3.0;
                // Wider soft halo
                c += float3(0.6, 0.4, 0.1) * exp(-dist2 / 0.02) * pulse * occlude * timeFade * 0.5;
            }
        }
    }

    return float4(c, 0);
}
