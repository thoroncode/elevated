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

            // Demo forward direction
            let demoForward = normalize(camTarget - camPos)
            let demoRight = normalize(cross(SIMD3<Float>(0, 1, 0), demoForward))
            let demoUp = cross(demoForward, demoRight)
            let demoBasis = simd_float3x3(columns: (demoRight, demoUp, demoForward))

            // Set device anchor on drawable for reprojection
            drawable.deviceAnchor = deviceAnchor

            guard let presentCmd = renderer.cmdQueue.makeCommandBuffer() else { continue }

            for viewIndex in 0..<drawable.views.count {
                let texture = drawable.colorTextures[viewIndex]

                // Per-eye projection from CompositorServices (LH, near=0 far=1)
                let projMatrix = drawable.computeProjection(
                    convention: .rightUpForward, viewIndex: viewIndex)

                // View matrix from head tracking
                var viewMatrix: simd_float4x4
                if let anchor = deviceAnchor {
                    let headTransform = anchor.originFromAnchorTransform
                    // Per-eye view offset
                    let eyeTransform = drawable.views[viewIndex].transform
                    let viewTransform = headTransform * eyeTransform
                    let headRotation = simd_float3x3(
                        SIMD3(viewTransform.columns.0.x, viewTransform.columns.0.y, viewTransform.columns.0.z),
                        SIMD3(viewTransform.columns.1.x, viewTransform.columns.1.y, viewTransform.columns.1.z),
                        SIMD3(viewTransform.columns.2.x, viewTransform.columns.2.y, viewTransform.columns.2.z)
                    )

                    // Combine demo camera direction with head rotation
                    let r = demoBasis * headRotation
                    viewMatrix = simd_float4x4(columns: (
                        SIMD4(r.columns.0.x, r.columns.1.x, r.columns.2.x, 0),
                        SIMD4(r.columns.0.y, r.columns.1.y, r.columns.2.y, 0),
                        SIMD4(r.columns.0.z, r.columns.1.z, r.columns.2.z, 0),
                        SIMD4(-dot(r.columns.0, camPos), -dot(r.columns.1, camPos), -dot(r.columns.2, camPos), 1)
                    ))
                } else {
                    viewMatrix = lookAtLH(eye: camPos, center: camTarget, up: SIMD3(0, 1, 0))
                }

                let vp = projMatrix * viewMatrix

                guard let cmd = renderer.cmdQueue.makeCommandBuffer() else { continue }
                renderer.renderFrame(commandBuffer: cmd, outputTexture: texture,
                                    viewProjection: vp, size: size)
                cmd.commit()
            }

            drawable.encodePresent(commandBuffer: presentCmd)
            presentCmd.commit()

            frame.endSubmission()
        }
    }

}
#endif
