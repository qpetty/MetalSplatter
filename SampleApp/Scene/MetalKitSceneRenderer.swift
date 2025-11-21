#if os(iOS) || os(macOS)

import Darwin
import Metal
import MetalKit
import MetalSplatter
import os
import SampleBoxRenderer
import simd
import SwiftUI

class MetalKitSceneRenderer: NSObject, MTKViewDelegate {
    private static let log =
        Logger(subsystem: Bundle.main.bundleIdentifier!,
               category: "MetalKitSceneRenderer")

    let metalKitView: MTKView
    let device: MTLDevice
    let commandQueue: MTLCommandQueue

    var model: ModelIdentifier?
    var modelRenderer: (any ModelRenderer)?
    var enableFileMonitoring: Bool = true

    let inFlightSemaphore = DispatchSemaphore(value: Constants.maxSimultaneousRenders)
    
    // File monitoring for automatic reload
    private var fileMonitorSource: DispatchSourceFileSystemObject?
    private var fileMonitorDescriptor: Int32?
    private var reloadWorkItem: DispatchWorkItem?

    var lastRotationUpdateTimestamp: Date? = nil
    var rotation: Angle = .zero

    var drawableSize: CGSize = .zero
    
#if os(macOS)
    var cameraController: CameraController?
    var lastMovementUpdateTimestamp: Date? = nil
#endif

    init?(_ metalKitView: MTKView) {
        self.device = metalKitView.device!
        guard let queue = self.device.makeCommandQueue() else { return nil }
        self.commandQueue = queue
        self.metalKitView = metalKitView
        metalKitView.colorPixelFormat = MTLPixelFormat.bgra8Unorm_srgb
        metalKitView.depthStencilPixelFormat = MTLPixelFormat.depth32Float
        metalKitView.sampleCount = 1
        metalKitView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    }
    
    deinit {
        tearDownFileMonitor()
    }

    private func setupFileMonitor(for url: URL) {
        // Tear down any existing monitor first
        tearDownFileMonitor()
        
        // Open file descriptor for monitoring
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else {
            Self.log.error("Failed to open file descriptor for monitoring: \(url.path)")
            return
        }
        
        fileMonitorDescriptor = descriptor
        
        // Create dispatch source for file system events
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: .write,
            queue: DispatchQueue.main
        )
        
        fileMonitorSource = source
        
        // Set up event handler with debouncing
        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            
            // Cancel any pending reload
            self.reloadWorkItem?.cancel()
            
