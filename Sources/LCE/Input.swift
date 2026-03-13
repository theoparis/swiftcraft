import AppKit

final class InputHandler {
    private(set) var pressedKeys: Set<UInt16> = []
    private(set) var mouseDelta = SIMD2<Float>(repeating: 0)
    private(set) var isMouseCaptured = false

    private var ignoreNextMouseEvent = false

    func setKey(_ keyCode: UInt16, pressed: Bool) {
        if pressed {
            pressedKeys.insert(keyCode)
        } else {
            pressedKeys.remove(keyCode)
        }
    }

    func setModifierFlags(_ flags: NSEvent.ModifierFlags) {
        if flags.contains(.shift) {
            pressedKeys.insert(Key.leftShift)
        } else {
            pressedKeys.remove(Key.leftShift)
        }
    }

    @MainActor
    func captureMouse(in view: NSView) {
        guard !isMouseCaptured else { return }
        isMouseCaptured = true
        NSCursor.hide()
        centerCursor(in: view)
    }

    @MainActor
    func releaseMouse() {
        guard isMouseCaptured else { return }
        isMouseCaptured = false
        NSCursor.unhide()
    }

    @MainActor
    func mouseMoved(deltaX: CGFloat, deltaY: CGFloat, in view: NSView) {
        guard isMouseCaptured else { return }
        if ignoreNextMouseEvent {
            ignoreNextMouseEvent = false
            return
        }
        mouseDelta.x += Float(deltaX)
        mouseDelta.y += Float(deltaY)
        centerCursor(in: view)
    }

    func consumeMouseDelta() -> SIMD2<Float> {
        defer { mouseDelta = .zero }
        return mouseDelta
    }

    func isPressed(_ keyCode: UInt16) -> Bool {
        pressedKeys.contains(keyCode)
    }

    @MainActor
    private func centerCursor(in view: NSView) {
        guard let window = view.window else { return }
        let rectInWindow = view.convert(view.bounds, to: nil)
        let centerInWindow = CGPoint(x: rectInWindow.midX, y: rectInWindow.midY)
        let screenPoint = window.convertPoint(toScreen: centerInWindow)
        ignoreNextMouseEvent = true
        CGWarpMouseCursorPosition(screenPoint)
    }
}

enum Key {
    static let w: UInt16 = 13
    static let a: UInt16 = 0
    static let s: UInt16 = 1
    static let d: UInt16 = 2
    static let space: UInt16 = 49
    static let leftShift: UInt16 = 56
}
