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
    private var isRunning = false

    public init(layerRenderer: LayerRenderer) throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal not available")
        }

        // Create a temporary MTKView for Renderer pipeline/resource init
        let tempView = MTKView(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), device: device)
        tempView.colorPixelFormat = .bgra8Unorm_srgb
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
            LayerRenderer.Clock().sleep(until: timing.optimalInputTime)

            guard let drawable = frame.queryDrawable() else { continue }
            drawable.encodeWaitForPresentation(using: drawable.commandBuffer!)

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

            for viewIndex in 0..<drawable.views.count {
                let view = drawable.views[viewIndex]
                let texture = drawable.colorTextures[viewIndex]

                // Per-eye projection from tangents
                let tangents = view.tangents
                let projMatrix = makeProjection(
                    left: tangents.left, right: tangents.right,
                    top: tangents.top, bottom: tangents.bottom,
                    near: 0.03125, far: 256.0
                )

                // View matrix from head tracking
                var viewMatrix: simd_float4x4
                if let anchor = deviceAnchor {
                    let headTransform = anchor.originFromAnchorTransform
                    let headRotation = simd_float3x3(
                        SIMD3(headTransform.columns.0.x, headTransform.columns.0.y, headTransform.columns.0.z),
                        SIMD3(headTransform.columns.1.x, headTransform.columns.1.y, headTransform.columns.1.z),
                        SIMD3(headTransform.columns.2.x, headTransform.columns.2.y, headTransform.columns.2.z)
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

            drawable.encodePresent(using: drawable.commandBuffer!)
            drawable.commandBuffer!.commit()
        }
    }

    /// Build a perspective projection from asymmetric tangent values.
    private nonisolated func makeProjection(left: Float, right: Float,
                                            top: Float, bottom: Float,
                                            near: Float, far: Float) -> simd_float4x4 {
        let l = left * near
        let r = right * near
        let t = top * near
        let b = bottom * near
        let w = r - l
        let h = t - b
        let d = far - near

        return simd_float4x4(columns: (
            SIMD4(2 * near / w, 0, 0, 0),
            SIMD4(0, 2 * near / h, 0, 0),
            SIMD4((r + l) / w, (t + b) / h, far / d, 1),
            SIMD4(0, 0, -near * far / d, 0)
        ))
    }
}
#endif
