// Renderer.swift
// Elevated — Metal renderer
// 3-pass pipeline: G-buffer → deferred shading → post-processing

import Metal
import MetalKit
import simd

// ─── Uniforms mirror of Shaders.metal struct ─────────────────────────────────
struct Uniforms {
    var q: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,   // q[0..3]
            SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,   // q[4..7]
            SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,   // q[8..11]
            SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)   // q[12..15]
    var v: simd_float4x4
    var vi: simd_float4x4  // inverse view-projection
    var resolution: SIMD2<Float>
    var time: Float
    var _pad: Float

    // Convenience accessor
    mutating func setQ(_ i: Int, _ val: SIMD4<Float>) {
        withUnsafeMutableBytes(of: &q) { ptr in
            ptr.storeBytes(of: val, toByteOffset: i * MemoryLayout<SIMD4<Float>>.stride,
                           as: SIMD4<Float>.self)
        }
    }
    func getQ(_ i: Int) -> SIMD4<Float> {
        return withUnsafeBytes(of: q) { ptr in
            ptr.loadUnaligned(fromByteOffset: i * MemoryLayout<SIMD4<Float>>.stride,
                              as: SIMD4<Float>.self)
        }
    }
}

// ─── Animation keyframes (decoded from original binary spline data) ────────────
// Each keyframe: [time_seconds, q0x,q0y,q0z,q0w, q1x,q1y,q1z,q1w, q2x,q2y,q2z,q2w]
// q[0]: water wave offset.xy, time_scale.z, misc.w
// q[1]: terrain_offset.xy, sun_angle_rad.z, water_level.w
// q[2]: season_snow.x, post_brightness.y, post_gamma_scale.z, terrain_height_scale.w
// q[3] is derived: (cos(q1.z), 0.3125, sin(q1.z), time) — sun direction + time
let animKeyframes: [[Float]] = [
//  time      q0.x   q0.y   q0.z    q0.w    q1.x    q1.y    q1.z    q1.w    q2.x   q2.y   q2.z   q2.w
    [  0.0,  0.383, 0.000, 0.0002, 0.552,  0.062,-24.000, 2.000, -0.297,  0.000,-1.000, 1.172, 0.562],
    [  3.8,  0.383, 0.000, 0.0002, 0.552,  0.062,-24.000, 2.000, -0.297,  0.000, 0.000, 1.172, 0.562],
    [  7.6,  0.020, 0.000, 0.0002, 1.667,  2.000, 31.750, 2.000, -0.297,  0.000, 0.000, 1.172, 0.562],
    [ 12.3,  0.020, 0.000, 0.0002, 0.083,  0.141,  0.000, 2.812,  0.062,  0.000,-0.141, 1.172, 0.094],
    [ 15.1,  0.066, 0.000, 0.0002, 0.083,  0.062,  0.000, 1.000, -1.500,  0.000,-0.141, 1.172, 0.562],
    [ 20.8,  0.441, 0.000, 0.0002, 0.083,  0.078,  0.000, 1.000, -1.500,  0.000,-0.141, 1.172, 0.562],
    [ 26.5,  0.422, 0.000, 0.0002, 0.083,  0.078,  0.000, 1.000, -1.500,  0.000,-0.141, 1.172, 0.562],
    [ 29.3,  0.070, 0.000, 0.0002, 0.042,  0.078,  0.000, 1.750, -1.500,  0.000,-0.750, 1.953, 0.562],
    [ 34.0,  0.035, 0.000, 0.0002, 0.042,  0.219, -0.250, 5.000, -0.172,  0.000,-0.297, 1.406, 0.562],
    [ 35.4,  0.035, 0.000, 0.0002, 0.021,  0.219, -0.250, 5.000, -0.172,  0.000,-0.297, 1.406, 0.562],
    [ 37.8,  0.410, 0.000, 0.0002, 0.208,  0.219, -0.250, 2.000, -0.172,  0.000,-0.297, 1.406, 0.562],
    [ 39.2,  0.410, 0.000, 0.0002, 0.125,  0.219, -0.250, 2.000, -0.172,  0.000,-0.297, 1.406, 0.562],
    [ 41.6,  0.023, 0.000, 0.0002, 0.083,  0.500,  0.000, 5.000, -0.172,  0.000,-0.297, 1.406, 0.562],
    [ 43.5,  0.395, 0.000, 0.0012, 0.625,  0.125,  0.000, 5.625, -1.500,  0.000,-0.141, 0.000, 0.562],
    [ 48.2,  0.395, 0.000, 0.0012, 0.625,  0.125,  0.000, 5.625, -1.500,  0.000,-0.141, 1.250, 0.562],
    [ 49.1,  0.727, 0.000, 0.0010, 0.625,  0.125,  0.000, 4.375, -1.500,  0.000,-0.141, 1.250, 0.562],
    [ 56.7,  0.047, 0.000, 0.0010, 0.250,  0.125,  0.000, 5.156, -1.500,  0.000, 0.000, 1.000, 0.992],
    [ 66.2,  0.316, 0.000, 0.0059, 0.188,  1.250, -5.500, 3.438, -1.500,  0.000,-0.297, 1.484, 0.992],
    [ 70.9,  0.383, 0.004, 0.0142, 0.292,  2.188, -5.000, 2.500, -1.500,  0.000,-0.297, 1.484, 0.992],
    [ 75.6,  0.383, 0.004, 0.0142, 0.292,  2.188, -5.000, 2.500, -1.500,  0.000,-0.297, 1.484, 0.992],
    [ 78.9,  0.383, 0.004, 0.0142, 0.292,  2.188, -5.000, 2.500, -1.500,  0.000,-1.000, 1.016, 0.992],
    [ 79.4,  0.598, 0.004, 0.0212, 0.500,  0.250, -3.250, 3.281, -0.562,  0.000, 0.000, 1.250, 0.992],
    [ 92.6,  0.445, 0.004, 0.0623, 1.667,  0.125,  0.000, 1.562, -0.250,  0.000,-0.062, 1.094, 0.992],
    [100.2,  0.188, 0.004, 0.0623, 1.250,  0.125,  0.000, 1.562, -1.188,  0.000,-0.062, 1.094, 0.992],
    [107.7,  0.324, 0.004, 0.0459, 0.667,  0.125,  0.000, 0.312, -1.188,  0.000,-0.180, 1.406, 0.992],
    [118.1,  0.324, 0.004, 0.0459, 0.667,  0.125,  0.000, 0.312, -1.188,  0.000,-0.180, 1.406, 0.992],
    [118.6,  0.324, 0.004, 0.0459, 0.667,  0.125,  0.000, 0.312, -1.188,  0.000, 0.000, 1.406, 0.992],
    [122.9,  0.043, 0.004, 0.0623, 1.333,  0.125,  0.000, 4.688, -1.188,  0.000,-0.219, 1.406, 0.719],
    [126.6,  0.031, 0.004, 0.0623, 1.333,  0.062, 18.000, 4.688, -1.188,  0.000,-0.219, 1.406, 0.719],
    [130.4,  0.086, 0.004, 0.0623, 1.333,  0.250,  0.000, 2.656, -1.188,  0.000,-0.219, 1.406, 0.719],
    [138.0,  0.043, 0.004, 0.0039, 0.552,  0.250,  0.000, 2.000, -1.188,  0.000,-0.219, 0.000, 0.992],
    [138.5,  0.043, 0.004, 0.0039, 0.552,  0.250,  0.000, 2.000, -1.188,  0.000,-0.219, 1.484, 0.992],
    [141.8,  0.043, 0.004, 0.0039, 0.552,  0.750, -4.250, 2.000, -1.188,  0.250,-0.219, 1.484, 0.992],
    [145.5,  0.012, 0.000, 0.0156, 0.552,  2.969,-12.000, 5.312, -0.094,  0.500,-0.812, 1.992, 0.992],
    [152.2,  0.012, 0.000, 0.0156, 0.552,  2.969,-12.000, 5.312, -0.094,  0.996,-0.812, 1.992, 0.992],
    [155.0,  0.035, 0.000, 0.0437, 1.250,  0.219,-12.000, 3.125, -0.094,  0.996,-0.062, 1.172,-0.844],
    [162.6,  0.195, 0.004, 0.0437, 1.250,  0.312, -7.000, 5.312, -1.500,  0.996,-0.062, 1.172,-0.844],
    [170.1,  0.004, 0.000, 0.0552, 1.250,  0.219, -2.000, 0.000,  0.008,  0.996,-0.141, 1.328, 0.797],
    [185.2,  0.488, 0.000, 0.0073, 1.250,  0.219, -2.000, 1.094, -0.172,  0.996,-0.219, 1.406, 0.797],
    [200.4,  0.488, 0.000, 0.0073, 1.250,  0.219, -2.000, 1.094, -0.172,  0.000,-0.219, 1.406, 0.797],
    [211.7,  0.488, 0.000, 0.0073, 1.250,  0.219, -2.000, 1.094, -0.172,  0.000,-1.000, 1.000, 0.797],
    [332.2,  0.488, 0.000, 0.0073, 1.250,  0.219, -2.000, 1.094, -0.172,  0.000,-1.000, 1.000, 0.797],
]

