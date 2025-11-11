#if os(macOS)

import Foundation
import simd

class CameraController {
    // Camera state
    var position: SIMD3<Float>
    var yaw: Float
    var pitch: Float
    
    // Movement state
    var moveForward: Bool = false
    var moveBackward: Bool = false
    var moveLeft: Bool = false
    var moveRight: Bool = false
    
    // Constants
    let movementSpeed: Float = 5.0 // units per second
    let mouseSensitivity: Float = 0.002 // radians per pixel
    let minPitch: Float = -Float.pi / 2 + 0.1 // Prevent gimbal lock
    let maxPitch: Float = Float.pi / 2 - 0.1
    
    init(position: SIMD3<Float> = SIMD3<Float>(0, 0, 0), yaw: Float = 0, pitch: Float = 0) {
        self.position = position
        self.yaw = yaw
        self.pitch = pitch
    }
    
    func updateMovement(deltaTime: TimeInterval, commonUpCalibration: matrix_float4x4) {
        guard moveForward || moveBackward || moveLeft || moveRight else { return }
        
        let speed = movementSpeed * Float(deltaTime)
        
        // Calculate movement vectors using the SAME logic as the view matrix
        // This ensures movement directions match what the camera sees in world space
        
        // Calculate forward vector from yaw only (for horizontal movement, ignore pitch)
        // We want movement in the XZ plane
        let forwardXZ = normalize(SIMD3<Float>(
            sin(yaw),
            0,
            cos(yaw)
        ))
        
        // Apply calibration to the forward vector to match world coordinate system
        let forwardXZ4 = commonUpCalibration * SIMD4<Float>(forwardXZ.x, forwardXZ.y, forwardXZ.z, 0)
        let calibratedForwardXZ = normalize(SIMD3<Float>(forwardXZ4.x, forwardXZ4.y, forwardXZ4.z))
        
        // Calculate right vector: perpendicular to forward in XZ plane
        // After calibration, world up might not be (0,1,0), so we need to compute it
        let worldUp4 = commonUpCalibration * SIMD4<Float>(0, 1, 0, 0)
        let calibratedWorldUp = normalize(SIMD3<Float>(worldUp4.x, worldUp4.y, worldUp4.z))
        
        // Right vector is cross product of forward and up (gives perpendicular in XZ plane)
        let right = normalize(cross(calibratedForwardXZ, calibratedWorldUp))
        
        var movement = SIMD3<Float>(0, 0, 0)
        
        if moveForward {
            movement += calibratedForwardXZ * speed
        }
        if moveBackward {
            movement -= calibratedForwardXZ * speed
        }
        if moveRight {
            movement += right * speed
        }
        if moveLeft {
            movement -= right * speed
        }
        
        position += movement
    }
    
    func updateRotation(deltaYaw: Float, deltaPitch: Float) {
        yaw += deltaYaw * mouseSensitivity
        pitch += deltaPitch * mouseSensitivity
        
        // Clamp pitch to prevent gimbal lock
        pitch = max(minPitch, min(maxPitch, pitch))
        
        // Normalize yaw to [-π, π]
        while yaw > Float.pi {
            yaw -= 2 * Float.pi
        }
        while yaw < -Float.pi {
            yaw += 2 * Float.pi
        }
    }
    
    func getViewMatrix(commonUpCalibration: matrix_float4x4) -> matrix_float4x4 {
        // Use look-at construction which correctly handles:
        // 1. Rotation around camera position (via translation component)
        // 2. Pitch rotation around camera's local X axis (not world X axis)
        //
        // The look-at matrix naturally ensures all rotations happen around the camera
        // because the translation accounts for camera position in the rotated coordinate system.
        
        // Calculate camera orientation from yaw and pitch
        // This gives us the forward direction in world space before calibration
        let forward = normalize(SIMD3<Float>(
            sin(yaw) * cos(pitch),
            -sin(pitch),
            cos(yaw) * cos(pitch)
        ))
        
        // Apply calibration to orientation vectors
        // This incorporates calibration into the camera's coordinate system
        let forward4 = commonUpCalibration * SIMD4<Float>(forward.x, forward.y, forward.z, 0)
        let calibratedForward = normalize(SIMD3<Float>(forward4.x, forward4.y, forward4.z))
        
        // Get calibrated world up vector
        let worldUp4 = commonUpCalibration * SIMD4<Float>(0, 1, 0, 0)
        let calibratedWorldUp = normalize(SIMD3<Float>(worldUp4.x, worldUp4.y, worldUp4.z))
        
        // Calculate camera's right and up vectors using cross products
        // This naturally gives us the camera's local coordinate system
        // Pitch rotation is implicitly around the right vector (camera's local X axis)
        let right = normalize(cross(calibratedForward, calibratedWorldUp))
        let up = normalize(cross(right, calibratedForward))
        
        // Build look-at view matrix
        // The translation component (-dot(right,pos), -dot(up,pos), dot(forward,pos))
        // correctly positions the camera in the rotated coordinate system.
        // Since we're using calibrated vectors, the camera position is accounted for
        // in the calibrated space, ensuring rotations happen around the camera.
        let viewMatrix = matrix_float4x4(
            columns: (
                vector_float4(right.x, right.y, right.z, 0),
                vector_float4(up.x, up.y, up.z, 0),
                vector_float4(-calibratedForward.x, -calibratedForward.y, -calibratedForward.z, 0),
                vector_float4(-dot(right, position), -dot(up, position), dot(calibratedForward, position), 1)
            )
        )
        
        return viewMatrix
    }
}

#endif // os(macOS)

