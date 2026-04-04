// Shaders.metal
// Elevated — Mac/Metal port of the rgba 4KB intro (Breakpoint 2009)
// Original HLSL by iq (Inigo Quilez) + mentor
// Metal translation for educational/personal use

#include <metal_stdlib>
using namespace metal;

using T = texture2d<float>;
constexpr sampler s0(address::repeat, filter::nearest);
constexpr sampler s1(address::clamp_to_edge, filter::linear);

// ─── Uniform layout (matches HLSL q[16] + v) ────────────────────────────────
struct U {
    float4 q[16];
    float4x4 v;       // view-projection matrix
    float4x4 vi;      // inverse view-projection matrix (for ray reconstruction)
    float2 resolution;
    float  time;
    float  _pad;
};

// ─── G-buffer pixel output ───────────────────────────────────────────────────
struct O {
    float4 w [[color(0)]];  // xyz=world pos, w=1 if hit
};

// ─── Vertex shader outputs ───────────────────────────────────────────────────
struct V {
    float4 p [[position]];
    float4 w;  // world-space position
};

struct P {
    float4 p [[position]];
    float2 u;
};

// ────────────────────────────────────────────────────────────────────────────
// NOISE FUNCTIONS
// ────────────────────────────────────────────────────────────────────────────

// no(p) — smooth Perlin noise, returns float3(value, gradient.xy)
// Translated from HLSL: tex2Dlod samples a 256x256 hash texture
float3 no(float2 p, T t0) {
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
float fbm(float2 p, float o, T t0) {
    float2 d = 0;
    float a = 0;
    float bv = 3;
    for (float i = 0; i < o; i++) {
        float3 n = no(0.25*p, t0);
        d += n.yz;
        a += (bv *= 0.5) * n.x / (1 + dot(d, d));
        // HLSL float2x2(a,b,c,d) is row-major; MSL is column-major.
        // HLSL [[1.6,-1.2],[1.2,1.6]] * p = (1.6px-1.2py, 1.2px+1.6py)
        // To get same result in MSL: transpose the constructor args.
        p = float2x2(1.6,1.2,-1.2,1.6) * p;
    }
    return a;
}

// cn(p, e, o) — terrain normal via finite differences
float3 cn(float2 p, float e, float o, constant U& u,
          T t0) {
    float a = fbm(p, o, t0);
    return normalize(float3(
        u.q[2].w*(a - fbm(p+float2(e,0), o, t0)),
        e,
        u.q[2].w*(a - fbm(p+float2(0,e), o, t0))
    ));
}

// b(p, c, d) — sky/diffuse light contribution
float3 sl(float3 p, float3 c, float3 d, constant U& u,
          T t0) {
    float a = dot(d, u.q[3].xyz);
    float bv = mix(a, dot(c, u.q[3].xyz), 0.5 + 0.5*u.q[2].x);
    return float3(.13,.18,.22)*(c.y + 0.25*saturate(-bv) - 0.1*no(1024*p.xz, t0).y)
         + float3(1.4,1,.7)*saturate(bv)*saturate(2*a);
}

// ────────────────────────────────────────────────────────────────────────────
// PASS 1 — TERRAIN VERTEX SHADER (m0)
// Displaces a flat mesh by terrain height
// ────────────────────────────────────────────────────────────────────────────
vertex V a(
    uint i [[vertex_id]],
    constant U& u [[buffer(1)]],
    T t0 [[texture(0)]])
{
    // Procedural XZ from vertex_id — no vertex buffer needed.
    // Non-indexed draw: vertex_id encodes triangle+vertex, matches the CPU index pattern.
    uint tri = i / 3, vert = i % 3, quad = tri / 2, qt = tri % 2;
    uint qx = quad % 1023u, qz = quad / 1023u;
    uint bl = qz * 1024u + qx;
    uint idx[6];
    if (((qx + qz) & 1) == 0) {
        idx[0]=bl; idx[1]=bl+1; idx[2]=bl+1024u;
        idx[3]=bl+1; idx[4]=bl+1025u; idx[5]=bl+1024u;
    } else {
        idx[0]=bl; idx[1]=bl+1; idx[2]=bl+1025u;
        idx[3]=bl; idx[4]=bl+1025u; idx[5]=bl+1024u;
    }
    uint gv = idx[qt * 3 + vert];
    float2 xz = (float2(gv % 1024u, gv / 1024u) / 1023.0 - 0.5) * 104.0;

    float h = u.q[2].w * fbm(xz, 8, t0);
    float4 w = float4(xz.x, h, xz.y, 1);
    V r;
    r.w = w;
    r.p = u.v * w;
    return r;
}

// ────────────────────────────────────────────────────────────────────────────
// PASS 1 — TERRAIN / WATER FRAGMENT SHADER (m2 pass-through → writes G-buffer)
// Stores world position + hit flag into G-buffer
// ────────────────────────────────────────────────────────────────────────────
fragment O b(V i [[stage_in]]) {
    O r;
    r.w = float4(i.w.xyz, 1.0);  // w=1 flags geometry hit
    return r;
}

// ────────────────────────────────────────────────────────────────────────────
// PASS 2 — DEFERRED SHADING (m3)
// Full-screen quad reads G-buffer, shades terrain + sky + water + fog
// ────────────────────────────────────────────────────────────────────────────
vertex P c(uint i [[vertex_id]]) {
    float2 uv = float2((i << 1) & 2, i & 2);
    P r;
    r.p = float4(uv * 2 + float2(-1, -1), 0, 1);
    r.u = float2(uv.x, 1 - uv.y);
    return r;
}

fragment float4 d(
    P i [[stage_in]],
    constant U& u [[buffer(0)]],
    T t0 [[texture(0)]],
    T t1 [[texture(1)]])
{
    float2 x = i.u;
    float2 o = x + 0.5/1280;
    float4 d = t1.sample(s1, o);  // G-buffer world pos

    // Exact m3 style: e = normalize(mul(v, float4(ndc.xy, 1, 1))) where v is inverse(VP).
    // Do not perspective-divide here; the original shader normalizes xyz directly.
    float4 eye4 = u.vi * float4(x.x*2-1, 1-x.y*2, 1, 1);
    float3 e = normalize(eye4.xyz);
    // Preserve sign near the horizon to avoid a hard branch/discontinuity at e.y = 0.
    float ey = (abs(e.y) < 0.001) ? ((e.y < 0.0) ? -0.001 : 0.001) : e.y;
    float2 s = e.xz / ey;

    // Cloud band index
    float k = fmod(2*s.y + 1000, 8);

    // Sky base colour
    float3 c = float3(.55,.65,.75)
        + 0.1 * fbm(s + u.q[3].w*0.2, 10, t0)
        + 0.5 * pow(1-ey, 8)
        + pow(saturate(dot(e, u.q[3].xyz)), 16) * float3(.4,.3,.1)
        + float4(1+0.4*k, 2, 3+0.5*k, 0).xyz
          * (1 - cos(12.5664*s.y))
          * saturate(1 - abs(s.y)/10 - abs(s.x + u.q[5+(int)k].x*0.0012 - 8)/20)
          * exp(-u.q[5+(int)k].x*0.0002);

    if (d.w > 0.5) {
        // d.xyz = world-space position (terrain uses fixed world coords, camera moves via view matrix)
        // Exact port of m3: float t=length(d.xyz-q[4].xyz)
        float t = length(d.xyz - u.q[4].xyz);
        float w = u.q[1].w - d.y;   // water level - surface.y  (< 0 = above water = terrain)

        if (w < 0) {
            // ── TERRAIN — exact m3 port ───────────────────────────────
            float3 n = cn(d.xz, 0.001*t, 12 - log2(t), u, t0);
            float  h = fbm(3*d.xz, 3, t0);
            float  r = no(666*d.xz, t0).x;

            c = (0.1 + 0.75*u.q[2].x) * (0.8 + 0.2*r);
            c = mix(c,
                    mix(float3(.8,.85,.9), float3(.45,.45,.2)*(0.8+0.2*r), u.q[2].x),
                    smoothstep(0.5 - 0.8*n.y, 1 - 1.1*n.y, h*0.15));
            c = mix(c,
                    mix(float3(.37,.23,.08), float3(.42,.4,.2), u.q[2].x) * (0.5+0.5*r),
                    smoothstep(0, 1, 50*(n.y-1) + (h+u.q[2].x)/0.4));
            // b(d, n, cn(d.xz,...)) — pass world position d
            c *= sl(d.xyz, n, cn(d.xz, 0.001*t, 5, u, t0), u, t0);

        } else {
            // ── WATER — exact m3 port ─────────────────────────────────
            // t=(q[1].w-q[4].y)/e.y; d=q[4]+e.xyzz*t
            t = (u.q[1].w - u.q[4].y) / e.y;
            d.xyz = u.q[4].xyz + e * t;   // world position of water hit
            float2 wXZ = d.xz;
            float3 n = normalize(cn(float2(512,32)*wXZ
                                    + saturate(w*60)*float2(u.q[3].w, 0),
                                    0.001*t, 4, u, t0) * float3(1,6,1));

            c = 0.12 * (float3(.4,1,1) - float3(.2,.6,.4)*saturate(w*16));
            c *= 0.3 + 0.7*u.q[2].x;
            c += pow(1 - dot(-e, n), 4)
               * (pow(saturate(dot(u.q[3].xyz, reflect(-e,n))), 32) * float3(.32,.31,.3) + 0.1);
            c = mix(c,
                    sl(d.xyz, n, n, u, t0),
                    smoothstep(1, 0,
                        u.q[2].x + w*60
                        - fbm(666*wXZ + saturate(w*60)*float2(u.q[3].w,0)*2, 5, t0)) * 0.5);
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
fragment float4 e(
    P i [[stage_in]],
    constant U& u [[buffer(0)]],
    T t0 [[texture(0)]],   // noise texture
    T t1 [[texture(1)]],   // G-buffer
    T t2 [[texture(2)]])   // scene color
{
    float2 o = i.u + 0.5/1280;
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

    float w = t0.sample(s0, o + float2(u.q[3].w * 0.1, 0)).r - 0.5;
    c += w * 0.01;

    return float4(c, 0);
}
