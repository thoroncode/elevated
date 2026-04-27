// ImmersiveRenderer.swift
// Immersive Metal renderer for visionOS using CompositorServices.
// Uses the demo's own projection/FOV plus eye offset and head rotation to
// preserve Elevated's cinematography while adding head-tracked look-around.

#if os(visionOS)
import CompositorServices
import Metal
import MetalKit
import Spatial
import ARKit
import ElevatedCore
import AVFoundation

@MainActor
public class ImmersiveRenderer {
    private let renderer: Renderer
    private let synth = SynthPlayer()
    private let arSession = ARKitSession()
    private let worldTracking = WorldTrackingProvider()
    nonisolated(unsafe) private var isRunning = false
    nonisolated(unsafe) private var isStopped = false

    public init(layerRenderer: LayerRenderer) throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal not available")
        }

        let tempView = MTKView(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), device: device)
        tempView.colorPixelFormat = .bgra8Unorm_srgb
        tempView.depthStencilPixelFormat = .depth32Float
        renderer = Renderer(mtkView: tempView, debug: false, capture: false)
        renderer.outputGamma = 2.4

        do {
            try AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("[ImmersiveRenderer] Audio session failed: \(error)")
        }
    }

    public func start() async {
        do {
            try await arSession.run([worldTracking])
        } catch {
            print("[ImmersiveRenderer] ARKit failed: \(error)")
        }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            synth.synthesize { [weak self] ok in
                guard let self, ok else {
                    cont.resume()
                    return
                }
                self.renderer.start()
                self.synth.play()
                self.isRunning = true
                cont.resume()
            }
        }
    }

    public func stop() {
        isStopped = true
        isRunning = false
        synth.pause()
        renderer.pause()
        arSession.stop()
    }

    nonisolated public func renderLoop(_ layerRenderer: LayerRenderer) {
        // Reference head orientation — captured on first frame so
        // "straight ahead" = the demo's forward direction.
        var referenceHeadRotation: simd_float3x3?

        var lastFpsTick = CACurrentMediaTime()
        var framesThisTick = 0
        var smoothedFps: Double = 0
        var totalFrames = 0

        while !isStopped {
            guard layerRenderer.state == .running else {
                if layerRenderer.state == .paused {
                    layerRenderer.waitUntilRunning()
                    continue
                }
                break
            }

            guard let frame = layerRenderer.queryNextFrame() else { continue }
            frame.startUpdate()

            let deviceAnchor = worldTracking.queryDeviceAnchor(atTimestamp: CACurrentMediaTime())

            frame.endUpdate()
            guard let timing = frame.predictTiming() else { continue }
            LayerRenderer.Clock().wait(until: timing.optimalInputTime)

            let drawables = frame.queryDrawables()
            guard !drawables.isEmpty else { continue }

            frame.startSubmission()

            let time = renderer.currentTime
            if time >= kDemoDuration && isRunning {
                isRunning = false
                Task { @MainActor in
                    self.synth.seek(to: 0)
                    self.renderer.start()
                    self.isRunning = true
                }
            }

            // Extract head rotation from ARKit
            let headRotation: simd_float3x3
            if let anchor = deviceAnchor {
                let h = anchor.originFromAnchorTransform
                headRotation = simd_float3x3(
                    SIMD3(h.columns.0.x, h.columns.0.y, h.columns.0.z),
                    SIMD3(h.columns.1.x, h.columns.1.y, h.columns.1.z),
                    SIMD3(h.columns.2.x, h.columns.2.y, h.columns.2.z)
                )
            } else {
                headRotation = matrix_identity_float3x3
            }

            // Capture reference on first valid frame
            if referenceHeadRotation == nil && deviceAnchor != nil {
                referenceHeadRotation = headRotation
            }

            // Head rotation relative to reference (so straight ahead = demo forward)
            let relativeRotation: simd_float4x4
            if let ref = referenceHeadRotation {
                let rel = headRotation * ref.inverse
                relativeRotation = simd_float4x4(columns: (
                    SIMD4(rel.columns.0, 0),
                    SIMD4(rel.columns.1, 0),
                    SIMD4(rel.columns.2, 0),
                    SIMD4(0, 0, 0, 1)
                ))
            } else {
                relativeRotation = matrix_identity_float4x4
            }

            for drawable in drawables {
                let tex = drawable.colorTextures[0]
                let size = CGSize(width: tex.width, height: tex.height)

                // Update uniforms — this computes the demo's exact projection + view
                // (camera path, roll, sync-driven FOV) for this frame.
                renderer.updateUniformsForTime(time, size: size)
                let demoProjection = renderer.lastProjection
                let viewDemo = renderer.lastView

                drawable.deviceAnchor = deviceAnchor
                // CompositorServices still expects its reverse-Z near/far ordering here
                // even though we render with the demo's own forward-Z projection.
                drawable.depthRange = SIMD2(256.0, 0.03125)

                guard let cmd = renderer.cmdQueue.makeCommandBuffer() else { continue }

                for viewIndex in 0..<drawable.views.count {
                    let texture = drawable.colorTextures[viewIndex]
                    let view = drawable.views[viewIndex]

                    // Per-eye view offset (IPD) as a 4x4 translation
                    let eyeTransform = view.transform
                    let eyeView = simd_float4x4(columns: (
                        SIMD4(1, 0, 0, 0),
                        SIMD4(0, 1, 0, 0),
                        SIMD4(0, 0, 1, 0),
                        SIMD4(-eyeTransform.columns.3.x,
                               -eyeTransform.columns.3.y,
                               -eyeTransform.columns.3.z, 1)
                    ))

                    // Keep the demo's intended projection/FOV and layer stereo eye
                    // offset + head look-around in view space: P_demo * eyeOffset * R_head * V_demo
                    let vp = demoProjection * eyeView * relativeRotation * viewDemo

                    renderer.renderFrame(commandBuffer: cmd, outputTexture: texture,
                                        viewProjection: vp, size: size)
                }

                drawable.encodePresent(commandBuffer: cmd)
                cmd.commit()
            }

            frame.endSubmission()

            framesThisTick += 1
            totalFrames += 1
            let now = CACurrentMediaTime()
            let dt = now - lastFpsTick
            if dt >= 0.5 {
                smoothedFps = Double(framesThisTick) / dt
                framesThisTick = 0
                lastFpsTick = now
            }

            if let firstDrawable = drawables.first {
                let firstTex = firstDrawable.colorTextures[0]
                let snapshotSize = CGSize(width: firstTex.width, height: firstTex.height)
                let camPos = renderer.demoCameraPosition
                let fps = smoothedFps
                let frameNo = totalFrames
                Task { @MainActor in
                    if let s = sharedDebugState {
                        s.time = time
                        s.fps = fps
                        s.frameCount = frameNo
                        s.renderSize = snapshotSize
                        s.minNearPlane = capturedMinNearPlane
                        s.cameraPos = camPos
                    }
                }
            }
        }

        if !isStopped {
            Task { @MainActor in
                self.stop()
            }
        }
    }
}
#endif
