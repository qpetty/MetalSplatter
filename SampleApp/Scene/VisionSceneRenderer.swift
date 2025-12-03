#if os(visionOS)

import CompositorServices
import Metal
import MetalSplatter
import os
import SampleBoxRenderer
import simd
import Spatial
import SwiftUI

extension LayerRenderer.Clock.Instant.Duration {
    var timeInterval: TimeInterval {
        let nanoseconds = TimeInterval(components.attoseconds / 1_000_000_000)
        return TimeInterval(components.seconds) + (nanoseconds / TimeInterval(NSEC_PER_SEC))
    }
}

class VisionSceneRenderer {
    private static let log =
        Logger(subsystem: Bundle.main.bundleIdentifier!,
               category: "VisionSceneRenderer")

    let layerRenderer: LayerRenderer
    let device: MTLDevice
    let commandQueue: MTLCommandQueue

    var model: ModelIdentifier?
    var modelRenderer: (any ModelRenderer)?

    var lastRotationUpdateTimestamp: Date? = nil
    var rotation: Angle = .zero
    
    var modelOrientation = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
    var modelScale: Float = 1.0
    let minimumModelScale: Float = 0.25
    let maximumModelScale: Float = 4.0

    var activeTranslationEventID: SpatialEventCollection.Event.ID?
    var pinchStates: [SpatialEventCollection.Event.ID: PinchState] = [:]
    var twoHandGestureState: TwoHandGestureState?

    let arSession: ARKitSession
    let worldTracking: WorldTrackingProvider
    
    var isDragging: Bool = false
    var gestureJustStarted: Bool = false
    
//    var modelPosition = SIMD3<Float>(0.0, 0.0, Constants.modelCenterZ)
    var modelPosition = SIMD3<Float>(0.0, 0.0, -2)
    var modelRadius = 1.0 as Float
    var dragStartPosition: SIMD3<Float>?
    var previousLocation: SIMD3<Float>?
    var initialHitPoint: Point3D?
    var hitPointOffset: SIMD3<Float>? // Offset from model center to hit point

    struct PinchState {
        let id: SpatialEventCollection.Event.ID
        var location: SIMD3<Float>
        var kind: SpatialEventCollection.Event.Kind
    }
    
    struct TwoHandGestureState {
        let firstID: SpatialEventCollection.Event.ID
        let secondID: SpatialEventCollection.Event.ID
        let initialDistance: Float
        let initialScale: Float
        let initialOrientation: simd_quatf
        let initialDirection: SIMD2<Float>?
        
        func contains(_ id: SpatialEventCollection.Event.ID) -> Bool {
            id == firstID || id == secondID
        }
    }

