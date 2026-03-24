// Renderer.swift
// Elevated — Metal renderer
// 3-pass pipeline: G-buffer → deferred shading → post-processing

import Foundation
import Metal
import MetalKit
import simd
import CSynth

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

// ─── 256×256 noise texture — exact frandom() LCG from synth_core.nh ─────────
// frandom(): seed = seed * 16307 + 17 (wrapping u32);
//            return (int16)(seed >> 14) / 32768.0
// D3DXFillTexture fills row-major (y outer, x inner) starting from seed = 0.
// Original format D3DFMT_R16F; stored here as R32F for Metal.
func makeNoiseTexture(device: MTLDevice) -> (MTLTexture, [Float]) {
    let size = 256
    var seed: UInt32 = 0
    func frandom() -> Float {
        seed = seed &* 16307 &+ 17
        let i16 = Int16(bitPattern: UInt16(truncatingIfNeeded: seed >> 14))
        return Float(i16) / 32768.0
    }

    var pixels = [Float](repeating: 0, count: size * size)
    for y in 0..<size {
        for x in 0..<size {
            pixels[y * size + x] = frandom()
        }
    }

    let desc = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .r32Float, width: size, height: size, mipmapped: false)
    desc.usage = .shaderRead
    desc.storageMode = .shared
    let tex = device.makeTexture(descriptor: desc)!
    tex.replace(region: MTLRegionMake2D(0, 0, size, size),
                mipmapLevel: 0,
                withBytes: pixels,
                bytesPerRow: size * MemoryLayout<Float>.stride)
    return (tex, pixels)
}

// ─── Debug overlay ────────────────────────────────────────────────────────────
/// NSTextField overlay shown in --debug mode. Lives above the Metal view.
class DebugOverlay {
    let label: NSTextField

    init() {
        label = NSTextField(frame: NSRect(x: 8, y: 8, width: 780, height: 200))
        label.isEditable        = false
        label.isSelectable      = false
        label.isBezeled         = false
        label.drawsBackground   = true
        label.backgroundColor   = NSColor(calibratedWhite: 0, alpha: 0.55)
        label.textColor         = NSColor(calibratedRed: 0.2, green: 1, blue: 0.3, alpha: 1)
        label.font              = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        label.maximumNumberOfLines = 0
        label.cell?.wraps       = true
    }

    var isHidden: Bool {
        get { label.isHidden }
        set { label.isHidden = newValue }
    }

    func install(in view: NSView) {
        view.addSubview(label)
    }

