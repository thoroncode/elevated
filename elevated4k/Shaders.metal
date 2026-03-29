// Shaders.metal
// Elevated — Mac/Metal port of the rgba 4KB intro (Breakpoint 2009)
// Original HLSL by iq (Inigo Quilez) + mentor
// Metal translation for educational/personal use

#include <metal_stdlib>
using namespace metal;

using T = texture2d<float>;
constexpr sampler A(address::repeat, filter::nearest);
constexpr sampler B(address::clamp_to_edge, filter::linear);

// ─── Uniform layout (matches HLSL q[16] + v) ────────────────────────────────
struct U {
    float4 q[16];
    float4x4 v;       // view-projection matrix
    float4x4 vi;      // inverse view-projection matrix (for ray reconstruction)
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

// h(p) — smooth Perlin noise, returns float3(value, gradient.xy)
// Translated from HLSL: tex2Dlod samples a 256x256 hash texture
float3 h(float2 p, T t0) {
    float2 f = fract(p);
    float2 u = f*f*f*(f*(f*6-15)+10);  // quintic smoothstep
    float a = t0.sample(A, (floor(p)+float2(0,0))/256, level(0)).r;
    float b = t0.sample(A, (floor(p)+float2(1,0))/256, level(0)).r;
    float c = t0.sample(A, (floor(p)+float2(0,1))/256, level(0)).r;
    float d = t0.sample(A, (floor(p)+float2(1,1))/256, level(0)).r;
    return float3(
        a+(b-a)*u.x+(c-a)*u.y+(a-b-c+d)*u.x*u.y,
        30*f*f*(f*(f-2)+1)*(float2(b-a,c-a)+(a-b-c+d)*u.yx)
    );
}

// m(p, o) — FBM terrain, o octaves, domain rotation + derivative damping
float m(float2 p, float o, T t0) {
    float2 d = 0;
    float a = 0;
    float bv = 3;
    for (float i = 0; i < o; i++) {
        float3 n = h(0.25*p, t0);
        d += n.yz;
        a += (bv *= 0.5) * n.x / (1 + dot(d, d));
        // HLSL float2x2(a,b,c,d) is row-major; MSL is column-major.
        // HLSL [[1.6,-1.2],[1.2,1.6]] * p = (1.6px-1.2py, 1.2px+1.6py)
        // To get same result in MSL: transpose the constructor args.
        p = float2x2(1.6,1.2,-1.2,1.6) * p;
    }
    return a;
}

// j(p, e, o) — terrain normal via finite differences
float3 j(float2 p, float e, float o, constant U& u,
          T t0) {
    float a = m(p, o, t0);
    return normalize(float3(
        u.q[2].w*(a - m(p+float2(e,0), o, t0)),
        e,
        u.q[2].w*(a - m(p+float2(0,e), o, t0))
    ));
}

// l(p, c, d) — sky/diffuse light contribution
float3 l(float3 p, float3 c, float3 d, constant U& u,
          T t0) {
    float a = dot(d, u.q[3].xyz);
    float b = mix(a, dot(c, u.q[3].xyz), 0.5 + 0.5*u.q[2].x);
    return float3(.13,.18,.22)*(c.y + 0.25*saturate(-b) - 0.1*h(1024*p.xz, t0).y)
         + float3(1.4,1,.7)*saturate(b)*saturate(2*a);
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
    uint r = i / 3, v = i % 3, q = r / 2, t = r % 2;
    uint x = q % 1023u, z = q / 1023u;
    uint b = z * 1024u + x;
    uint j[6];
    if (((x + z) & 1) == 0) {
        j[0]=b; j[1]=b+1; j[2]=b+1024u;
        j[3]=b+1; j[4]=b+1025u; j[5]=b+1024u;
    } else {
        j[0]=b; j[1]=b+1; j[2]=b+1025u;
        j[3]=b; j[4]=b+1025u; j[5]=b+1024u;
    }
    uint g = j[t * 3 + v];
    float2 xz = (float2(g % 1024u, g / 1024u) / 1023.0 - 0.5) * 104.0;

    float h = u.q[2].w * m(xz, 8, t0);
    float4 w = float4(xz.x, h, xz.y, 1);
    return V{u.v * w, w};
}

// ────────────────────────────────────────────────────────────────────────────
// PASS 1 — TERRAIN / WATER FRAGMENT SHADER (m2 pass-through → writes G-buffer)
// Stores world position + hit flag into G-buffer
// ────────────────────────────────────────────────────────────────────────────
fragment float4 b(V i [[stage_in]]) {
    return float4(i.w.xyz, 1.0);  // w=1 flags geometry hit
}

// ────────────────────────────────────────────────────────────────────────────
// PASS 2 — FULLSCREEN SHADING HELPER
// Reads the G-buffer and reconstructs the shaded scene color for one sample.
// ────────────────────────────────────────────────────────────────────────────
vertex P c(uint i [[vertex_id]]) {
    float2 u = float2((i << 1) & 2, i & 2);
    return P{float4(u * 2 + float2(-1, -1), 0, 1), float2(u.x, 1 - u.y)};
}

float3 f(float2 o, constant U& u, T t0, T t1)
{
    float2 x = o - 0.5/1280;
    float4 g = t1.sample(B, o);  // G-buffer world pos

    // Exact m3 style: e = normalize(mul(v, float4(ndc.xy, 1, 1))) where v is inverse(VP).
    // Do not perspective-divide here; the original shader normalizes xyz directly.
    float3 e = normalize((u.vi * float4(x.x*2-1, 1-x.y*2, 1, 1)).xyz);
    // Preserve sign near the horizon to avoid a hard branch/discontinuity at e.y = 0.
    float ey = (abs(e.y) < 0.001) ? ((e.y < 0.0) ? -0.001 : 0.001) : e.y;
    float2 s = e.xz / ey;

    // Cloud band index
    float k = fmod(2*s.y + 1000, 8);
    float3 p = u.q[3].xyz, q = u.q[4].xyz;
    float v = u.q[2].x, y = u.q[5+(int)k].x, z = u.q[3].w;

    // Sky base colour
    float3 c = float3(.55,.65,.75)
        + 0.1 * m(s + z*0.2, 10, t0)
        + 0.5 * pow(1-ey, 8)
        + pow(saturate(dot(e, p)), 16) * float3(.4,.3,.1)
        + float3(1+0.4*k, 2, 3+0.5*k)
          * (1 - cos(12.5664*s.y))
          * saturate(1 - abs(s.y)/10 - abs(s.x + y*0.0012 - 8)/20)
          * exp(-y*0.0002);

    if (g.w > 0.5) {
        // g.xyz = world-space position (terrain uses fixed world coords, camera moves via view matrix)
        // Exact port of m3: float t=length(g.xyz-q[4].xyz)
        float t = length(g.xyz - q);
        float w = u.q[1].w - g.y;   // water level - surface.y  (< 0 = above water = terrain)

        if (w < 0) {
            // ── TERRAIN — exact m3 port ───────────────────────────────
            float3 n = j(g.xz, 0.001*t, 12 - log2(t), u, t0);
            float  a = m(3*g.xz, 3, t0);
            float  r = h(666*g.xz, t0).x;

            c = (0.1 + 0.75*v) * (0.8 + 0.2*r);
            c = mix(c,
                    mix(float3(.8,.85,.9), float3(.45,.45,.2)*(0.8+0.2*r), v),
                    smoothstep(0.5 - 0.8*n.y, 1 - 1.1*n.y, a*0.15));
            c = mix(c,
                    mix(float3(.37,.23,.08), float3(.42,.4,.2), v) * (0.5+0.5*r),
                    smoothstep(0, 1, 50*(n.y-1) + (a+v)/0.4));
            // b(g, n, j(g.xz,...)) — pass world position g
            c *= l(g.xyz, n, j(g.xz, 0.001*t, 5, u, t0), u, t0);

        } else {
            // ── WATER — exact m3 port ─────────────────────────────────
            // t=(q[1].w-q[4].y)/e.y; g=q[4]+e.xyzz*t
            t = (u.q[1].w - q.y) / e.y;
            g.xyz = q + e * t;   // world position of water hit
            float2 x = g.xz;
            float a = saturate(w*60);
            float3 n = normalize(j(float2(512,32)*x
                                    + a*float2(z, 0),
                                    0.001*t, 4, u, t0) * float3(1,6,1));

            c = 0.12 * (float3(.4,1,1) - float3(.2,.6,.4)*saturate(w*16));
            c *= 0.3 + 0.7*v;
            c += pow(1 - dot(-e, n), 4)
               * (pow(saturate(dot(p, reflect(-e,n))), 32) * float3(.32,.31,.3) + 0.1);
            c = mix(c,
                    l(g.xyz, n, n, u, t0),
                    smoothstep(1, 0,
                        v + w*60
                        - m(666*x + a*float2(z,0)*2, 5, t0)) * 0.5);
        }

        c *= 0.7 + 0.3*smoothstep(0, 1, 256*abs(w));
        c *= exp(-0.042*t);
        c += (1 - exp(-0.1*t)) * (float3(.52,.59,.65) + pow(saturate(dot(e, p)), 8)*float3(.6,.4,.1));
    }

    return c;
}

// ────────────────────────────────────────────────────────────────────────────
// PASS 2 — FUSED DEFERRED SHADING + POST (m4)
// Shades from the G-buffer and post-processes directly into the drawable.
// ────────────────────────────────────────────────────────────────────────────
fragment float4 e(
    P i [[stage_in]],
    constant U& u [[buffer(0)]],
    T t0 [[texture(0)]],   // noise texture
    T t1 [[texture(1)]])   // G-buffer
{
    float2 o = i.u + 0.5/1280;
    float4 d = t1.sample(B, o);
    float3 c = f(o, u, t0, t1);

    if (d.w > 0.5) {
        // Motion blur: reproject world pos to clip, sample along motion vector
        float4 p = u.v * float4(d.xyz, 1);
        p.y *= -1;
        float2 m = 0.5 + 0.5*p.xy/p.w - o;
        c *= 0.5;
        c += 0.3 * f(o + 0.5 * m,  u, t0, t1);
        c += 0.2 * f(o +       m,  u, t0, t1);
    }

    // Gamma + brightness/contrast
    c = pow(c, 0.45) * u.q[2].z + u.q[2].y;

    // Vignette
    c *= 0.4 + 9.6*o.x*o.y*(1-o.x)*(1-o.y);

    // Chromatic aberration (subtle red/blue shift)
    c.xz *= 0.98;

    // Film grain
    float w = t0.sample(A, u.q[3].w * 0.1).r;
    o += w;
    c -= 0.005*w;
    c.x += 0.01 * t0.sample(A, o + float2(0.1, 0)).r;
    c.y += 0.01 * t0.sample(A, o + float2(0.2, 0)).r;
    c.z += 0.01 * t0.sample(A, o + float2(0.3, 0)).r;

    return float4(c, 0);
}
