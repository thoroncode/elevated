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

    public init(layerRenderer: LayerRenderer) throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal not available")
        }

        // Create a temporary MTKView for Renderer pipeline/resource init.
        // Use .bgra8Unorm so the postPSO matches the .bgra8Unorm texture
        // views we create from the sRGB drawable (avoids double-gamma).
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

            // Get head pose for reprojection
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

            guard let cmd = renderer.cmdQueue.makeCommandBuffer() else { continue }

            for viewIndex in 0..<drawable.views.count {
                let srgbTexture = drawable.colorTextures[viewIndex]

                // Create a .bgra8Unorm view of the sRGB drawable texture.
                // The shader already outputs gamma-corrected values (like macOS),
                // so we write raw bytes to avoid double-gamma from sRGB encoding.
                let outputTexture = srgbTexture.makeTextureView(pixelFormat: .bgra8Unorm)
                                    ?? srgbTexture

                // Per-eye projection from CompositorServices
                let projMatrix = drawable.computeProjection(
                    convention: .rightUpForward, viewIndex: viewIndex)

                // Fixed demo camera — preplanned flight path, no head tracking
                let viewMatrix = lookAtLH(eye: camPos, center: camTarget, up: SIMD3(0, 1, 0))
                let vp = projMatrix * viewMatrix

                renderer.renderFrame(commandBuffer: cmd, outputTexture: outputTexture,
                                    viewProjection: vp, size: size)
            }

            drawable.encodePresent(commandBuffer: cmd)
            cmd.commit()

            frame.endSubmission()
        }
    }

}
#endif
