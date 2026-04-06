// ElevatedApp.swift
// SwiftUI app entry point for visionOS immersive experience.

#if os(visionOS)
import SwiftUI
import CompositorServices

public struct ElevatedApp: App {
    @State private var immersionStyle: ImmersionStyle = .full

    public init() {}

    public var body: some Scene {
        WindowGroup {
            ImmersiveLauncher()
        }

        ImmersiveSpace(id: "elevated") {
            CompositorLayer(configuration: ContentConfiguration()) { layerRenderer in
                Task { @MainActor in
                    do {
                        let renderer = try ImmersiveRenderer(layerRenderer: layerRenderer)
                        await renderer.start()
                        renderer.renderLoop(layerRenderer)
                    } catch {
                        print("[ElevatedApp] Failed to create renderer: \(error)")
                    }
                }
            }
        }
        .immersionStyle(selection: $immersionStyle, in: .full)
    }
}

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
        configuration.colorFormat = .bgra8Unorm
        configuration.isFoveationEnabled = supportsFoveation
        let options: LayerRenderer.Capabilities.SupportedLayoutsOptions = supportsFoveation ? [.foveationEnabled] : []
        let layouts = capabilities.supportedLayouts(options: options)
        configuration.layout = layouts.contains(.dedicated) ? .dedicated : .shared
    }
}
#endif