    func update(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            self?.label.stringValue = text
        }
    }
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

    // Noise texture
    var noiseTex: MTLTexture!
    var noisePixels: [Float] = []

    // Time
    var startTime: Double = 0
    private(set) var isPaused = false
    private var pauseTime: Double = 0
    var onDraw: (() -> Void)?
    weak var view: MTKView?

    // Debug / capture
    var debugMode: Bool
    let captureMode: Bool           // --capture: save one PNG per second to /tmp/elevated_cap/
    var frameNumber: Int = 0
    var lastCapturedSecond: Int = -1
    var debugOverlay: DebugOverlay?

    func installDebugOverlay(in view: NSView) {
        let overlay = DebugOverlay()
        overlay.install(in: view)
        debugOverlay = overlay
    }

    // ── Playback time ──────────────────────────────────────────────────────
    var currentTime: Double {
        guard startTime > 0 else { return 0 }
        let t = isPaused ? pauseTime : CACurrentMediaTime() - startTime
        return max(0, min(t, 217.0))
    }

    func start() {
        startTime = CACurrentMediaTime()
        view?.isPaused = false
    }

    func pause() {
        guard !isPaused, startTime > 0 else { return }
        pauseTime = CACurrentMediaTime() - startTime
        isPaused = true
    }

    func resume() {
        guard isPaused else { return }
        startTime = CACurrentMediaTime() - pauseTime
        isPaused = false
    }

    func seek(to time: Double) {
        let t = max(0, min(time, 217.0))
        startTime = CACurrentMediaTime() - t
        if isPaused { pauseTime = t }
    }

    /// SMPTE-style timecode string: HH:MM:SS:FF at 60 fps.
    static func timecode(_ t: Double, fps: Int = 60) -> String {
        let tf = Int(max(0, t) * Double(fps))
        return String(format: "%02d:%02d:%02d:%02d",
                      tf / fps / 3600, tf / fps / 60 % 60, tf / fps % 60, tf % fps)
    }

    init(mtkView: MTKView, debug: Bool = false, capture: Bool = false) {
        self.debugMode   = debug
        self.captureMode = capture
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
        // Original mesh: D3DXCreatePolygon(52.0f, 4) — square with ~52 unit radius.
        // Camera XZ range: ±24. Fog exp(-0.042*t) hides edges beyond ~40 units.
        // Use scale=104 (±52) to match original extent.
        let (vb, ib, ic) = makeTerrainMesh(device: device, size: 256, scale: 104)
        terrainVBuf = vb; terrainIBuf = ib; terrainIndexCount = ic
    }

    // ── Initial uniforms ───────────────────────────────────────────────────
    func initUniforms() {
        updateUniforms(size: CGSize(width: 1920, height: 1080))
    }

    // ── CPU noise helpers ──────────────────────────────────────────────────

    // Point (nearest-neighbour) sample of the 256×256 noise texture.
    // D3D9 default sampler state is D3DTEXF_POINT — no bilinear blending.
    // tex2D(t0, uv) returns the exact texel at floor(uv * 256) mod 256.
    private func sampleNoise(_ uv: SIMD2<Float>) -> Float {
        let size = 256
        let x = Int(Foundation.floor((uv.x - Foundation.floor(uv.x)) * Float(size))) & (size - 1)
        let y = Int(Foundation.floor((uv.y - Foundation.floor(uv.y)) * Float(size))) & (size - 1)
        return noisePixels[y * size + x]
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

        // Exact port of m1 shader — each tex2D(t0, o+=.1) increments o then samples.
        // c.x=16*cos(t*s1+3*s2)+8*cos(t*s3*2+3*s4)
        o += SIMD2(repeating: 0.1); let s1 = sampleNoise(o)
        o += SIMD2(repeating: 0.1); let s2 = sampleNoise(o)
        o += SIMD2(repeating: 0.1); let s3 = sampleNoise(o)
        o += SIMD2(repeating: 0.1); let s4 = sampleNoise(o)
        let cx = 16 * cos(tt * s1 + 3 * s2) + 8 * cos(tt * s3 * 2 + 3 * s4)

        // c.z=16*cos(t*s5+3*s6)+8*cos(t*s7*2+3*s8)
        o += SIMD2(repeating: 0.1); let s5 = sampleNoise(o)
        o += SIMD2(repeating: 0.1); let s6 = sampleNoise(o)
        o += SIMD2(repeating: 0.1); let s7 = sampleNoise(o)
        o += SIMD2(repeating: 0.1); let s8 = sampleNoise(o)
        let cz = 16 * cos(tt * s5 + 3 * s6) + 8 * cos(tt * s7 * 2 + 3 * s8)

        // c.y = terScale * fbm(cx,cz, 3 octaves) + camPosY + camTarY * xdot
        var cx_ = cx
        var cy   = q2.w * cpuFbm(SIMD2(cx, cz), octaves: 3) + q1.x + q1.y * xdot
        var cz_  = cz

        // Jitter: o+=q[3].w*.5; c.x+=.002*no(o+=.1); c.y+=.002*no(o+=.1); c.z+=.002*no(o+=.1)
        // Each no() call increments o by 0.1 separately; HLSL takes .x (value) of each float3 result.
        o += SIMD2(repeating: q3.w * 0.5)
        o += SIMD2(repeating: 0.1); cx_ += 0.002 * cpuNo(o).x
        o += SIMD2(repeating: 0.1); cy  += 0.002 * cpuNo(o).x
        o += SIMD2(repeating: 0.1); cz_ += 0.002 * cpuNo(o).x

        return SIMD3(cx_, cy, cz_)
    }

    // ── Per-frame update ───────────────────────────────────────────────────
    func updateUniforms(size: CGSize) {
        let t = Float(currentTime)
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
        // idata.cpp comment: "x.x = 0 for cam  x.x = 1 for target"
        // D3D9 VPOS on this hardware/driver gives integer pixel indices, not centres.
        let camPos    = m1Camera(xdot: 0.0)
        let camTarget = m1Camera(xdot: 1.0)
        uniforms.setQ(4, SIMD4(camPos.x, camPos.y, camPos.z, 1))

        // q[5..12]: instrument sync for visual light beams.
        // Exact port of demo_deb.cpp DemoEffect() lines 184-200.
        // Clamp to valid demo range [0, ELEVATED_TOTAL_SAMPLES] to avoid Int32 overflow
        // (initUniforms() is called before start(), when t is large)
        let syncPos = Int32(max(0, min(position, Int(ELEVATED_TOTAL_SAMPLES))))
        var syncVals = [Float](repeating: 0, count: 8)
        syncVals.withUnsafeMutableBufferPointer { ptr in
            elevated_instrument_sync(syncPos, ptr.baseAddress!)
        }
        for i in 0..<8 {
            uniforms.setQ(5 + i, SIMD4(syncVals[i], 0, 0, 0))
        }

        // View matrix — exact port of constructMatrix() from demo_deb.cpp:
        // D3DXMatrixLookAtLH(mat, pptr[0].xyz, pptr[1].xyz, up)
        // up = {sin(roll), cos(roll), 0} where roll = pptr[0].w = .3*cos(t*2)
        let roll = 0.3 * cos(t * camSpeed * 2)
        let up = SIMD3<Float>(sin(roll), cos(roll), 0)

        let aspect = Float(size.width) / Float(size.height)
        let proj = projectionMatrixLH(fovY: camFov, aspect: aspect, near: 0.03125, far: 256.0)
        let view = lookAtLH(eye: camPos, center: camTarget, up: up)
        uniforms.v  = proj * view
        uniforms.vi = simd_inverse(uniforms.v)
    }

    // ── Frame capture ──────────────────────────────────────────────────────

    /// If set, the next rendered frame is saved to this path then the app exits.
    var captureNextFramePath: String? = nil

    // Saves the final drawable as /tmp/elevated_cap/cap_XXXX.png once per second.
    func maybeCaptureFrame(drawable: CAMetalDrawable) {
        guard captureMode else { return }
        let sec = Int(uniforms.time)
        guard sec != lastCapturedSecond, sec >= 0 else { return }
        lastCapturedSecond = sec
        let dir = "/tmp/elevated_cap"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = "\(dir)/cap_\(String(format: "%04d", sec + 1)).png"
        saveDrawable(drawable, to: path)
        if debugMode { print("  [capture] \(path)") }
    }

    // Reads back a drawable texture and saves it as a PNG.
    func saveDrawable(_ drawable: CAMetalDrawable, to path: String) {
        let tex = drawable.texture
        let w = tex.width, h = tex.height
        let bpr = w * 4
        var raw = [UInt8](repeating: 0, count: bpr * h)
        guard let buf = device.makeBuffer(length: bpr * h, options: .storageModeShared),
              let cmd = cmdQueue.makeCommandBuffer(),
              let blit = cmd.makeBlitCommandEncoder() else { return }
        blit.copy(from: tex, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOriginMake(0, 0, 0),
                  sourceSize: MTLSizeMake(w, h, 1),
                  to: buf, destinationOffset: 0,
                  destinationBytesPerRow: bpr,
                  destinationBytesPerImage: bpr * h)
        blit.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        memcpy(&raw, buf.contents(), bpr * h)
        for i in stride(from: 0, to: raw.count, by: 4) {
            let b = raw[i]; raw[i] = raw[i+2]; raw[i+2] = b  // swap B↔R
        }
        savePNG(pixels: raw, width: w, height: h, path: path)
    }

    private func savePNG(pixels: [UInt8], width: Int, height: Int, path: String) {
        let bpr = width * 4
        var mutable = pixels
        let img: CGImage? = mutable.withUnsafeMutableBytes { ptr in
            guard let ctx = CGContext(data: ptr.baseAddress,
                                      width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: bpr,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return nil }
            return ctx.makeImage()
        }
        guard let img else { return }
        let rep = NSBitmapImageRep(cgImage: img)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }

    // ── Debug output ───────────────────────────────────────────────────────
    func emitDebug() {
        let t    = uniforms.time
        let q0   = uniforms.getQ(0)  // camSeedX, camSeedY, camSpeed, camFov
        let q1   = uniforms.getQ(1)  // camPosY, camTarY, sunAngle, waterLevel
        let q2   = uniforms.getQ(2)  // season, brightness, contrast, terScale

        let camPos    = m1Camera(xdot: 0.0)
        let camTarget = m1Camera(xdot: 1.0)

        let tc = Renderer.timecode(Double(t))
        let msg = String(format:
            "frame %6d  %@  row=%d\n" +
            "camPos    %7.3f %7.3f %7.3f\n" +
            "camTarget %7.3f %7.3f %7.3f\n" +
            "camSpeed  %7.4f  camFov %6.4f rad (%5.1f°)\n" +
            "terScale  %7.4f  season %5.3f\n" +
            "sunAngle  %7.4f  waterLv %6.4f\n" +
            "brightness%7.4f  contrast%6.4f",
            frameNumber, tc, Int(t * 44100) / 20840,
            camPos.x, camPos.y, camPos.z,
            camTarget.x, camTarget.y, camTarget.z,
            q0.z, q0.w, q0.w * (180 / Float.pi),
            q2.w, q2.x,
            q1.z, q1.w,
            q2.y, q2.z
        )

        // Console log every frame
        print(msg)

        // Screen overlay
        debugOverlay?.update(msg)
    }

    // ── MTKViewDelegate ────────────────────────────────────────────────────
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        rebuildOffscreen(size: size)
    }

    func draw(in view: MTKView) {
        let t = currentTime
        if t >= 217.0 && !isPaused {
            NSApplication.shared.terminate(nil)
            return
        }

        guard let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor else { return }

        updateUniforms(size: view.drawableSize)
        frameNumber += 1
        if debugMode { emitDebug() }
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
            enc.setCullMode(.back)   // hide terrain underside when camera dips below mesh
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

        maybeCaptureFrame(drawable: drawable)

        if let path = captureNextFramePath {
            captureNextFramePath = nil
            saveDrawable(drawable, to: path)
            print("[icon] saved \(path)")
            DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
        }

        onDraw?()
    }
}

