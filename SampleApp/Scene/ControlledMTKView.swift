#if os(macOS)

import AppKit
import MetalKit

class ControlledMTKView: MTKView {
    weak var cameraController: CameraController?
    
    private var keyStates: Set<UInt16> = []
    private var isMouseDragging: Bool = false
    private var lastMouseLocation: NSPoint = .zero
    private var trackingArea: NSTrackingArea?
    
    override func awakeFromNib() {
        super.awakeFromNib()
        setupTrackingArea()
    }
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        setupTrackingArea()
    }
    
    private func setupTrackingArea() {
        if let trackingArea = trackingArea {
            removeTrackingArea(trackingArea)
        }
        
        let options: NSTrackingArea.Options = [
            .activeInKeyWindow,
            .mouseMoved,
            .inVisibleRect
        ]
        
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: options,
            owner: self,
            userInfo: nil
        )
        
        if let trackingArea = trackingArea {
            addTrackingArea(trackingArea)
        }
    }
    
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        setupTrackingArea()
    }
    
    override var acceptsFirstResponder: Bool {
        return true
    }
    
    override func keyDown(with event: NSEvent) {
        guard let characters = event.charactersIgnoringModifiers else {
            super.keyDown(with: event)
            return
        }
        
        let keyCode = event.keyCode
        keyStates.insert(keyCode)
        
        // Handle WASD keys
        switch characters.lowercased() {
        case "w":
            cameraController?.moveForward = true
        case "s":
            cameraController?.moveBackward = true
        case "a":
            cameraController?.moveLeft = true
        case "d":
            cameraController?.moveRight = true
        default:
            break
        }
    }
    
    override func keyUp(with event: NSEvent) {
        guard let characters = event.charactersIgnoringModifiers else {
            super.keyUp(with: event)
            return
        }
        
        let keyCode = event.keyCode
        keyStates.remove(keyCode)
        
        // Handle WASD keys
        switch characters.lowercased() {
        case "w":
            cameraController?.moveForward = false
        case "s":
            cameraController?.moveBackward = false
        case "a":
            cameraController?.moveLeft = false
        case "d":
            cameraController?.moveRight = false
        default:
            break
        }
    }
    
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isMouseDragging = true
        lastMouseLocation = convert(event.locationInWindow, from: nil)
    }
    
    override func mouseDragged(with event: NSEvent) {
        guard isMouseDragging, let cameraController = cameraController else { return }
        
        let currentLocation = convert(event.locationInWindow, from: nil)
        let deltaX = Float(currentLocation.x - lastMouseLocation.x)
        let deltaY = Float(currentLocation.y - lastMouseLocation.y)
        
        // Standard FPS Look: Drag Down -> Look Down
        // macOS Y increases Up. Drag Down -> deltaY < 0.
        // Look Down -> Decrease Pitch -> deltaPitch < 0.
        cameraController.updateRotation(deltaYaw: deltaX, deltaPitch: deltaY)
        
        lastMouseLocation = currentLocation
    }
    
    override func mouseUp(with event: NSEvent) {
        isMouseDragging = false
    }
    
    override func mouseExited(with event: NSEvent) {
        isMouseDragging = false
    }
    
    override func scrollWheel(with event: NSEvent) {
        guard let cameraController = cameraController else {
            super.scrollWheel(with: event)
            return
        }
        
        // Use vertical scroll delta for pitch adjustment (looking up/down)
        // Scroll Down (Positive) -> Look Down (Decrease Pitch)
        let scrollDeltaY = Float(event.scrollingDeltaY)
        let scrollSensitivity: Float = 0.1 // radians per scroll unit
        
        // Update pitch based on scroll
        cameraController.updateRotation(deltaYaw: 0, deltaPitch: -scrollDeltaY * scrollSensitivity)
    }
    
    override func flagsChanged(with event: NSEvent) {
        // Handle modifier keys if needed in the future
        super.flagsChanged(with: event)
    }
}

#endif // os(macOS)

