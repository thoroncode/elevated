// ImmersiveRenderer.swift
// Immersive Metal renderer for visionOS using CompositorServices.
// Fly through the Elevated terrain with head-tracked free look.

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

    public init(layerRenderer: LayerRenderer) throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal not available")
        }

        // Create a temporary MTKView for Renderer pipeline/resource init
        let tempView = MTKView(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), device: device)
        tempView.colorPixelFormat = .bgra8Unorm
        tempView.depthStencilPixelFormat = .depth32Float
        renderer = Renderer(mtkView: tempView, debug: false, capture: false)

        // Audio
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
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

    nonisolated public func renderLoop(_ layerRenderer: LayerRenderer) {
        while true {
            guard layerRenderer.state == .running else {
                if layerRenderer.state == .paused {
                    layerRenderer.waitUntilRunning()
                    continue
                }
                break  // .invalidated
            }

            guard let frame = layerRenderer.queryNextFrame() else { continue }
            frame.startUpdate()

            // Get head pose
            let deviceAnchor = worldTracking.queryDeviceAnchor(atTimestamp: CACurrentMediaTime())

            frame.endUpdate()
            guard let timing = frame.predictTiming() else { continue }
            LayerRenderer.Clock().wait(until: timing.optimalInputTime, tolerance: nil)

            guard let drawable = frame.queryDrawable() else { continue }

            frame.startSubmission()

            let time = renderer.currentTime
            if time >= kDemoDuration && isRunning {
                Task { @MainActor in
                    synth.seek(to: 0)
                    renderer.start()
                }
            }

            // Update sync-driven uniforms
            let tex = drawable.colorTextures[0]
            let size = CGSize(width: tex.width, height: tex.height)
            renderer.updateUniformsForTime(time, size: size)

            let camPos = renderer.demoCameraPosition
            let camTarget = renderer.demoCameraTarget

            // Set device anchor on drawable for reprojection
            drawable.deviceAnchor = deviceAnchor

            // Use a single command buffer for all eyes + present
            guard let cmd = renderer.cmdQueue.makeCommandBuffer() else { continue }

            for viewIndex in 0..<drawable.views.count {
                let texture = drawable.colorTextures[viewIndex]

                // Per-eye projection from CompositorServices
                let projMatrix = drawable.computeProjection(
                    convention: .rightUpForward, viewIndex: viewIndex)

                // View matrix: demo camera + head tracking
                let viewMatrix: simd_float4x4
                if let anchor = deviceAnchor {
                    let eyeTransform = anchor.originFromAnchorTransform * drawable.views[viewIndex].transform
                    let eyePos = SIMD3<Float>(eyeTransform.columns.3.x,
                                              eyeTransform.columns.3.y,
                                              eyeTransform.columns.3.z)
                    // Use demo camera position but apply head rotation for look direction
                    let headRotation = simd_float3x3(
                        SIMD3(eyeTransform.columns.0.x, eyeTransform.columns.0.y, eyeTransform.columns.0.z),
                        SIMD3(eyeTransform.columns.1.x, eyeTransform.columns.1.y, eyeTransform.columns.1.z),
                        SIMD3(eyeTransform.columns.2.x, eyeTransform.columns.2.y, eyeTransform.columns.2.z)
                    )

                    // Demo forward basis
                    let demoFwd = normalize(camTarget - camPos)
                    let demoRight = normalize(cross(SIMD3<Float>(0, 1, 0), demoFwd))
                    let demoUp = cross(demoFwd, demoRight)
                    let demoBasis = simd_float3x3(columns: (demoRight, demoUp, demoFwd))

                    let r = demoBasis * headRotation
                    // Offset eye position relative to head in demo space
                    let headPos = SIMD3<Float>(
                        anchor.originFromAnchorTransform.columns.3.x,
                        anchor.originFromAnchorTransform.columns.3.y,
                        anchor.originFromAnchorTransform.columns.3.z)
                    let eyeOffset = eyePos - headPos
                    let eye = camPos + demoBasis * eyeOffset

                    viewMatrix = simd_float4x4(columns: (
                        SIMD4(r.columns.0.x, r.columns.1.x, r.columns.2.x, 0),
                        SIMD4(r.columns.0.y, r.columns.1.y, r.columns.2.y, 0),
                        SIMD4(r.columns.0.z, r.columns.1.z, r.columns.2.z, 0),
                        SIMD4(-dot(r.columns.0, eye), -dot(r.columns.1, eye), -dot(r.columns.2, eye), 1)
                    ))
                } else {
                    viewMatrix = lookAtLH(eye: camPos, center: camTarget, up: SIMD3(0, 1, 0))
                }

                let vp = projMatrix * viewMatrix

                // Render all 3 passes into this eye's texture
                renderer.renderFrame(commandBuffer: cmd, outputTexture: texture,
                                    viewProjection: vp, size: size)
            }

            drawable.encodePresent(commandBuffer: cmd)
            cmd.commit()
            cmd.waitUntilCompleted()

            frame.endSubmission()
        }
    }

}
#endif
