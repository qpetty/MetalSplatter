#if os(visionOS)
import CompositorServices
#endif
import SwiftUI

@main
struct SampleApp: App {
//    var dragStartPosition = simd_float3()  // Optional: Anchor point for relative movement
    var body: some Scene {
        WindowGroup("MetalSplatter Sample App", id: "main") {
            ContentView()
        }

#if os(macOS)
        WindowGroup(for: ModelIdentifier.self) { modelIdentifier in
            MetalKitSceneView(modelIdentifier: modelIdentifier.wrappedValue)
                .navigationTitle(modelIdentifier.wrappedValue?.description ?? "No Model")
        }
#endif // os(macOS)

#if os(visionOS)
        ImmersiveSpace(for: ModelIdentifier.self) { modelIdentifier in
            CompositorLayer(configuration: ContentStageConfiguration()) { layerRenderer in
                let renderer = VisionSceneRenderer(layerRenderer)
                
                layerRenderer.onSpatialEvent = { eventCollection in
                    for event in eventCollection {
                        let locationSIMD = event.location3D.simd3  // Convert once per event
                                        
                        // Comprehensive logging
                        print("Event: kind=\(event.kind), phase=\(event.phase), location=\(event.location3D) (SIMD: \(locationSIMD))")
                        print("Selection ray: origin=\(event.selectionRay?.origin), dir=\(event.selectionRay?.direction)")
                        
                        switch event.kind {
//                        case .directPinch, .indirectPinch:
//                            handlePinch(event: event, locationSIMD: locationSIMD, renderer: renderer)
                        case .directPinch:
                            handlePinch(event: event, locationSIMD: event.location3D.simd3, renderer: renderer)
                        case .indirectPinch:
                            handleIndirectPinch(event: event, renderer: renderer)
                        case .touch:
                            handleTouchMovement(event: event, locationSIMD: locationSIMD, renderer: renderer)
                        default:
                            print("Unhandled kind: \(event.kind)")
                        }
                    }
                }
                
                Task {
                    do {
                        try await renderer.load(modelIdentifier.wrappedValue)
                    } catch {
                        print("Error loading model: \(error.localizedDescription)")
                    }
                    renderer.startRenderLoop()
                }
            }
        }
        .immersionStyle(selection: .constant(immersionStyle), in: immersionStyle)
#endif // os(visionOS)
    }

#if os(visionOS)
    var immersionStyle: ImmersionStyle {
        if #available(visionOS 2, *) {
            .mixed
        } else {
            .full
        }
    }
#endif // os(visionOS)
}

extension Point3D {
    var simd3: SIMD3<Float> {
        SIMD3<Float>(Float(x), Float(y), Float(z))
    }
}

extension Vector3D {
    var simd3: SIMD3<Float> {
        SIMD3<Float>(Float(x), Float(y), Float(z))
    }
}

private func handlePinch(event: SpatialEventCollection.Event, locationSIMD: SIMD3<Float>, renderer: VisionSceneRenderer) {
    let modelSIMD = renderer.modelPosition  // For distance calc
    
    switch event.phase {
    case .active:
        if !renderer.isDragging, let selectionRay = event.selectionRay {
            let handToModelDistance = distance(modelSIMD, event.location3D)
            print("Direct Pinch ACTIVE (start) - distance to model: \(handToModelDistance)m")
            
            let maxDistanceForInteraction: Float = 2.0
            if handToModelDistance > maxDistanceForInteraction {
                print("Ignoring event: too far (\(handToModelDistance)m)")
                return
            }
            
            if handToModelDistance > 0.15 {
                print("Direct pinch ignored: too far (\(handToModelDistance)m)")
                return
            }
            
            renderer.isDragging = true
            renderer.gestureJustStarted = true
            renderer.dragStartPosition = modelSIMD
            renderer.previousLocation = locationSIMD
        } else {
            // Update: Use hand pose (e.g., wrist joint) for delta
            // Update with delta from location3D (hand movement)
            guard let startPos = renderer.dragStartPosition,
                  let prevLoc = renderer.previousLocation else { return }
            
            let delta = locationSIMD - prevLoc
            let newPosition = startPos + delta
            print("Direct Pinch ACTIVE (update) - Delta: \(delta), New pos: \(newPosition)")
            
            renderer.modelPosition = newPosition
            renderer.previousLocation = locationSIMD
            renderer.gestureJustStarted = false
        }
    case .ended, .cancelled:
        print("Direct Pinch ENDED/CANCELLED - Final pos: \(renderer.modelPosition)")
        if event.phase == .cancelled && renderer.dragStartPosition != nil {
            renderer.modelPosition = renderer.dragStartPosition!
        }
        endDrag(renderer: renderer)
    @unknown default:
        break
    }
}

