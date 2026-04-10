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
}

public struct ElevatedApp: App {
    @State private var immersionStyle: ImmersionStyle = .full
    @State private var appState = AppState()

    public init() {}

    public var body: some Scene {
        WindowGroup {
            ImmersiveLauncher()
        }

        ImmersiveSpace(id: "elevated") {
            CompositorLayer(configuration: ContentConfiguration()) { layerRenderer in
                Task { @MainActor in
                    // Stop any previous renderer (e.g. re-entering immersive space)
                    appState.renderer?.stop()

                    do {
                        let renderer = try ImmersiveRenderer(layerRenderer: layerRenderer)
                        appState.renderer = renderer
                        await renderer.start()
                        renderer.renderLoop(layerRenderer)
                        // renderLoop returned — clean up
                        renderer.stop()
                        if appState.renderer === renderer {
                            appState.renderer = nil
                        }
                    } catch {
                        print("[ElevatedApp] Failed to create renderer: \(error)")
                    }
                }
            }
        }
        .immersionStyle(selection: $immersionStyle, in: .full)
    }
}

/// Auto-opens the immersive space and dismisses the launch window.
struct ImmersiveLauncher: View {
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Color.clear
            .task {
                let result = await openImmersiveSpace(id: "elevated")
                if case .opened = result {
                    dismissWindow()
                }
            }
    }
}

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
    }
}
#endif