// ─── Math helpers ──────────────────────────────────────────────────────────────
// Left-handed lookAt matching D3DXMatrixLookAtLH.
// D3DX produces a row-major matrix for row-vector pre-multiply; transposed here
// to column-major for Metal's post-multiply convention (u.v * worldCol).
func lookAtLH(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
    let z = normalize(center - eye)       // forward (+Z in LH)
    let x = normalize(cross(up, z))       // right
    let y = cross(z, x)                   // up (reorthogonalized)
    return simd_float4x4(columns: (
        SIMD4(x.x, y.x, z.x, 0),
        SIMD4(x.y, y.y, z.y, 0),
        SIMD4(x.z, y.z, z.z, 0),
        SIMD4(-dot(x,eye), -dot(y,eye), -dot(z,eye), 1)
    ))
}

// Left-handed perspective matching D3DXMatrixPerspectiveFovLH.
// D3D NDC z range is [0,1] (near=0, far=1), same as Metal — no remapping needed.
func projectionMatrixLH(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
    let y = 1 / tan(fovY * 0.5)           // cot(fovY/2)
    let x = y / aspect
    let z = far / (far - near)             // zf/(zf-zn)
    return simd_float4x4(columns: (
        SIMD4(x, 0, 0, 0),
        SIMD4(0, y, 0, 0),
        SIMD4(0, 0, z, 1),
        SIMD4(0, 0, -near * z, 0)
    ))
}

func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, t: Float) -> SIMD3<Float> {
    return a + (b - a) * t
}