            // Create new reload work item with 0.5s delay
            let workItem = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                Task {
                    await self.reloadCurrentModel()
                }
            }
            
            self.reloadWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
        }
        
        // Set up cancel handler to close file descriptor
        source.setCancelHandler { [weak self] in
            guard let self = self, let descriptor = self.fileMonitorDescriptor else { return }
            close(descriptor)
            self.fileMonitorDescriptor = nil
        }
        
        // Start monitoring
        source.resume()
        
        Self.log.info("Started file monitoring for: \(url.path)")
    }
    
    private func tearDownFileMonitor() {
        // Cancel pending reload
        reloadWorkItem?.cancel()
        reloadWorkItem = nil
        
        // Cancel and release dispatch source
        fileMonitorSource?.cancel()
        fileMonitorSource = nil
        
        // File descriptor will be closed by cancel handler
    }
    
    private func reloadCurrentModel() async {
        guard case .gaussianSplat(let url) = model else {
            return
        }
        
        Self.log.info("Reloading model from: \(url.path)")
        
        do {
            // Create new splat renderer
            let splat = try await SplatRenderer(device: device,
                                                colorFormat: metalKitView.colorPixelFormat,
                                                depthFormat: metalKitView.depthStencilPixelFormat,
                                                sampleCount: metalKitView.sampleCount,
                                                maxViewCount: 1,
                                                maxSimultaneousRenders: Constants.maxSimultaneousRenders)
            try await splat.read(from: url)
            
            // Only update if we still have the same model
            if case .gaussianSplat(let currentUrl) = model, currentUrl == url {
                modelRenderer = splat
                Self.log.info("Successfully reloaded model from: \(url.path)")
            }
        } catch {
            Self.log.error("Failed to reload model from \(url.path): \(error.localizedDescription)")
            // Keep the old model renderer intact on error
        }
    }

    func load(_ model: ModelIdentifier?) async throws {
        let isModelChange = model != self.model
        
        if isModelChange {
            // Tear down file monitor for previous model
            tearDownFileMonitor()
            self.model = model
            modelRenderer = nil
        }
        
        // Handle file monitoring preference changes for existing Gaussian splat models
        if !isModelChange, case .gaussianSplat(let url) = model {
            if enableFileMonitoring && fileMonitorSource == nil {
                // Monitoring was enabled but not set up
                setupFileMonitor(for: url)
            } else if !enableFileMonitoring && fileMonitorSource != nil {
                // Monitoring was disabled but still active
                tearDownFileMonitor()
            }
        }

        switch model {
        case .gaussianSplat(let url):
            if isModelChange {
                let splat = try await SplatRenderer(device: device,
                                                    colorFormat: metalKitView.colorPixelFormat,
                                                    depthFormat: metalKitView.depthStencilPixelFormat,
                                                    sampleCount: metalKitView.sampleCount,
                                                    maxViewCount: 1,
                                                    maxSimultaneousRenders: Constants.maxSimultaneousRenders)
                try await splat.read(from: url)
                modelRenderer = splat
                
                // Set up file monitoring for Gaussian splat files if enabled
                if enableFileMonitoring {
                    setupFileMonitor(for: url)
                }
            }
        case .sampleBox:
            if isModelChange {
                modelRenderer = try! await SampleBoxRenderer(device: device,
                                                             colorFormat: metalKitView.colorPixelFormat,
                                                             depthFormat: metalKitView.depthStencilPixelFormat,
                                                             sampleCount: metalKitView.sampleCount,
                                                             maxViewCount: 1,
                                                             maxSimultaneousRenders: Constants.maxSimultaneousRenders)
                // No file monitoring for sample box
            }
        case .streaming:
            break
        case .none:
            break
        }
    }

    private var viewport: ModelRendererViewportDescriptor {
        let projectionMatrix = matrix_perspective_right_hand(fovyRadians: Float(Constants.fovy.radians),
                                                             aspectRatio: Float(drawableSize.width / drawableSize.height),
                                                             nearZ: 0.1,
                                                             farZ: 100.0)

        // Turn common 3D GS PLY files rightside-up. This isn't generally meaningful, it just
        // happens to be a useful default for the most common datasets at the moment.
        let commonUpCalibration = matrix4x4_rotation(radians: .pi, axis: SIMD3<Float>(0, 0, 1))

        let viewMatrix: matrix_float4x4
#if os(macOS)
        if let cameraController = cameraController {
            viewMatrix = cameraController.getViewMatrix() * commonUpCalibration
        } else {
            // Fallback to auto-rotation if camera controller is not set
            let rotationMatrix = matrix4x4_rotation(radians: Float(rotation.radians),
                                                    axis: Constants.rotationAxis)
            let translationMatrix = matrix4x4_translation(0.0, 0.0, Constants.modelCenterZ)
            viewMatrix = translationMatrix * rotationMatrix * commonUpCalibration
        }
#else
        let rotationMatrix = matrix4x4_rotation(radians: Float(rotation.radians),
                                                axis: Constants.rotationAxis)
        let translationMatrix = matrix4x4_translation(0.0, 0.0, Constants.modelCenterZ)
        viewMatrix = translationMatrix * rotationMatrix * commonUpCalibration
#endif

        let viewport = MTLViewport(originX: 0, originY: 0, width: drawableSize.width, height: drawableSize.height, znear: 0, zfar: 1)

        return ModelRendererViewportDescriptor(viewport: viewport,
                                               projectionMatrix: projectionMatrix,
                                               viewMatrix: viewMatrix,
                                               screenSize: SIMD2(x: Int(drawableSize.width), y: Int(drawableSize.height)))
    }

    private func updateRotation() {
        let now = Date()
        defer {
            lastRotationUpdateTimestamp = now
        }

        guard let lastRotationUpdateTimestamp else { return }
        rotation += Constants.rotationPerSecond * now.timeIntervalSince(lastRotationUpdateTimestamp)
    }
    
#if os(macOS)
    private func updateCameraMovement() {
        guard let cameraController = cameraController else {
            // Fallback to auto-rotation if camera controller is not set
            updateRotation()
            return
        }
        
        let now = Date()
        defer {
            lastMovementUpdateTimestamp = now
        }
        
        guard let lastMovementUpdateTimestamp = lastMovementUpdateTimestamp else {
            return
        }
        
        let deltaTime = now.timeIntervalSince(lastMovementUpdateTimestamp)
        
        cameraController.updateMovement(deltaTime: deltaTime)
    }
#endif

    func draw(in view: MTKView) {
        guard let modelRenderer else { return }
        guard let drawable = view.currentDrawable else { return }

        _ = inFlightSemaphore.wait(timeout: DispatchTime.distantFuture)

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            inFlightSemaphore.signal()
            return
        }

        let semaphore = inFlightSemaphore
        commandBuffer.addCompletedHandler { (_ commandBuffer)-> Swift.Void in
            semaphore.signal()
        }

#if os(macOS)
        updateCameraMovement()
#else
        updateRotation()
#endif

        do {
            try modelRenderer.render(viewports: [viewport],
                                     colorTexture: view.multisampleColorTexture ?? drawable.texture,
                                     colorStoreAction: view.multisampleColorTexture == nil ? .store : .multisampleResolve,
                                     depthTexture: view.depthStencilTexture,
                                     rasterizationRateMap: nil,
                                     renderTargetArrayLength: 0,
                                     to: commandBuffer)
        } catch {
            Self.log.error("Unable to render scene: \(error.localizedDescription)")
        }

        commandBuffer.present(drawable)

        commandBuffer.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        drawableSize = size
    }
}

#endif // os(iOS) || os(macOS)

