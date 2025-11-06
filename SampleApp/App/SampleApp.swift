#if os(visionOS)
import CompositorServices
#endif
import SwiftUI
import MetalSplatter

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
    switch event.phase {
    case .active:
        if !renderer.isDragging {
            // Check distance from hand to model center
            let modelCenter = renderer.modelPosition
            let handToModelDistance = distance(modelCenter, locationSIMD)
            print("Direct Pinch ACTIVE (start) - distance to model: \(handToModelDistance)m")

            let maxDistanceForInteraction: Float = 3.0
            if handToModelDistance > maxDistanceForInteraction {
                print("Ignoring direct pinch: too far (\(handToModelDistance)m)")
                return
            }

            // For direct pinch, we'll treat the contact point as the center for simplicity
            // Calculate offset from model center to contact point (approximated as model center)
            let contactOffset = locationSIMD - modelCenter

            renderer.isDragging = true
            renderer.gestureJustStarted = true
            renderer.dragStartPosition = renderer.modelPosition
            renderer.previousLocation = locationSIMD
            renderer.hitPointOffset = contactOffset
            print("Direct Pinch START - Initial model pos: \(renderer.modelPosition), hand pos: \(locationSIMD)")
        } else {
            // Update: Move model so contact point follows hand position exactly
            guard let hitPointOffset = renderer.hitPointOffset else { return }

            let handPosition = locationSIMD

            // The model center should be positioned so that: center + offset = hand_position
            // Therefore: center = hand_position - offset
            let newModelCenter = handPosition - hitPointOffset

            print("Direct Pinch UPDATE - Hand pos: \(handPosition), new model pos: \(newModelCenter)")

            renderer.modelPosition = newModelCenter
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
        if !renderer.isDragging, let selectionRay = event.selectionRay, let inputDevicePose = event.inputDevicePose {
            // Start: Raycast selectionRay to find hit on model
            guard let hitPoint = raycastToModel(using: selectionRay, renderer: renderer) else {
                print("Indirect Pinch ACTIVE (start) - No hit on model")
                return
            }

            // Check distance from hand to model for interaction limits
            let handPosition = inputDevicePose.pose3D.position.simd3
            let distanceToModel = distance(renderer.modelPosition, hitPoint)
            print("Indirect Pinch ACTIVE (start) - Hit point: \(hitPoint), distance to model: \(distanceToModel)m")

            // Calculate offset from model center to hit point for gaze-based manipulation
            let hitPointOffset = hitPoint.simd3 - renderer.modelPosition

            renderer.isDragging = true
            renderer.gestureJustStarted = true
            renderer.dragStartPosition = renderer.modelPosition
            renderer.previousLocation = handPosition
            renderer.initialHitPoint = hitPoint
            renderer.hitPointOffset = hitPointOffset
            print("Indirect Pinch START - Initial model pos: \(renderer.modelPosition), hit point: \(hitPoint), offset: \(hitPointOffset)")
        } else if renderer.isDragging, let inputDevicePose = event.inputDevicePose, let previousLocation = renderer.previousLocation {
            // Update: Move model so hit point follows hand position exactly
            let handPosition = inputDevicePose.pose3D.position.simd3

            // The model center should be positioned so that: center + offset = hand_position
            // Therefore: center = hand_position - offset
            let newModelCenter = handPosition - previousLocation + renderer.modelPosition

            print("Indirect Pinch UPDATE - Hand pos: \(handPosition), new model pos: \(newModelCenter)")

            renderer.modelPosition = newModelCenter
            renderer.previousLocation = handPosition
            renderer.gestureJustStarted = false
        }
    case .ended, .cancelled:
        print("Indirect Pinch ENDED/CANCELLED - Final pos: \(renderer.modelPosition)")
        endDrag(renderer: renderer)
    @unknown default:
        break
    }
}


// Raycast helper using sphere intersection
private func raycastToModel(using ray: Ray3D, renderer: VisionSceneRenderer) -> Point3D? {
    return raycastToModelSphere(using: ray, modelPosition: renderer.modelPosition, radius: renderer.modelRadius)
}

// Sphere intersection for raycast hit detection
private func raycastToModelSphere(using ray: Ray3D, modelPosition: SIMD3<Float>, radius: Float) -> Point3D? {
    let origin = ray.origin.simd3
    let direction = simd_normalize(ray.direction.simd3)
    let modelCenter = modelPosition
    let oc = modelCenter - origin
    let t = simd_dot(oc, direction)
    let closest = origin + t * direction
    let distSq = simd_length_squared(closest - modelCenter)

    if distSq <= radius * radius {
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
    renderer.initialHitPoint = nil
    renderer.hitPointOffset = nil
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
