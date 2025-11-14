#if os(iOS) || os(macOS)

import SwiftUI
import MetalKit

#if os(macOS)
private typealias ViewRepresentable = NSViewRepresentable
#elseif os(iOS)
private typealias ViewRepresentable = UIViewRepresentable
#endif

struct MetalKitSceneView: ViewRepresentable {
    var modelIdentifier: ModelIdentifier?
    @AppStorage("enableFileMonitoring") private var enableFileMonitoring = true

    class Coordinator {
        var renderer: MetalKitSceneRenderer?
#if os(macOS)
        var cameraController: CameraController?
#endif
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

#if os(macOS)
    func makeNSView(context: NSViewRepresentableContext<MetalKitSceneView>) -> MTKView {
        makeView(context.coordinator)
    }
#elseif os(iOS)
    func makeUIView(context: UIViewRepresentableContext<MetalKitSceneView>) -> MTKView {
        makeView(context.coordinator)
    }
#endif

    private func makeView(_ coordinator: Coordinator) -> MTKView {
#if os(macOS)
        let metalKitView = ControlledMTKView()
#else
        let metalKitView = MTKView()
#endif

        if let metalDevice = MTLCreateSystemDefaultDevice() {
            metalKitView.device = metalDevice
        }

        guard let renderer = MetalKitSceneRenderer(metalKitView) else {
            return metalKitView
        }
        renderer.enableFileMonitoring = enableFileMonitoring
        coordinator.renderer = renderer
        metalKitView.delegate = renderer

#if os(macOS)
        // Create camera controller
        // The original view matrix pattern is: translation(0,0,-8) * rotation * calibration
        // This means the model is at (0, 0, -8) in world space
        // The camera should be at origin looking at the model
        // After calibration (180° rotation around Z), the coordinate system is rotated,
        // so we may need to adjust initial orientation, but let's start with default
        let cameraController = CameraController(
            position: SIMD3<Float>(0, 0, 0),
            yaw: 0,
            pitch: 0
        )
        coordinator.cameraController = cameraController
        renderer.cameraController = cameraController
        
        // Connect camera controller to the view
        metalKitView.cameraController = cameraController
#endif

        Task {
            do {
                try await renderer.load(modelIdentifier)
            } catch {
                print("Error loading model: \(error.localizedDescription)")
            }
        }

        return metalKitView
    }

#if os(macOS)
    func updateNSView(_ view: MTKView, context: NSViewRepresentableContext<MetalKitSceneView>) {
        updateView(context.coordinator)
    }
#elseif os(iOS)
    func updateUIView(_ view: MTKView, context: UIViewRepresentableContext<MetalKitSceneView>) {
        updateView(context.coordinator)
    }
#endif

    private func updateView(_ coordinator: Coordinator) {
        guard let renderer = coordinator.renderer else { return }
        renderer.enableFileMonitoring = enableFileMonitoring
        Task {
            do {
                try await renderer.load(modelIdentifier)
            } catch {
                print("Error loading model: \(error.localizedDescription)")
            }
        }
    }
}

#endif // os(iOS) || os(macOS)
