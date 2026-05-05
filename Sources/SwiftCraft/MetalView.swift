import MetalKit
import SwiftUI

struct Metal4View: NSViewRepresentable {
    func makeCoordinator() -> Metal4ViewCoordinator {
        Metal4ViewCoordinator()
    }

    func makeNSView(context: Context) -> GameView {
        let view = GameView(frame: .zero, device: context.coordinator.device)
        view.delegate = context.coordinator
        view.inputHandler = context.coordinator.inputHandler
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ view: GameView, context: Context) {}
}

final class GameView: MTKView {
    var inputHandler: InputHandler?
    private var trackingAreaRef: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect, device: MTLDevice?) {
        super.init(frame: frameRect, device: device)
        colorPixelFormat = .bgra8Unorm
        depthStencilPixelFormat = .depth32Float
        clearColor = MTLClearColor(red: 0.53, green: 0.81, blue: 0.92, alpha: 1.0)
        preferredFramesPerSecond = 120
        isPaused = false
        enableSetNeedsDisplay = false
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        window?.makeFirstResponder(self)
        // Defer one run-loop tick so SwiftUI finishes configuring the window before we
        // insert our flags — otherwise SwiftUI overwrites them.
        DispatchQueue.main.async { [weak self] in
            guard let window = self?.window else { return }
            window.styleMask.insert(.resizable)          // required for fullscreen to be enabled
            window.collectionBehavior.insert(.fullScreenPrimary)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let options: NSTrackingArea.Options = [.activeAlways, .inVisibleRect, .mouseMoved]
        let trackingArea = NSTrackingArea(
            rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(trackingArea)
        trackingAreaRef = trackingArea
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == Key.f11 {
            window?.toggleFullScreen(nil)
            return
        }
        inputHandler?.setKey(event.keyCode, pressed: true)
    }

    override func keyUp(with event: NSEvent) {
        inputHandler?.setKey(event.keyCode, pressed: false)
    }

    override func flagsChanged(with event: NSEvent) {
        inputHandler?.setModifierFlags(event.modifierFlags)
    }

    override func mouseDown(with event: NSEvent) {
        inputHandler?.captureMouse(in: self)
    }

    override func rightMouseDown(with event: NSEvent) {
        inputHandler?.releaseMouse()
    }

    override func mouseMoved(with event: NSEvent) {
        inputHandler?.mouseMoved(deltaX: event.deltaX, deltaY: event.deltaY, in: self)
    }

    override func mouseDragged(with event: NSEvent) {
        inputHandler?.mouseMoved(deltaX: event.deltaX, deltaY: event.deltaY, in: self)
    }
}
