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
            MacOSModelView(modelIdentifier: modelIdentifier.wrappedValue)
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

#if os(visionOS)
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
        if var pinchState = renderer.pinchStates[event.id] {
            pinchState.location = locationSIMD
            renderer.pinchStates[event.id] = pinchState
        } else {
            renderer.pinchStates[event.id] = .init(id: event.id, location: locationSIMD, kind: .directPinch)
        }

        if renderer.twoHandGestureState != nil {
            updateTwoHandGesture(renderer: renderer)
            return
        }

        if renderer.pinchStates.count >= 2 {
            startTwoHandGestureIfPossible(renderer: renderer)
            if renderer.twoHandGestureState != nil {
                endDrag(renderer: renderer)
                updateTwoHandGesture(renderer: renderer)
                return
            }
        }

        guard renderer.twoHandGestureState == nil else { return }

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
            renderer.activeTranslationEventID = event.id
            print("Direct Pinch START - Initial model pos: \(renderer.modelPosition), hand pos: \(locationSIMD)")
        } else {
            guard renderer.activeTranslationEventID == event.id else { return }
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
        renderer.pinchStates.removeValue(forKey: event.id)
        if renderer.twoHandGestureState?.contains(event.id) == true {
            renderer.twoHandGestureState = nil
        }
        endDrag(renderer: renderer)
    @unknown default:
        break
    }
}

private func handleIndirectPinch(event: SpatialEventCollection.Event, renderer: VisionSceneRenderer) {
    switch event.phase {
    case .active:
        if let inputDevicePose = event.inputDevicePose {
            let handPosition = inputDevicePose.pose3D.position.simd3
            if var pinchState = renderer.pinchStates[event.id] {
                pinchState.location = handPosition
                renderer.pinchStates[event.id] = pinchState
            } else {
                renderer.pinchStates[event.id] = .init(id: event.id, location: handPosition, kind: .indirectPinch)
            }
            
            if renderer.twoHandGestureState != nil {
                updateTwoHandGesture(renderer: renderer)
                return
            }
            
            if renderer.pinchStates.count >= 2 {
                startTwoHandGestureIfPossible(renderer: renderer)
                if renderer.twoHandGestureState != nil {
                    endDrag(renderer: renderer)
                    updateTwoHandGesture(renderer: renderer)
                    return
                }
            }
        }
        
        guard renderer.twoHandGestureState == nil else { return }
        
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
            renderer.activeTranslationEventID = event.id
            print("Indirect Pinch START - Initial model pos: \(renderer.modelPosition), hit point: \(hitPoint), offset: \(hitPointOffset)")
        } else if renderer.isDragging,
                  renderer.activeTranslationEventID == event.id,
                  let inputDevicePose = event.inputDevicePose,
                  let previousLocation = renderer.previousLocation {
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
        renderer.pinchStates.removeValue(forKey: event.id)
        if renderer.twoHandGestureState?.contains(event.id) == true {
            renderer.twoHandGestureState = nil
        }
        endDrag(renderer: renderer)
    @unknown default:
        break
    }
}


// Raycast helper using sphere intersection
private func raycastToModel(using ray: Ray3D, renderer: VisionSceneRenderer) -> Point3D? {
    return raycastToModelSphere(using: ray,
                                modelPosition: renderer.modelPosition,
                                radius: renderer.modelRadius * renderer.modelScale)
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
    renderer.activeTranslationEventID = nil
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

private func startTwoHandGestureIfPossible(renderer: VisionSceneRenderer) {
    guard renderer.twoHandGestureState == nil else { return }
    let pinchStates = renderer.pinchStates.values.sorted { $0.id.hashValue < $1.id.hashValue }
    guard pinchStates.count >= 2 else { return }
    let first = pinchStates[0]
    let second = pinchStates[1]
    
    let vector = second.location - first.location
    let distance = simd_length(vector)
    guard distance > 0.01 else { return }
    
    let initialDirection = normalizedHorizontalDirection(from: vector)
    
    renderer.twoHandGestureState = VisionSceneRenderer.TwoHandGestureState(
        firstID: first.id,
        secondID: second.id,
        initialDistance: distance,
        initialScale: renderer.modelScale,
        initialOrientation: renderer.modelOrientation,
        initialDirection: initialDirection
    )
}

private func updateTwoHandGesture(renderer: VisionSceneRenderer) {
    guard let state = renderer.twoHandGestureState,
          let first = renderer.pinchStates[state.firstID],
          let second = renderer.pinchStates[state.secondID] else {
        return
    }
    
    let vector = second.location - first.location
    let distance = simd_length(vector)
    guard distance > 0.001 else { return }
    
    let scaleFactor = distance / state.initialDistance
    let newScale = simd_clamp(state.initialScale * scaleFactor,
                              renderer.minimumModelScale,
                              renderer.maximumModelScale)
    renderer.modelScale = newScale
    
    if let initialDirection = state.initialDirection,
       let currentDirection = normalizedHorizontalDirection(from: vector) {
        let dotValue = simd_dot(initialDirection, currentDirection)
        let determinant = initialDirection.x * currentDirection.y - initialDirection.y * currentDirection.x
        let deltaAngle = -atan2(determinant, dotValue)
        let deltaQuaternion = simd_quatf(angle: deltaAngle, axis: SIMD3<Float>(0, 1, 0))
        renderer.modelOrientation = simd_normalize(deltaQuaternion * state.initialOrientation)
    }
}

private func normalizedHorizontalDirection(from vector: SIMD3<Float>) -> SIMD2<Float>? {
    let horizontal = SIMD2<Float>(vector.x, vector.z)
    let magnitude = simd_length(horizontal)
    guard magnitude > 0.0001 else { return nil }
    return horizontal / magnitude
}

// Distance helper (import simd)
private func distance(_ a: SIMD3<Float>, _ b: Point3D) -> Float {
    simd_length(a - b.simd3)
}

private func distance(_ a: Point3D, _ b: Point3D) -> Float {
    simd_length(a.simd3 - b.simd3)
}
#endif // os(visionOS)

#if os(macOS)
struct MacOSModelView: View {
    let modelIdentifier: ModelIdentifier?
    @State private var flipYAxis = false
    
    var body: some View {
        MetalKitSceneView(modelIdentifier: modelIdentifier, flipYAxis: flipYAxis)
            .overlay(alignment: .bottomTrailing) {
                Button(action: {
                    flipYAxis.toggle()
                }) {
                    Image(systemName: "arrow.up.and.down")
                        .imageScale(.large)
                        .padding(8)
                }
                .buttonStyle(.borderless)
                .background(Material.ultraThinMaterial)
                .cornerRadius(8)
                .padding()
                .help("Flip Y Axis")
            }
    }
}
#endif
