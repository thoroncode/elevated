// Renderer.swift
// Elevated — Metal renderer
// 3-pass pipeline: G-buffer → deferred shading → post-processing

import Foundation
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
func makeNoiseTexture(device: MTLDevice) -> (MTLTexture, [Float]) {
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
    return (tex, pixels)
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
    var noisePixels: [Float] = []

    // Time
    var startTime: Double = 0
    weak var view: MTKView?

    func start() {
        startTime = CACurrentMediaTime()
        view?.isPaused = false
    }

    init(mtkView: MTKView) {
        self.device   = mtkView.device!
        self.cmdQueue = device.makeCommandQueue()!
        super.init()

        self.view = mtkView
        mtkView.isPaused = true          // hold until synthesis is ready
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
        let (tex, pixels) = makeNoiseTexture(device: device)
        noiseTex = tex
        noisePixels = pixels
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
        updateUniforms(size: CGSize(width: 1920, height: 1080))
    }

    // ── CPU noise helpers ──────────────────────────────────────────────────

    // Bilinear sample of the 256×256 noise texture (tiling, [0,1] coords)
    private func sampleNoise(_ uv: SIMD2<Float>) -> Float {
        let size = 256
        let uf = (uv.x - Foundation.floor(uv.x)) * Float(size)
        let vf = (uv.y - Foundation.floor(uv.y)) * Float(size)
        let x0 = Int(uf) & (size - 1)
        let y0 = Int(vf) & (size - 1)
        let x1 = (x0 + 1) & (size - 1)
        let y1 = (y0 + 1) & (size - 1)
        let fx = uf - Foundation.floor(uf)
        let fy = vf - Foundation.floor(vf)
        let a = noisePixels[y0 * size + x0]
        let b = noisePixels[y0 * size + x1]
        let c = noisePixels[y1 * size + x0]
        let d = noisePixels[y1 * size + x1]
        return a + (b - a) * fx + (c - a) * fy + (a - b - c + d) * fx * fy
    }

    // Perlin-style gradient noise — returns (value, grad.x, grad.y)
    private func cpuNo(_ p: SIMD2<Float>) -> SIMD3<Float> {
        let px = Foundation.floor(p.x)
        let py = Foundation.floor(p.y)
        let fp = p - SIMD2(px, py)
        // quintic smoothstep: f*f*f*(f*(f*6-15)+10)
        let fp2 = fp * fp
        let fp3 = fp2 * fp
        let fp4 = fp3 * fp
        let fp5 = fp4 * fp
        let u = fp5 * 6 - fp4 * 15 + fp3 * 10
        let a = sampleNoise(SIMD2(px,     py    ) / 256)
        let b = sampleNoise(SIMD2(px + 1, py    ) / 256)
        let c = sampleNoise(SIMD2(px,     py + 1) / 256)
        let d = sampleNoise(SIMD2(px + 1, py + 1) / 256)
        let abcd = a - b - c + d
        let v = a + (b - a) * u.x + (c - a) * u.y + abcd * u.x * u.y
        // derivative of quintic: 30*f^2*(f*(f-2)+1) = 30*f^2*(f^2-2f+1)
        let du = (fp4 - fp3 * 2 + fp2) * 30
        let gx = du.x * ((b - a) + abcd * u.y)
        let gy = du.y * ((c - a) + abcd * u.x)
        return SIMD3(v, gx, gy)
    }

    // FBM terrain height, o octaves (matches shader fbm exactly)
    private func cpuFbm(_ p: SIMD2<Float>, octaves: Int = 8) -> Float {
        var p = p
        var d = SIMD2<Float>.zero
        var a: Float = 0
        var b: Float = 3
        for _ in 0..<octaves {
            let n = cpuNo(0.25 * p)
            d += SIMD2(n.y, n.z)
            b *= 0.5
            a += b * n.x / (1 + d.x * d.x + d.y * d.y)
            // domain rotation: float2x2(1.6,-1.2,1.2,1.6) * p
            p = SIMD2(1.6 * p.x - 1.2 * p.y, 1.2 * p.x + 1.6 * p.y)
        }
        return a
    }

    // Port of m1 shader: compute camera world position (xdot=0) or target (xdot=1)
    private func m1Camera(xdot: Float) -> SIMD3<Float> {
        guard !noisePixels.isEmpty else { return SIMD3(0, 1, 0) }
        let q0 = uniforms.getQ(0)  // (camSeedX, camSeedY, camSpeed, camFov)
        let q1 = uniforms.getQ(1)  // (camPosY, camTarY, sunAngle, waterLevel)
        let q2 = uniforms.getQ(2)  // (season, brightness, contrast, terScale)
        let q3 = uniforms.getQ(3)  // (sunDirX, sunDirY, sunDirZ, time)

        var o = SIMD2<Float>(q0.x + xdot * 0.37, q0.y + xdot * 0.37)
        let tt = q3.w * q0.z

        func sn(_ uv: SIMD2<Float>) -> Float { sampleNoise(uv) }

        // c.x: 16*cos(t*s1+3*s2) + 8*cos(t*s3*2+3*s4)
        o += SIMD2(repeating: 0.1)
        let s1 = sn(o); let s2 = sn(o + SIMD2(repeating: 0.1))
        o += SIMD2(repeating: 0.1)
        let s3 = sn(o); let s4 = sn(o + SIMD2(repeating: 0.1))
        let cx = 16 * cos(tt * s1 + 3 * s2) + 8 * cos(tt * s3 * 2 + 3 * s4)
        o += SIMD2(repeating: 0.2)

        // c.z: same pattern, next 4 samples
        o += SIMD2(repeating: 0.1)
        let s5 = sn(o); let s6 = sn(o + SIMD2(repeating: 0.1))
        o += SIMD2(repeating: 0.1)
        let s7 = sn(o); let s8 = sn(o + SIMD2(repeating: 0.1))
        let cz = 16 * cos(tt * s5 + 3 * s6) + 8 * cos(tt * s7 * 2 + 3 * s8)

        // c.y = terScale * fbm(cx,cz, 3 octaves) + camPosY + camTarY * xdot
        let cy = q2.w * cpuFbm(SIMD2(cx, cz), octaves: 3) + q1.x + q1.y * xdot

        return SIMD3(cx, cy, cz)
    }

    // ── Per-frame update ───────────────────────────────────────────────────
    func updateUniforms(size: CGSize) {
        let t = Float(CACurrentMediaTime() - startTime)
        uniforms.time = t
        uniforms.resolution = SIMD2(Float(size.width), Float(size.height))

        let position = Int(t * 44100)

        // q[0]: camSeedX/256, camSeedY/256, camSpeed/4096, camFov/96
        let camSeedX = syncParam(position, Sync.camSeedX) / 256.0
        let camSeedY = syncParam(position, Sync.camSeedY) / 256.0
        let camSpeed = syncParam(position, Sync.camSpeed) / 4096.0
        let camFov   = syncParam(position, Sync.camFov)   / 96.0
        uniforms.setQ(0, SIMD4(camSeedX, camSeedY, camSpeed, camFov))

        // q[1]: camPosY/64, (camTarY-128)/4, sunAngle/32 (radians), (waterLevel-192)/128
        let camPosY    = syncParam(position, Sync.camPosY) / 64.0
        let camTarY    = (syncParam(position, Sync.camTarY) - 128.0) / 4.0
        let sunAngle   = syncParam(position, Sync.sunAngle) / 32.0
        let waterLevel = (syncParam(position, Sync.terWaterLevel) - 192.0) / 128.0
        uniforms.setQ(1, SIMD4(camPosY, camTarY, sunAngle, waterLevel))

        // q[2]: season/256, (brightness-128)/128, contrast/128, (terScale-128)/128
        let season     = syncParam(position, Sync.terSeason)    / 256.0
        let brightness = (syncParam(position, Sync.imgBrightness) - 128.0) / 128.0
        let contrast   = syncParam(position, Sync.imgContrast)  / 128.0
        let terScale   = (syncParam(position, Sync.terScale) - 128.0) / 128.0
        uniforms.setQ(2, SIMD4(season, brightness, contrast, terScale))

        // q[3]: sun direction + time
        uniforms.setQ(3, SIMD4(cos(sunAngle), 0.3125, sin(sunAngle), t))

        // q[4]: camera world position (m1 camera formula)
        let camPos    = m1Camera(xdot: 0)
        let camTarget = m1Camera(xdot: 1)
        uniforms.setQ(4, SIMD4(camPos.x, camPos.y, camPos.z, 1))

        // q[5..12]: cloud band timer (instrument sync approximation)
        let cloudTimer = t * 44100.0 * 0.03
        for i in 5..<13 {
            let base = Float(i - 5) * 1200 + 3000
            uniforms.setQ(i, SIMD4(base + cloudTimer, 0, 0, 0))
        }

        // q[13]: beacon world position (lighthouse)
        uniforms.setQ(13, SIMD4(6.0, 2.8, -8.0, 1.0))

        // View matrix — camera-relative: eye at (0, camPos.y, 0), look toward camTarget
        let lookDir = normalize(camTarget - camPos)
        let roll = 0.3 * cos(t * camSpeed * 2)   // camera roll from m1 return value
        let up = SIMD3<Float>(sin(roll), cos(roll), 0)
        let localEye    = SIMD3<Float>(0, camPos.y, 0)
        let localTarget = localEye + lookDir * 20.0

        let aspect = Float(size.width / size.height)
        let proj = projectionMatrix(fovY: camFov, aspect: aspect, near: 0.03125, far: 256.0)
        let view = lookAt(eye: localEye, center: localTarget, up: up)
        uniforms.v  = proj * view
        uniforms.vi = simd_inverse(uniforms.v)
    }

    // ── MTKViewDelegate ────────────────────────────────────────────────────
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        rebuildOffscreen(size: size)
    }

    func draw(in view: MTKView) {
        let t = CACurrentMediaTime() - startTime
        if t >= 217.5 {
            NSApplication.shared.terminate(nil)
            return
        }

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