// Returns interpolated 12 q-values [q0.xyzw, q1.xyzw, q2.xyzw] for time t
func lerpAnimKeyframe(t: Float) -> [Float] {
    let n = animKeyframes.count
    guard n > 1 else { return Array(animKeyframes[0].dropFirst()) }
    for i in 0..<n-1 {
        let k0 = animKeyframes[i], k1 = animKeyframes[i+1]
        if t >= k0[0] && t < k1[0] {
            let s = (t - k0[0]) / (k1[0] - k0[0])
            return (1...12).map { j in k0[j] + (k1[j] - k0[j]) * s }
        }
    }
    return Array(animKeyframes[n-1].dropFirst())
}

// ─── Camera keyframes (matches the original fly-through feel) ────────────────
struct CameraKey {
    var time: Float
    var pos: SIMD3<Float>
    var target: SIMD3<Float>
}

// Camera path derived from q[0].xy keyframe data (camera XZ in world units ≈ q[0].xy*32).
// q[0].y is mostly 0 so motion is primarily in X; Z offsets add depth variety.
// Altitude: 0.4-0.9 above typical terrain height (terrain scale ~0.56 → peaks ~1.7).
// q[4].xz will hold camera world XZ; the view matrix uses eye at (0, camPos.y, 0).
let cameraPath: [CameraKey] = [
//   time   pos (world XZ drives terrain sampling)             look-at target
    CameraKey(time:   0, pos: SIMD3(12.3, 1.3,   0), target: SIMD3( 8.0, 0.9,  6)),
    CameraKey(time:   4, pos: SIMD3(12.3, 1.0,   0), target: SIMD3( 8.0, 0.7,  5)),   // fade in
    CameraKey(time:   8, pos: SIMD3( 0.6, 1.5,  -2), target: SIMD3( 6.0, 1.0,  4)),   // cut
    CameraKey(time:  12, pos: SIMD3( 0.6, 1.2,  -2), target: SIMD3( 5.0, 0.8,  3)),
    CameraKey(time:  15, pos: SIMD3( 2.1, 1.4,   2), target: SIMD3( 8.0, 0.9,  6)),
    CameraKey(time:  21, pos: SIMD3(14.1, 1.3,   2), target: SIMD3(10.0, 0.8,  7)),
    CameraKey(time:  27, pos: SIMD3(13.5, 1.2,   2), target: SIMD3( 9.0, 0.8,  7)),
    CameraKey(time:  29, pos: SIMD3( 2.2, 2.0,   2), target: SIMD3(-2.0, 1.6,  8)),   // high view
    CameraKey(time:  34, pos: SIMD3( 1.1, 1.6,   0), target: SIMD3( 7.0, 1.1,  6)),
    CameraKey(time:  35, pos: SIMD3( 0.7, 1.5,   0), target: SIMD3( 5.0, 1.0,  5)),
    CameraKey(time:  38, pos: SIMD3(13.1, 1.4,   2), target: SIMD3( 8.0, 0.9,  7)),
    CameraKey(time:  40, pos: SIMD3(13.1, 1.3,   2), target: SIMD3( 7.0, 0.8,  7)),
    CameraKey(time:  42, pos: SIMD3( 0.7, 1.6,   0), target: SIMD3(-4.0, 1.2,  6)),
    CameraKey(time:  44, pos: SIMD3(12.6, 1.5,  -4), target: SIMD3( 4.0, 1.0,  4)),   // water fly
    CameraKey(time:  48, pos: SIMD3(12.6, 1.3,  -4), target: SIMD3( 4.0, 0.8,  4)),
    CameraKey(time:  49, pos: SIMD3(23.3, 1.4,  -2), target: SIMD3(16.0, 1.0,  5)),
    CameraKey(time:  57, pos: SIMD3( 1.5, 1.5,   2), target: SIMD3( 8.0, 1.1,  8)),
    CameraKey(time:  66, pos: SIMD3(10.1, 1.6,   2), target: SIMD3( 5.0, 1.3,  8)),   // dusk
    CameraKey(time:  71, pos: SIMD3(12.3, 1.5,   4), target: SIMD3( 6.0, 1.2, 10)),
    CameraKey(time:  76, pos: SIMD3(12.3, 1.4,   4), target: SIMD3( 6.0, 1.1, 10)),
    CameraKey(time:  79, pos: SIMD3(19.1, 0.9,  -4), target: SIMD3(10.0, 0.5,  4)),   // low valley
    CameraKey(time:  93, pos: SIMD3(14.2, 1.1,   0), target: SIMD3( 7.0, 2.0, -7)),   // beacon view
    CameraKey(time: 100, pos: SIMD3( 6.0, 1.8,   2), target: SIMD3( 5.5, 2.5, -6)),   // up at beacon
    CameraKey(time: 108, pos: SIMD3(10.4, 1.6,   4), target: SIMD3( 3.0, 0.8, -2)),
    CameraKey(time: 118, pos: SIMD3(10.4, 1.5,   4), target: SIMD3( 3.0, 0.8, -2)),
    CameraKey(time: 119, pos: SIMD3(10.4, 1.2,   2), target: SIMD3( 4.0, 0.8, -4)),
    CameraKey(time: 123, pos: SIMD3( 1.4, 1.8,  -4), target: SIMD3( 4.0, 1.4, -8)),   // approach
    CameraKey(time: 127, pos: SIMD3( 1.0, 1.4,  -4), target: SIMD3( 4.5, 1.5, -8)),
    CameraKey(time: 130, pos: SIMD3( 2.8, 1.6,  -4), target: SIMD3( 5.5, 1.8, -9)),
    CameraKey(time: 138, pos: SIMD3( 1.4, 1.3,  -2), target: SIMD3( 4.0, 0.9, -6)),   // fade
    CameraKey(time: 139, pos: SIMD3( 1.4, 1.4,  -2), target: SIMD3( 5.0, 1.2, -6)),
    CameraKey(time: 142, pos: SIMD3( 1.4, 2.0,   6), target: SIMD3( 8.0, 1.5, 10)),   // lift
    CameraKey(time: 146, pos: SIMD3( 0.4, 1.6,  10), target: SIMD3(16.0, 1.0, 16)),   // wide
    CameraKey(time: 152, pos: SIMD3( 0.4, 1.5,  10), target: SIMD3(16.0, 0.9, 16)),
    CameraKey(time: 155, pos: SIMD3( 1.1, 2.2,  -6), target: SIMD3( 7.0, 1.5, -2)),   // winter
    CameraKey(time: 163, pos: SIMD3( 6.2, 2.0,  -6), target: SIMD3(10.0, 1.3,  2)),
    CameraKey(time: 170, pos: SIMD3( 0.1, 1.8,   0), target: SIMD3( 7.0, 0.0,  0)),   // sunset
    CameraKey(time: 185, pos: SIMD3(15.6, 2.0,  -2), target: SIMD3( 7.0, 0.5,  4)),
    CameraKey(time: 200, pos: SIMD3(15.6, 1.8,  -2), target: SIMD3( 7.0, 0.3,  4)),
    CameraKey(time: 212, pos: SIMD3(15.6, 1.5,  -2), target: SIMD3( 7.0, 0.0,  4)),
    CameraKey(time: 217, pos: SIMD3(15.6, 1.0,  -2), target: SIMD3( 7.0,-0.5,  4)),   // fade out
]

