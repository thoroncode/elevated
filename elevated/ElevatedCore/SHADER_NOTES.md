# Shader Notes

This note documents the shared Metal shader in [Shaders.metal](/tmp/elevated-intro-50k/elevated/ElevatedCore/Shaders.metal), how it interacts with the runtime, and which parts are structurally important versus mostly representational.

## Pipeline Overview

The port keeps the original intro structure:

| Pass | Entry points | Purpose |
|------|--------------|---------|
| Pass 1 | `a`, `b` | Displace terrain mesh and write a world-position G-buffer |
| Pass 2 | `c`, `d` | Fullscreen deferred shading: sky, terrain, water, fog |
| Pass 3 | `c`, `e` | Fullscreen post: motion blur, grading, vignette, aberration, grain |

The fullscreen vertex shader `c` is reused by both fullscreen passes.

## Runtime Inputs

The shader depends on three categories of input prepared on the CPU:

1. Uniform block `U`
2. A fixed 256x256 scalar noise texture
3. Render targets from the previous pass

In the 4k path, the inputs are assembled in [main.m](/tmp/elevated-intro-50k/elevated4k/main.m). In the shared app path they are assembled in [Renderer.swift](/tmp/elevated-intro-50k/elevated/ElevatedCore/Renderer.swift).

### Uniform Block `U`

`U` is the Metal equivalent of the original HLSL `q[16]` plus view/projection data.

Important slots:

| Field | Meaning |
|------|---------|
| `q[0]` | Camera seed X/Y, camera speed, FOV |
| `q[1]` | Camera height controls, sun angle, water level |
| `q[2]` | Season blend, post brightness, post contrast/gamma scale, terrain height scale |
| `q[3]` | Sun direction XYZ, time in seconds |
| `q[4]` | Camera world position |
| `q[5]..q[12]` | Cloud band parameters from music sync |
| `v` | View-projection matrix |
| `vi` | Inverse view-projection matrix |

Two details matter for simplification work:

- `vi` is already precomputed on CPU. The shader does not invert matrices anymore.
- The shader uses `q` slots in the same style as the original HLSL, so many formulas still read like compact data-driven demo code instead of modern engine code.

### Noise Texture

The noise texture is generated on the CPU and uploaded once:

- 256x256
- `R32Float`
- repeat addressing
- nearest sampling

This is important because the helper `no()` is not generic procedural noise. It is specifically a smoothed lookup over that hash texture. Any rewrite of `no()` has to preserve:

- repeat wrapping
- exact texel neighborhood
- `level(0)` behavior
- the same quintic interpolation

That makes the noise path a high-value optimization target, but also an easy place to introduce subtle visual drift.

## Pass Details

### Pass 1: Terrain G-buffer

#### `vertex V a(...)`

`a` takes a flat terrain mesh in XZ and displaces it vertically by FBM:

- input mesh is world-space XZ
- height is `q[2].w * fbm(xz, 8, noiseTex)`
- output `V.w` carries world position forward
- output `V.p` is clip-space via `u.v * world`

This pass does not shade anything. It only constructs terrain geometry.

#### `fragment O b(...)`

`b` writes the world-space position to the G-buffer:

- `rgb` = world position
- `a`/`w` = hit flag

This is intentionally minimal. There is no albedo buffer, normal buffer, or material buffer. Deferred shading reconstructs almost everything later from world position plus the same noise functions.

### Pass 2: Deferred Shading

#### `vertex P c(...)`

`c` builds the fullscreen triangle.

This is one of the safer areas to simplify because it only generates the standard oversized triangle and UVs. It has no artistic meaning by itself.

#### `fragment float4 d(...)`

`d` is the real visual core of the intro. It shades:

- sky
- cloud bands
- terrain surface
- water surface
- atmospheric fog

The pass starts by reading the world-position G-buffer and reconstructing the view ray from `u.vi`.

If `d.w <= 0.5`, the ray missed geometry and the shader returns sky.

If `d.w > 0.5`, the pass shades either terrain or water:

- `w = waterLevel - surfaceY`
- `w < 0` means terrain branch
- `w >= 0` means water branch

#### Terrain branch

The terrain branch computes:

- detailed normal from `cn()`
- extra low-frequency terrain variation from `fbm()`
- a high-frequency randomization term from `no()`
- layered color blends that create snow/rock/soil transitions
- lighting via `sl()`
- distance fog

This branch is visually sensitive. Most of the scene identity comes from these blends plus the camera path.

#### Water branch

The water branch:

- intersects the view ray with the water plane
- synthesizes a water normal from the same terrain/noise helpers
- adds Fresnel-like brightening and reflection/specular response
- blends toward skylight
- adds fog

This branch is also visually sensitive, especially around horizon and shoreline transitions.

### Pass 3: Post

#### `fragment float4 e(...)`

`e` applies:

- 16-sample motion blur when geometry exists
- gamma/contrast/brightness shaping
- vignette
- subtle chromatic aberration
- film grain from the noise texture

This pass changes the look a lot with fairly little code. It is a strong artistic multiplier, so even small math changes can be very noticeable.

For this repo specifically, side-by-side live review showed that film-grain simplifications can
look wrong even when frame diffs and binary-size numbers look acceptable. A screen-space shortcut
produced a drifting overlay, and a milder approximation still felt blinkier/less stable than the
original. Treat the grain path as artistically locked unless a candidate survives motion review.

## Helper Functions

### `no()`

Returns:

- `x`: scalar noise value
- `y/z`: gradient components

It is a bilinear/quintic-smoothed lookup over the CPU-generated hash texture.

### `fbm()`

Builds terrain-like fractal height using:

- repeated `no()` calls
- derivative accumulation
- damping by `1 / (1 + dot(d, d))`
- fixed domain rotation

That derivative damping is part of the look. Removing it changes the terrain character.

### `cn()`

Computes terrain normal by finite differences over `fbm()`.

It is expensive, but it tightly matches the terrain definition. Replacing it with a different approximation is likely visible.

### `sl()`

Computes sky/diffuse contribution using:

- sun direction from `q[3].xyz`
- season blend from `q[2].x`
- additional high-frequency modulation from `no()`

This is not just a generic Lambert term. It is part of the stylized palette of the intro.

## What Is Safe To Simplify

These are good candidates for exact or near-exact reductions:

- Shared sampler and type aliases
- Shader source representation and minification
- Helper signatures that carry redundant parameters
- Fullscreen triangle generation in `c`
- CPU-side precomputation when it matches current shader semantics exactly

These are structurally important and should be treated as look-defining:

- `no()` sampling behavior
- `fbm()` recurrence and domain rotation
- terrain color layering in `d`
- water normal/reflection logic in `d`
- post chain in `e`
- especially the film-grain behavior inside `e`

## Why The G-buffer Is So Small

The current port stores only world position plus a hit flag. That is deliberate:

- normals are recomputed procedurally
- terrain and water material color are procedural
- the scene stays compact because most information is implicit

This is one of the biggest reasons the shader looks dense. It is compressing what would normally be many buffers and many authored assets into a single procedural reconstruction pass.

## Practical Optimization Guidance

For size work, the best order is:

1. Reduce representation overhead first
2. Move exact work to CPU when it does not alter formulas
3. Only then touch look-defining math

In practice, the easiest safe wins so far have come from:

- reducing the source representation of the shader
- sharing samplers and types
- removing redundant parameter plumbing

The next risky-but-promising area is the noise lookup path, because it is used everywhere and repeats a lot of syntax.
