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
    
    init(position: SIMD3<Float> = SIMD3<Float>(0, 0, 5), yaw: Float = 0, pitch: Float = 0) {
        self.position = position
        self.yaw = yaw
        self.pitch = pitch
    }
    
    func updateMovement(deltaTime: TimeInterval) {
        guard moveForward || moveBackward || moveLeft || moveRight else { return }
        
        let speed = movementSpeed * Float(deltaTime)
        
        // Calculate forward vector for movement (XZ plane)
        // Yaw 0 corresponds to looking down -Z
        let forward = SIMD3<Float>(sin(yaw), 0, -cos(yaw))
        let right = SIMD3<Float>(cos(yaw), 0, sin(yaw))
        
        var movement = SIMD3<Float>(0, 0, 0)
        
        if moveForward {
            movement += forward
        }
        if moveBackward {
            movement -= forward
        }
        if moveRight {
            movement += right
        }
        if moveLeft {
            movement -= right
        }
        
        // Normalize to ensure constant speed regardless of direction
        if length_squared(movement) > 0 {
            movement = normalize(movement) * speed
            position += movement
        }
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
    
    func getViewMatrix() -> matrix_float4x4 {
        // Calculate forward vector
        // Yaw 0 = -Z
        let forward = normalize(SIMD3<Float>(
            sin(yaw) * cos(pitch),
            sin(pitch),
            -cos(yaw) * cos(pitch)
        ))
        
        let worldUp = SIMD3<Float>(0, 1, 0)
        
        // Calculate camera coordinate system
        let right = normalize(cross(forward, worldUp))
        let up = normalize(cross(right, forward))
        
        // Create LookAt matrix
        // Camera space basis vectors
        let zAxis = -forward // Backwards
        let xAxis = right
        let yAxis = up
        
        return matrix_float4x4(
            columns: (
                vector_float4(xAxis.x, xAxis.y, xAxis.z, 0),
                vector_float4(yAxis.x, yAxis.y, yAxis.z, 0),
                vector_float4(zAxis.x, zAxis.y, zAxis.z, 0),
                vector_float4(-dot(xAxis, position), -dot(yAxis, position), -dot(zAxis, position), 1)
            )
        )
    }
}

#endif // os(macOS)