func interpolateCamera(time t: Float) -> (pos: SIMD3<Float>, target: SIMD3<Float>) {
    let keys = cameraPath
    guard keys.count > 1 else { return (keys[0].pos, keys[0].target) }
    for i in 0..<keys.count-1 {
        let k0 = keys[i], k1 = keys[i+1]
        if t >= k0.time && t <= k1.time {
            let s = (t - k0.time) / (k1.time - k0.time)
            let ss = s*s*(3-2*s)  // smoothstep
            return (mix(k0.pos, k1.pos, t: ss), mix(k0.target, k1.target, t: ss))
        }
    }
    let last = keys.last!
    return (last.pos, last.target)
}

// ─── Terrain mesh generation ──────────────────────────────────────────────────
/// Flat grid in XZ, centered at origin. Metal displaces Y in vertex shader.
func makeTerrainMesh(device: MTLDevice, size: Int = 256, scale: Float = 64)
    -> (vbuf: MTLBuffer, ibuf: MTLBuffer, indexCount: Int)
{
    var verts = [SIMD2<Float>]()
    var indices = [UInt32]()
    verts.reserveCapacity(size * size)
    indices.reserveCapacity(size * size * 6)

    for z in 0..<size {
        for x in 0..<size {
            let fx = (Float(x) / Float(size-1) - 0.5) * scale
            let fz = (Float(z) / Float(size-1) - 0.5) * scale
            verts.append(SIMD2(fx, fz))
        }
    }
    for z in 0..<size-1 {
        for x in 0..<size-1 {
            let i = UInt32(z*size + x)
            indices += [i, i+1, i+UInt32(size), i+1, i+UInt32(size)+1, i+UInt32(size)]
        }
    }

    let vbuf = device.makeBuffer(bytes: verts,
                                  length: verts.count * MemoryLayout<SIMD2<Float>>.stride,
                                  options: .storageModeShared)!
    let ibuf = device.makeBuffer(bytes: indices,
                                  length: indices.count * MemoryLayout<UInt32>.stride,
                                  options: .storageModeShared)!
    return (vbuf, ibuf, indices.count)
}

