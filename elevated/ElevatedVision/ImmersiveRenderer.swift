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
            LayerRenderer.Clock().wait(until: timing.optimalInputTime, tolerance: nil)

            guard let drawable = frame.queryDrawable() else { continue }

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

            // Update sync-driven uniforms
            let tex = drawable.colorTextures[0]
            let size = CGSize(width: tex.width, height: tex.height)
            renderer.updateUniformsForTime(time, size: size)

            // Use the demo's own VP matrix (matching macOS exactly)
            // This includes the correct FOV, roll, and camera path.
            let demoVP = renderer.demoViewProjection

            // Set device anchor on drawable for reprojection
            drawable.deviceAnchor = deviceAnchor

            guard let cmd = renderer.cmdQueue.makeCommandBuffer() else { continue }

            for viewIndex in 0..<drawable.views.count {
                let texture = drawable.colorTextures[viewIndex]

                // Use demo's own view-projection for preplanned flight
                // (same as macOS — correct FOV, roll, camera path)
                renderer.renderFrame(commandBuffer: cmd, outputTexture: texture,
                                    viewProjection: demoVP, size: size)
            }

            drawable.encodePresent(commandBuffer: cmd)
            cmd.commit()

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
