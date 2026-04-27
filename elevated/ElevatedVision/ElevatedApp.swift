// ElevatedApp.swift
// SwiftUI app entry point for visionOS immersive experience.
// WindowGroup provides MTKView-based rendering (works in simulator).
// ImmersiveSpace provides CompositorServices rendering on device.

#if os(visionOS)
import SwiftUI
import CompositorServices

@Observable @MainActor
class AppState {
    var renderer: ImmersiveRenderer?
    var debug = DebugState()
}

@Observable @MainActor
final class DebugState {
    var time: Double = 0
    var fps: Double = 0
    var cameraPos = SIMD3<Float>(0, 0, 0)
    var minNearPlane: Float = 0
    var depthRange = SIMD2<Float>(0, 0)
    var renderSize: CGSize = .zero
    var frameCount: Int = 0
    var notes: String = ""
}

public struct ElevatedApp: App {
    @State private var appState = AppState()

    public init() {}

    public var body: some Scene {
        WindowGroup {
            ImmersiveLauncher()
        }

        WindowGroup(id: "debug") {
            DebugOverlay(state: appState.debug)
        }
        .windowResizability(.contentSize)

        ImmersiveSpace(id: "elevated") {
            CompositorLayer(configuration: ContentConfiguration()) { layerRenderer in
                Task { @MainActor in
                    // Stop any previous renderer (e.g. re-entering immersive space)
                    appState.renderer?.stop()

                    do {
                        sharedDebugState = appState.debug
                        let renderer = try ImmersiveRenderer(layerRenderer: layerRenderer)
                        appState.renderer = renderer
                        await renderer.start()
                        // Run the render loop off the main actor so SwiftUI updates
                        // (debug overlay, scene events) can keep running.
                        Task.detached(priority: .userInitiated) {
                            renderer.renderLoop(layerRenderer)
                            await MainActor.run {
                                renderer.stop()
                                if appState.renderer === renderer {
                                    appState.renderer = nil
                                }
                            }
                        }
                    } catch {
                        print("[ElevatedApp] Failed to create renderer: \(error)")
                    }
                }
            }
        }
        .immersionStyle(selection: .constant(.full), in: .full)
    }
}

/// Auto-opens the immersive space and dismisses the launch window. Also pops
/// the debug overlay so screen captures include live state.
struct ImmersiveLauncher: View {
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Color.clear
            .task {
                openWindow(id: "debug")
                let result = await openImmersiveSpace(id: "elevated")
                if case .opened = result {
                    dismissWindow()
                }
            }
    }
}

/// Floating debug HUD. Updates every frame from the renderer.
struct DebugOverlay: View {
    @Bindable var state: DebugState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Elevated — debug").font(.headline)
            Group {
                Text(String(format: "time      %.2f s", state.time))
                Text(String(format: "fps       %.1f", state.fps))
                Text(String(format: "frame     %d", state.frameCount))
                Text(String(format: "size      %.0f×%.0f", state.renderSize.width, state.renderSize.height))
                Text(String(format: "minNear   %.4f m", state.minNearPlane))
                Text(String(format: "depth     far=%.2f near=%.4f", state.depthRange.x, state.depthRange.y))
                Text(String(format: "cam       %.2f %.2f %.2f", state.cameraPos.x, state.cameraPos.y, state.cameraPos.z))
            }
            .font(.system(.body, design: .monospaced))
            if !state.notes.isEmpty { Text(state.notes).foregroundStyle(.yellow) }
        }
        .padding(20)
        .frame(minWidth: 380)
    }
}

/// Captured `supportedMinimumNearPlaneDistance` from the configuration callback,
/// read by `ImmersiveRenderer` when setting per-drawable depth range. Fallback
/// `1.0 m` matches the typical visionOS floor.
nonisolated(unsafe) var capturedMinNearPlane: Float = 1.0

/// Pointer the immersive render loop pushes per-frame state into so the
/// SwiftUI debug overlay can render it. `MainActor`-bound; the render loop
/// dispatches updates via `Task { @MainActor in ... }`.
nonisolated(unsafe) var sharedDebugState: DebugState?

struct ContentConfiguration: CompositorLayerConfiguration {
    func makeConfiguration(capabilities: LayerRenderer.Capabilities,
                          configuration: inout LayerRenderer.Configuration) {
        let supportsFoveation = capabilities.supportsFoveation
        configuration.depthFormat = .depth32Float
        configuration.colorFormat = .bgra8Unorm_srgb
        configuration.isFoveationEnabled = supportsFoveation
        let options: LayerRenderer.Capabilities.SupportedLayoutsOptions = supportsFoveation ? [.foveationEnabled] : []
        let layouts = capabilities.supportedLayouts(options: options)
        configuration.layout = layouts.contains(.dedicated) ? .dedicated : .shared
        capturedMinNearPlane = capabilities.supportedMinimumNearPlaneDistance
    }
}
#endif