/// Water mesh: flat grid at y=0, positioned around camera
func makeWaterMesh(device: MTLDevice, size: Int = 64, scale: Float = 40)
    -> (vbuf: MTLBuffer, ibuf: MTLBuffer, indexCount: Int)
{
    return makeTerrainMesh(device: device, size: size, scale: scale)
}

// ─── 256×256 Perlin hash noise texture ───────────────────────────────────────
func makeNoiseTexture(device: MTLDevice) -> MTLTexture {
    let size = 256
    var perm = Array(0..<size)
    // Fisher-Yates with fixed seed for reproducibility
    var rng: UInt64 = 0x123456789ABCDEF0
    func rand() -> Int {
        rng = rng &* 6364136223846793005 &+ 1442695040888963407
        return Int((rng >> 33) & 0x7FFFFFFF)
    }
    for i in stride(from: size-1, through: 1, by: -1) {
        let j = rand() % (i+1)
        perm.swapAt(i, j)
    }

    // Gradient directions for Perlin noise
    let grads: [SIMD2<Float>] = [
        SIMD2(1,0), SIMD2(-1,0), SIMD2(0,1), SIMD2(0,-1),
        SIMD2(0.707,0.707), SIMD2(-0.707,0.707), SIMD2(0.707,-0.707), SIMD2(-0.707,-0.707)
    ]

    var pixels = [Float](repeating: 0, count: size*size)
    for y in 0..<size {
        for x in 0..<size {
            let xi = x & 255, yi = y & 255
            let g = grads[(perm[(xi + perm[yi]) & 255]) & 7]
            let fx = Float(x)/Float(size), fy = Float(y)/Float(size)
            // Simple value + gradient hash, normalized to [0,1]
            let v = 0.5 + 0.5*(g.x * (fx - 0.5) + g.y * (fy - 0.5))
            pixels[y*size+x] = max(0, min(1, v))
        }
    }

    let desc = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .r32Float, width: size, height: size, mipmapped: false)
    desc.usage = .shaderRead
    desc.storageMode = .shared
    let tex = device.makeTexture(descriptor: desc)!
    tex.replace(region: MTLRegionMake2D(0,0,size,size),
                mipmapLevel: 0,
                withBytes: pixels,
                bytesPerRow: size * MemoryLayout<Float>.stride)
    return tex
}