private func handleIndirectPinch(event: SpatialEventCollection.Event, renderer: VisionSceneRenderer) {
    switch event.phase {
    case .active:
        if !renderer.isDragging, let selectionRay = event.selectionRay {
            // Start: Raycast selectionRay to find hit on model
            guard let hitPoint = raycastToModel(using: selectionRay, modelPosition: renderer.modelPosition) else {
                print("Indirect Pinch ACTIVE (start) - No hit on model")
                return
            }
            let handToModelDistance = distance(renderer.modelPosition, hitPoint) // Or check ray origin distance
            print("Indirect Pinch ACTIVE (start) - Hit point: \(hitPoint), distance to model: \(handToModelDistance)m")
            
            let maxDistanceForInteraction: Float = 2.0
            if handToModelDistance > maxDistanceForInteraction {
                print("Ignoring event: too far (\(handToModelDistance)m)")
                return
            }
            
            renderer.isDragging = true
            renderer.gestureJustStarted = true
            renderer.dragStartPosition = renderer.modelPosition // Or offset from hit if needed
            renderer.previousLocation = hitPoint.simd3 // Use hit as initial "location"
            renderer.initialHitPoint = hitPoint // Store for reference
        } else {
            // Update: Use hand pose (e.g., wrist joint) for delta
            guard let inputDevicePose = event.inputDevicePose,
                  let startPos = renderer.dragStartPosition,
                  let prevLoc = renderer.previousLocation else {
                print("Indirect Pinch ACTIVE (update) - Missing inputDevicePose or prior data")
                return
            }
            
            let handPositionSIMD = inputDevicePose.pose3D.position.simd3
            let delta = handPositionSIMD - prevLoc
            let newPosition = startPos + delta
            print("Indirect Pinch ACTIVE (update) - Hand pos: \(handPositionSIMD), Delta: \(delta), New pos: \(newPosition)")
            
            renderer.modelPosition = newPosition
            renderer.previousLocation = handPositionSIMD
            renderer.gestureJustStarted = false
        }
    case .ended, .cancelled:
        print("Indirect Pinch ENDED/CANCELLED - Final pos: \(renderer.modelPosition)")
        if event.phase == .cancelled && renderer.dragStartPosition != nil {
            renderer.modelPosition = renderer.dragStartPosition!
        }
        endDrag(renderer: renderer)
    @unknown default:
        break
    }
}


// Example raycast helper (implement in VisionSceneRenderer; simplistic bounding box for demo—use full ray-model intersection for accuracy)
private func raycastToModel(using ray: Ray3D, modelPosition: SIMD3<Float>) -> Point3D? {
    // Ray: origin (head pos) + direction (gaze vector)
    let origin = ray.origin.simd3
    let direction = simd_normalize(ray.direction.simd3)
    
    // Simple sphere/BBox check against model (expand with your model's actual geometry)
    let modelRadius: Float = 1.0 // Tune to your model size
    let modelCenter = modelPosition
    let oc = modelCenter - origin
    let t = simd_dot(oc, direction)
    let closest = origin + t * direction
    let distSq = simd_length_squared(closest - modelCenter)
    
    if distSq <= modelRadius * modelRadius {
        return Point3D(x: closest.x, y: closest.y, z: closest.z)
    }
    return nil
}

private func handleTouchMovement(event: SpatialEventCollection.Event, locationSIMD: SIMD3<Float>, renderer: VisionSceneRenderer) {
    if renderer.isDragging, let startPos = renderer.dragStartPosition, let prevLoc = renderer.previousLocation {
        let delta = locationSIMD - prevLoc
        let newPosition = startPos + delta
        print("Touch movement - Delta: \(delta), New pos: \(newPosition)")
        renderer.modelPosition = newPosition
        renderer.previousLocation = locationSIMD
    }
}

private func endDrag(renderer: VisionSceneRenderer) {
    renderer.isDragging = false
    renderer.gestureJustStarted = false
    renderer.dragStartPosition = nil
    renderer.previousLocation = nil
}

private func handleTouchMovement(event: SpatialEventCollection.Event, renderer: VisionSceneRenderer) {
    // Similar logic for .indirectTouch during drag
    if renderer.isDragging, let startPos = renderer.dragStartPosition, let prevLoc = renderer.previousLocation {
        let currentLoc = event.location3D
        let delta = currentLoc.simd3 - prevLoc
        let newPosition = startPos + delta
        print("Touch movement - Delta: \(delta), New pos: \(newPosition)")
        renderer.modelPosition = newPosition
        renderer.previousLocation = currentLoc.simd3
    }
}

// Distance helper (import simd)
private func distance(_ a: SIMD3<Float>, _ b: Point3D) -> Float {
    simd_length(a - b.simd3)
}

private func distance(_ a: Point3D, _ b: Point3D) -> Float {
    simd_length(a.simd3 - b.simd3)
}