    init(_ layerRenderer: LayerRenderer) {
        self.layerRenderer = layerRenderer
        self.device = layerRenderer.device
        self.commandQueue = self.device.makeCommandQueue()!

        worldTracking = WorldTrackingProvider()
        arSession = ARKitSession()
        
        NotificationCenter.default.addObserver(forName: Constants.plyReceivedNotificationName, object: nil, queue: nil) { [weak self] notification in
            self?.handlePLYReceived(notification)
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func handlePLYReceived(_ notification: Notification) {
        guard let url = notification.userInfo?["url"] as? URL else { return }
        
        Task {
            do {
                if let splatRenderer = self.modelRenderer as? SplatRenderer {
                    Self.log.info("Preparing replacement renderer for PLY: \(url.lastPathComponent)")
                    
                    let replacementRenderer = try self.makeSplatRenderer()
                    replacementRenderer.highQualityDepth = splatRenderer.highQualityDepth
                    replacementRenderer.clearColor = splatRenderer.clearColor
                    replacementRenderer.onSortStart = splatRenderer.onSortStart
                    replacementRenderer.onSortComplete = splatRenderer.onSortComplete
                    
                    try await replacementRenderer.read(from: url)
                    
                    Self.log.info("Switching to replacement renderer for PLY: \(url.lastPathComponent)")
                    self.modelRenderer = replacementRenderer
                    self.modelRadius = replacementRenderer.modelRadius
                } else {
                    Self.log.info("Loading new PLY: \(url.lastPathComponent)")
                    try await self.load(.gaussianSplat(url))
                }
            } catch {
                Self.log.error("Failed to reload PLY: \(error.localizedDescription)")
            }
        }
    }

    func load(_ model: ModelIdentifier?) async throws {
        guard model != self.model else { return }
        self.model = model

        modelOrientation = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
        modelScale = 1.0
        twoHandGestureState = nil
        pinchStates.removeAll()
        activeTranslationEventID = nil
        isDragging = false
        gestureJustStarted = false
        dragStartPosition = nil
        previousLocation = nil
        initialHitPoint = nil
        hitPointOffset = nil

        modelRenderer = nil
        switch model {
        case .gaussianSplat(let url):
            let splat = try makeSplatRenderer()
            // Convert SPZ to PLY if needed
            let loadURL = try SPZConverter.convertIfNeeded(url)
            try await splat.read(from: loadURL)
            modelRenderer = splat
            // Center the model in world space
            if let splatRenderer = splat as? SplatRenderer {
                modelPosition = SIMD3<Float>(0.0, 0.0, -2) // Keep initial position
                print("splat count: \(splatRenderer.splatCount)")
            }
            
            modelRadius = splat.modelRadius
            
        case .sampleBox:
            modelRenderer = try! SampleBoxRenderer(device: device,
                                                   colorFormat: layerRenderer.configuration.colorFormat,
                                                   depthFormat: layerRenderer.configuration.depthFormat,
                                                   sampleCount: 1,
                                                   maxViewCount: layerRenderer.properties.viewCount,
                                                   maxSimultaneousRenders: Constants.maxSimultaneousRenders)
        case .streaming:
            break
        case .none:
            break
        }
    }
    
    private func makeSplatRenderer() throws -> SplatRenderer {
        try SplatRenderer(device: device,
                          colorFormat: layerRenderer.configuration.colorFormat,
                          depthFormat: layerRenderer.configuration.depthFormat,
                          sampleCount: 1,
                          maxViewCount: layerRenderer.properties.viewCount,
                          maxSimultaneousRenders: Constants.maxSimultaneousRenders)
    }
    
    // Force reload even if model URL is the same (for streaming updates)
    func reload() async throws {
        guard let model = self.model else { return }
        // Temporarily clear model to force reload
        let currentModel = model
        self.model = nil
        try await load(currentModel)
    }

    func startRenderLoop() {
        Task {
            do {
                try await arSession.run([worldTracking])
            } catch {
                fatalError("Failed to initialize ARSession")
            }

            let renderThread = Thread {
                self.renderLoop()
            }
            renderThread.name = "Render Thread"
            renderThread.start()
        }
    }

    private func viewports(drawable: LayerRenderer.Drawable, deviceAnchor: DeviceAnchor?) -> [ModelRendererViewportDescriptor] {
        let autoRotationMatrix = matrix4x4_rotation(radians: Float(rotation.radians),
                                                    axis: Constants.rotationAxis)
        let userRotationMatrix = simd_float4x4(modelOrientation)
        let scaleMatrix = matrix4x4_uniform_scale(modelScale)
//        let translationMatrix = matrix4x4_translation(0.0, 0.0, Constants.modelCenterZ)
        let worldTranslation = matrix4x4_translation(modelPosition.x, modelPosition.y, modelPosition.z);
        let translationMatrix = worldTranslation;
        // Turn common 3D GS PLY files rightside-up. This isn't generally meaningful, it just
        // happens to be a useful default for the most common datasets at the moment.
        let commonUpCalibration = matrix4x4_rotation(radians: .pi, axis: SIMD3<Float>(0, 0, 1))
        let modelMatrix = translationMatrix * userRotationMatrix * autoRotationMatrix * commonUpCalibration * scaleMatrix

        let simdDeviceAnchor = deviceAnchor?.originFromAnchorTransform ?? matrix_identity_float4x4
        
        return drawable.views.enumerated().map { (index, view) in
            let userViewpointMatrix = (simdDeviceAnchor * view.transform).inverse
            
            let projectionMatrix = drawable.computeProjection(viewIndex: index)
            
            let screenSize = SIMD2(x: Int(view.textureMap.viewport.width),
                                   y: Int(view.textureMap.viewport.height))
            return ModelRendererViewportDescriptor(viewport: view.textureMap.viewport,
                                                  projectionMatrix: projectionMatrix,
                                                  viewMatrix: userViewpointMatrix * modelMatrix,
                                                  screenSize: screenSize)
        }
    }

    private func updateRotation() {
        let now = Date()
        defer {
            lastRotationUpdateTimestamp = now
        }

        guard let lastRotationUpdateTimestamp else { return }
        rotation += Constants.rotationPerSecond * now.timeIntervalSince(lastRotationUpdateTimestamp)
    }

    func renderFrame() {
        guard let frame = layerRenderer.queryNextFrame() else { return }

        guard let timing = frame.predictTiming() else { return }
        
        frame.startUpdate()
//        updateRotation()
        frame.endUpdate()

        LayerRenderer.Clock().wait(until: timing.optimalInputTime)
        
        frame.startSubmission()

        let drawables = frame.queryDrawables()
        
        if drawables.isEmpty {
            return
        }

        let presentationTime = LayerRenderer.Clock.Instant.epoch.duration(to: timing.presentationTime).timeInterval
        let deviceAnchor = worldTracking.queryDeviceAnchor(atTimestamp: presentationTime)

        for drawable in drawables {
            drawable.deviceAnchor = deviceAnchor
            
            let viewports = self.viewports(drawable: drawable, deviceAnchor: deviceAnchor)
            
            guard let commandBuffer = commandQueue.makeCommandBuffer() else {
                fatalError("Failed to create command buffer")
            }
            
            do {
                try modelRenderer?.render(viewports: viewports,
                                          colorTexture: drawable.colorTextures[0],
                                          colorStoreAction: .store,
                                          depthTexture: drawable.depthTextures[0],
                                          rasterizationRateMap: drawable.rasterizationRateMaps.first,
                                          renderTargetArrayLength: layerRenderer.configuration.layout == .layered ? drawable.views.count : 1,
                                          to: commandBuffer)
            } catch {
                Self.log.error("Unable to render scene: \(error.localizedDescription)")
            }

            drawable.encodePresent(commandBuffer: commandBuffer)
            commandBuffer.commit()
        }

        frame.endSubmission()
    }

    func renderLoop() {
        while true {
            if layerRenderer.state == .invalidated {
                Self.log.warning("Layer is invalidated")
                return
            } else if layerRenderer.state == .paused {
                layerRenderer.waitUntilRunning()
                continue
            } else {
                autoreleasepool {
                    self.renderFrame()
                }
            }
        }
    }
}

#endif // os(visionOS)