// ─── Renderer ─────────────────────────────────────────────────────────────────
class Renderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let cmdQueue: MTLCommandQueue
    var uniforms = Uniforms(
        q: (.zero,.zero,.zero,.zero,.zero,.zero,.zero,.zero,
            .zero,.zero,.zero,.zero,.zero,.zero,.zero,.zero),
        v: matrix_identity_float4x4,
        vi: matrix_identity_float4x4,
        resolution: .zero, time: 0, _pad: 0)

    // Pipelines
    var gbufferPSO:  MTLRenderPipelineState!
    var deferredPSO: MTLRenderPipelineState!
    var postPSO:     MTLRenderPipelineState!

    // Depth stencil
    var depthState: MTLDepthStencilState!

    // G-buffer textures
    var gbufWorldPos: MTLTexture!  // rgba32float — world pos + hit flag
    var gbufColor:    MTLTexture!  // rgba32float — vertex color
    var gbufDepth:    MTLTexture!  // depth32float
    var sceneColor:   MTLTexture!  // rgba16float — scene after deferred pass

    // Mesh buffers
    var terrainVBuf: MTLBuffer!
    var terrainIBuf: MTLBuffer!
    var terrainIndexCount: Int = 0
    var waterVBuf: MTLBuffer!
    var waterIBuf: MTLBuffer!
    var waterIndexCount: Int = 0

    // Noise texture
    var noiseTex: MTLTexture!

    // Time
    var startTime: Double = 0

    init(mtkView: MTKView) {
        self.device   = mtkView.device!
        self.cmdQueue = device.makeCommandQueue()!
        super.init()

        startTime = CACurrentMediaTime()
        mtkView.depthStencilPixelFormat = .depth32Float
        mtkView.colorPixelFormat        = .bgra8Unorm
        mtkView.sampleCount             = 1

        buildPipelines(mtkView: mtkView)
        buildResources(mtkView: mtkView)
        buildMeshes()
        initUniforms()
    }

    // ── Pipelines ──────────────────────────────────────────────────────────
    func buildPipelines(mtkView: MTKView) {
        let lib: MTLLibrary
        do {
            // SPM copies .metal as a resource; compile it at runtime
            guard let srcURL = Bundle.module.url(forResource: "Shaders", withExtension: "metal"),
                  let src = try? String(contentsOf: srcURL, encoding: .utf8) else {
                fatalError("Shaders.metal not found in bundle")
            }
            let opts = MTLCompileOptions()
            opts.languageVersion = .version3_0
            lib = try device.makeLibrary(source: src, options: opts)
        } catch {
            fatalError("Metal shader compile error: \(error)")
        }

        let gbufDesc = MTLRenderPipelineDescriptor()
        gbufDesc.vertexFunction   = lib.makeFunction(name: "terrainVert")
        gbufDesc.fragmentFunction = lib.makeFunction(name: "gbufferFrag")
        gbufDesc.colorAttachments[0].pixelFormat = .rgba32Float  // worldPos
        gbufDesc.colorAttachments[1].pixelFormat = .rgba32Float  // color
        gbufDesc.depthAttachmentPixelFormat = .depth32Float
        gbufferPSO = try! device.makeRenderPipelineState(descriptor: gbufDesc)

        let deferredDesc = MTLRenderPipelineDescriptor()
        deferredDesc.vertexFunction   = lib.makeFunction(name: "fullscreenVert")
        deferredDesc.fragmentFunction = lib.makeFunction(name: "deferredFrag")
        deferredDesc.colorAttachments[0].pixelFormat = .rgba16Float
        deferredPSO = try! device.makeRenderPipelineState(descriptor: deferredDesc)

        let postDesc = MTLRenderPipelineDescriptor()
        postDesc.vertexFunction   = lib.makeFunction(name: "fullscreenVert")
        postDesc.fragmentFunction = lib.makeFunction(name: "postFrag")
        postDesc.colorAttachments[0].pixelFormat = mtkView.colorPixelFormat
        postPSO = try! device.makeRenderPipelineState(descriptor: postDesc)

        let dsDesc = MTLDepthStencilDescriptor()
        dsDesc.depthCompareFunction = .less
        dsDesc.isDepthWriteEnabled  = true
        depthState = device.makeDepthStencilState(descriptor: dsDesc)!
    }

    // ── Off-screen textures ────────────────────────────────────────────────
    func buildResources(mtkView: MTKView) {
        noiseTex = makeNoiseTexture(device: device)
        rebuildOffscreen(size: mtkView.drawableSize)
    }

    func rebuildOffscreen(size: CGSize) {
        let w = Int(size.width), h = Int(size.height)
        guard w > 0, h > 0 else { return }

        func makeTex(_ fmt: MTLPixelFormat, _ usage: MTLTextureUsage = [.shaderRead, .renderTarget]) -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: fmt, width: w, height: h, mipmapped: false)
            d.usage = usage
            d.storageMode = .private
            return device.makeTexture(descriptor: d)!
        }

        gbufWorldPos = makeTex(.rgba32Float)
        gbufColor    = makeTex(.rgba32Float)
        gbufDepth    = makeTex(.depth32Float, [.renderTarget])
        sceneColor   = makeTex(.rgba16Float)
    }

    // ── Meshes ─────────────────────────────────────────────────────────────
    func buildMeshes() {
        let (vb, ib, ic) = makeTerrainMesh(device: device, size: 256, scale: 64)
        terrainVBuf = vb; terrainIBuf = ib; terrainIndexCount = ic

        let (wv, wi, wc) = makeWaterMesh(device: device, size: 64, scale: 40)
        waterVBuf = wv; waterIBuf = wi; waterIndexCount = wc
    }

    // ── Initial uniforms ───────────────────────────────────────────────────
    func initUniforms() {
        // Set from keyframe 0 (exact values from original binary)
        let kf = lerpAnimKeyframe(t: 0)
        let sunAngle = kf[6]  // q[1].z
        uniforms.setQ(0, SIMD4(kf[0], kf[1], kf[2], kf[3]))
        uniforms.setQ(1, SIMD4(kf[4], kf[5], sunAngle, kf[7]))
        uniforms.setQ(2, SIMD4(kf[8], kf[9], kf[10], kf[11]))
        // Sun direction derived from angle: q[3] = (cos(angle), 0.3125, sin(angle), 0)
        uniforms.setQ(3, SIMD4(cos(sunAngle), 0.3125, sin(sunAngle), 0))
        // Cloud bands q[5..12]: original writes timer-in-samples (t*44100) to q[i].x,
        // creating clouds that slowly drift/fade as the demo progresses.
        // exp(-q.x * 0.0002): values ~3000-8000 give densities 0.55-0.20
        for i in 5..<13 {
            uniforms.setQ(i, SIMD4(Float(i-5) * 1200 + 3000, 0, 0, 0))
        }

        // q[13]: beacon world position (lighthouse on a hilltop, visible around t=70-180s)
        // x,z = world XZ; y = height above terrain
        uniforms.setQ(13, SIMD4(6.0, 2.8, -8.0, 1.0))
    }

    // ── Per-frame update ───────────────────────────────────────────────────
    func updateUniforms(size: CGSize) {
        let t = Float(CACurrentMediaTime() - startTime)
        uniforms.time = t
        uniforms.resolution = SIMD2(Float(size.width), Float(size.height))

        // Interpolate animation keyframes (q[0..2])
        let kf = lerpAnimKeyframe(t: t)
        let sunAngle = kf[6]  // q[1].z = sun angle in radians
        uniforms.setQ(0, SIMD4(kf[0], kf[1], kf[2], kf[3]))
        uniforms.setQ(1, SIMD4(kf[4], kf[5], sunAngle, kf[7]))
        uniforms.setQ(2, SIMD4(kf[8], kf[9], kf[10], kf[11]))

        // q[3]: sun direction (cos/sin of angle, fixed y-elevation=0.3125) + time
        // Matches original: fld q[1].z; fsincos → (cos, 0.3125, sin, time/44100)
        uniforms.setQ(3, SIMD4(cos(sunAngle), 0.3125, sin(sunAngle), t))

        // Cloud bands: drift with time, approximating original timer-driven values.
        // Original writes sample-counter (t*44100) to q[i].x each frame.
        // exp(-q.x*0.0002) controls density; t*44100 → very sparse; we scale by 0.03.
        let cloudTimer = t * 44100 * 0.03
        for i in 5..<13 {
            let base = Float(i - 5) * 1200 + 3000
            uniforms.setQ(i, SIMD4(base + cloudTimer, 0, 0, 0))
        }
        uniforms.setQ(13, SIMD4(6.0, 2.8, -8.0, 1.0))

        // Camera — camera-relative world model:
        // q[4].xz = camera world XZ (terrain FBM sampled at mesh_vertex + q[4].xz)
        // q[4].y  = camera local Y (eye height above mesh origin)
        // View matrix has eye at (0, q[4].y, 0) with rotation only (no XZ translation).
        let (camPos, camTarget) = interpolateCamera(time: t)
        uniforms.setQ(4, SIMD4(camPos.x, camPos.y, camPos.z, 1))

        let aspect = Float(size.width / size.height)
        let proj = projectionMatrix(fovY: 0.8, aspect: aspect, near: 0.1, far: 500)

        // Eye is always at (0, camPos.y, 0) in camera-relative space.
        // Look direction is the same as in world space (direction doesn't depend on XZ offset).
        let lookDir = normalize(camTarget - camPos)
        let localEye    = SIMD3<Float>(0, camPos.y, 0)
        let localTarget = localEye + lookDir * 20.0
        let view = lookAt(eye: localEye, center: localTarget, up: SIMD3(0, 1, 0))
        uniforms.v = proj * view
        uniforms.vi = simd_inverse(uniforms.v)
    }

    // ── MTKViewDelegate ────────────────────────────────────────────────────
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        rebuildOffscreen(size: size)
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor else { return }

        updateUniforms(size: view.drawableSize)
        guard let cmd = cmdQueue.makeCommandBuffer() else { return }

        // ── Pass 1: G-buffer ──────────────────────────────────────────────
        let gbRPD = MTLRenderPassDescriptor()
        gbRPD.colorAttachments[0].texture     = gbufWorldPos
        gbRPD.colorAttachments[0].loadAction  = .clear
        gbRPD.colorAttachments[0].storeAction = .store
        gbRPD.colorAttachments[0].clearColor  = MTLClearColor(red:0,green:0,blue:0,alpha:0)
        gbRPD.colorAttachments[1].texture     = gbufColor
        gbRPD.colorAttachments[1].loadAction  = .clear
        gbRPD.colorAttachments[1].storeAction = .store
        gbRPD.depthAttachment.texture         = gbufDepth
        gbRPD.depthAttachment.loadAction      = .clear
        gbRPD.depthAttachment.storeAction     = .dontCare
        gbRPD.depthAttachment.clearDepth      = 1.0

        var uCopy = uniforms
        if let enc = cmd.makeRenderCommandEncoder(descriptor: gbRPD) {
            enc.setRenderPipelineState(gbufferPSO)
            enc.setDepthStencilState(depthState)
            enc.setVertexBuffer(terrainVBuf, offset: 0, index: 0)
            enc.setVertexBytes(&uCopy, length: MemoryLayout<Uniforms>.size, index: 1)
            enc.setVertexTexture(noiseTex, index: 0)
            enc.drawIndexedPrimitives(type: .triangle, indexCount: terrainIndexCount,
                                      indexType: .uint32, indexBuffer: terrainIBuf,
                                      indexBufferOffset: 0)
            enc.endEncoding()
        }

        // ── Pass 2: Deferred shading ──────────────────────────────────────
        let defRPD = MTLRenderPassDescriptor()
        defRPD.colorAttachments[0].texture     = sceneColor
        defRPD.colorAttachments[0].loadAction  = .dontCare
        defRPD.colorAttachments[0].storeAction = .store

        if let enc = cmd.makeRenderCommandEncoder(descriptor: defRPD) {
            enc.setRenderPipelineState(deferredPSO)
            enc.setFragmentBytes(&uCopy, length: MemoryLayout<Uniforms>.size, index: 0)
            enc.setFragmentTexture(noiseTex,    index: 0)
            enc.setFragmentTexture(gbufWorldPos, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }

        // ── Pass 3: Post-processing → screen ──────────────────────────────
        rpd.colorAttachments[0].loadAction = .dontCare
        if let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) {
            enc.setRenderPipelineState(postPSO)
            enc.setFragmentBytes(&uCopy, length: MemoryLayout<Uniforms>.size, index: 0)
            enc.setFragmentTexture(noiseTex,    index: 0)
            enc.setFragmentTexture(gbufWorldPos, index: 1)
            enc.setFragmentTexture(sceneColor,   index: 2)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }

        cmd.present(drawable)
        cmd.commit()
    }
}

// ─── Math helpers ──────────────────────────────────────────────────────────────
func lookAt(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
    let f = normalize(center - eye)
    let r = normalize(cross(f, up))
    let u = cross(r, f)
    return simd_float4x4(columns: (
        SIMD4(r.x, u.x, -f.x, 0),
        SIMD4(r.y, u.y, -f.y, 0),
        SIMD4(r.z, u.z, -f.z, 0),
        SIMD4(-dot(r,eye), -dot(u,eye), dot(f,eye), 1)
    ))
}

func projectionMatrix(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
    let y = 1 / tan(fovY * 0.5)
    let x = y / aspect
    let z = far / (near - far)
    return simd_float4x4(columns: (
        SIMD4(x,  0,  0,  0),
        SIMD4(0,  y,  0,  0),
        SIMD4(0,  0,  z, -1),
        SIMD4(0,  0,  z*near, 0)
    ))
}

func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, t: Float) -> SIMD3<Float> {
    return a + (b - a) * t
}
