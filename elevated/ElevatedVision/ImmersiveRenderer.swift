// ImmersiveRenderer.swift
// Immersive Metal renderer for visionOS using CompositorServices.
// Preplanned demo flight through the Elevated terrain.

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

        // Use .bgra8Unorm_srgb to match CompositorLayer drawable format.
        let tempView = MTKView(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), device: device)
        tempView.colorPixelFormat = .bgra8Unorm_srgb
        tempView.depthStencilPixelFormat = .depth32Float
        renderer = Renderer(mtkView: tempView, debug: false, capture: false)
        // sRGB texture auto-applies pow(1/2.4) encoding. Set 2.4 so the
        // shader pre-applies pow(c, 2.4) to cancel it, matching macOS output.
        renderer.outputGamma = 2.4

        // Audio — use .ambient so system auto-stops on background
        do {
            try AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("[ImmersiveRenderer] Audio session failed: \(error)")
        }

    }

    public func start() async {
        // Start ARKit
        do {
            try await arSession.run([worldTracking])
        } catch {
            print("[ImmersiveRenderer] ARKit failed: \(error)")
        }

        // Synthesize audio
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

    /// Stop everything — call when immersive space is dismissed.
    public func stop() {
        isStopped = true
        isRunning = false
        synth.pause()
        renderer.pause()
        arSession.stop()
    }

    nonisolated public func renderLoop(_ layerRenderer: LayerRenderer) {
        while !isStopped {
            guard layerRenderer.state == .running else {
                if layerRenderer.state == .paused {
                    layerRenderer.waitUntilRunning()
                    continue
                }
                break  // .invalidated
            }

            guard let frame = layerRenderer.queryNextFrame() else { continue }
            frame.startUpdate()

            // Get head pose for reprojection
            let deviceAnchor = worldTracking.queryDeviceAnchor(atTimestamp: CACurrentMediaTime())

            frame.endUpdate()
            guard let timing = frame.predictTiming() else { continue }
            LayerRenderer.Clock().wait(until: timing.optimalInputTime)

            let drawables = frame.queryDrawables()
            guard !drawables.isEmpty else { continue }

            frame.startSubmission()

            let time = renderer.currentTime
            if time >= kDemoDuration && isRunning {
                isRunning = false  // prevent repeated restart dispatches
                Task { @MainActor in
                    self.synth.seek(to: 0)
                    self.renderer.start()
                    self.isRunning = true
                }
            }

            for drawable in drawables {
                // Update sync-driven uniforms
                let tex = drawable.colorTextures[0]
                let size = CGSize(width: tex.width, height: tex.height)
                renderer.updateUniformsForTime(time, size: size)

                let camPos = renderer.demoCameraPosition
                let camTarget = renderer.demoCameraTarget

                // Build demo camera basis (the direction the demo "looks")
                let demoFwd = normalize(camTarget - camPos)
                let demoRight = normalize(cross(SIMD3<Float>(0, 1, 0), demoFwd))
                let demoUp = cross(demoFwd, demoRight)
                // demoBasis columns: right, up, forward — transforms head-space → world-space
                let demoBasis = simd_float3x3(columns: (demoRight, demoUp, demoFwd))

                // Head rotation from ARKit (identity if no tracking)
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

                // Combined orientation: demo direction + head look-around
                let orient = demoBasis * headRotation

                // Set device anchor and depth range for compositor reprojection
                drawable.deviceAnchor = deviceAnchor
                drawable.depthRange = SIMD2(256.0, 0.03125)  // reverse-Z: (far, near)

                guard let cmd = renderer.cmdQueue.makeCommandBuffer() else { continue }

                for viewIndex in 0..<drawable.views.count {
                    let texture = drawable.colorTextures[viewIndex]
                    let view = drawable.views[viewIndex]

                    // Per-eye offset from device center (IPD / stereo)
                    let eyeTransform = view.transform
                    let eyeOffset = SIMD3(eyeTransform.columns.3.x,
                                          eyeTransform.columns.3.y,
                                          eyeTransform.columns.3.z)
                    let eyePos = camPos + orient * eyeOffset

                    // View matrix: inverse of the combined orientation placed at eye position
                    let r = orient
                    let viewMatrix = simd_float4x4(columns: (
                        SIMD4(r.columns.0.x, r.columns.1.x, r.columns.2.x, 0),
                        SIMD4(r.columns.0.y, r.columns.1.y, r.columns.2.y, 0),
                        SIMD4(r.columns.0.z, r.columns.1.z, r.columns.2.z, 0),
                        SIMD4(-dot(r.columns.0, eyePos),
                               -dot(r.columns.1, eyePos),
                               -dot(r.columns.2, eyePos), 1)
                    ))

                    // Per-eye asymmetric projection from compositor
                    let projMatrix = drawable.computeProjection(viewIndex: viewIndex)
                    let vp = projMatrix * viewMatrix

                    renderer.renderFrame(commandBuffer: cmd, outputTexture: texture,
                                        viewProjection: vp, size: size)
                }

                drawable.encodePresent(commandBuffer: cmd)
                cmd.commit()
            }

            frame.endSubmission()
        }

        // Render loop exited — ensure cleanup
        if !isStopped {
            Task { @MainActor in
                self.stop()
            }
        }
    }

}
#endif
