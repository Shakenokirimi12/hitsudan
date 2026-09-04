import AppKit
import ApplicationServices
import CoreGraphics

/// Drives the system pointer from raw tablet samples — the part of the vendor
/// driver that decides where the cursor is and when a press counts as a click.
///
/// macOS's generic digitizer handling points the tablet at whichever display
/// the cursor happens to be on, and only fires a click well past the pen's own
/// tip switch. Here the mapping is absolute onto one chosen display, and the
/// click fires on the tip switch itself, which the device asserts at about 11%
/// of full pressure — far lighter than the system's own threshold.
final class PenPointer {

    var screen: NSScreen?
    var mapsRightButton = true

    var isEnabled = false {
        didSet { if !isEnabled { surrender(); returnCursorNow() } }
    }

    private let source = CGEventSource(stateID: .hidSystemState)
    private var inProximity = false
    private var leftDown = false
    private var rightDown = false

    // Two pointing devices, each remembering where it left the cursor. Lifting
    // the pen leaves the cursor where the pen put it; the cursor only returns
    // to the mouse's own position when the mouse is actually moved.
    private var mouseHome: CGPoint?
    private var penHoldsCursor = false
    private var lastPenEventAt = Date.distantPast
    private var monitors: [Any] = []

    var isTrusted: Bool { AXIsProcessTrusted() }

    init() { watchForRealMouse() }

    deinit { monitors.forEach { NSEvent.removeMonitor($0) } }

    /// The moment the person actually touches the mouse, hand the cursor back
    /// to where the mouse itself last was.
    private func watchForRealMouse() {
        let kinds: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .scrollWheel]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: kinds, handler: { [weak self] _ in
            self?.realMouseMoved()
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: kinds, handler: { [weak self] event in
            self?.realMouseMoved()
            return event
        }) {
            monitors.append(local)
        }
    }

    private func realMouseMoved() {
        // Our own synthesized events land here too; ignore anything while the
        // pen is in range or within a moment of its last report.
        guard !inProximity, Date().timeIntervalSince(lastPenEventAt) > 0.2 else { return }
        guard penHoldsCursor, let home = mouseHome else { return }
        penHoldsCursor = false
        mouseHome = nil
        CGWarpMouseCursorPosition(home)
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    /// Posting mouse events needs Accessibility. Ask once, with the system prompt.
    func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    private var displayID: CGDirectDisplayID? {
        guard let screen else { return nil }
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value
    }

    // MARK: - Driving

    func handle(_ sample: PenSample) {
        guard isEnabled, isTrusted, let id = displayID else { return }

        guard sample.inRange else {
            if inProximity { surrender() }
            return
        }

        lastPenEventAt = Date()
        if !inProximity {
            inProximity = true
            // Only the first takeover records where the mouse itself was; a pen
            // returning after a lift must not overwrite it with its own position.
            if !penHoldsCursor { mouseHome = CGEvent(source: nil)?.location }
            penHoldsCursor = true
        }

        // CGDisplayBounds is already global, top-left origin, y downward — the
        // same convention a digitizer reports in, so no flipping is needed.
        let bounds = CGDisplayBounds(id)
        let point = CGPoint(x: bounds.minX + CGFloat(sample.x) * bounds.width,
                            y: bounds.minY + CGFloat(sample.y) * bounds.height)

        let moveType: CGEventType = leftDown ? .leftMouseDragged
                                  : rightDown ? .rightMouseDragged : .mouseMoved
        post(moveType, at: point, button: leftDown ? .left : .right, sample: sample)

        if sample.tip != leftDown {
            leftDown = sample.tip
            post(leftDown ? .leftMouseDown : .leftMouseUp, at: point, button: .left, sample: sample)
        }

        if mapsRightButton, sample.button1 != rightDown {
            rightDown = sample.button1
            post(rightDown ? .rightMouseDown : .rightMouseUp, at: point, button: .right, sample: sample)
        }
    }

    /// The pen has left, or the feed stopped, or the takeover was switched off.
    /// The cursor stays where the pen put it — it returns to the mouse's own
    /// position only once the mouse is actually moved.
    func surrender() {
        if leftDown || rightDown, let last = CGEvent(source: nil)?.location {
            if leftDown { post(.leftMouseUp, at: last, button: .left, sample: nil); leftDown = false }
            if rightDown { post(.rightMouseUp, at: last, button: .right, sample: nil); rightDown = false }
        }
        leftDown = false
        rightDown = false
        inProximity = false
    }

    /// Switching the takeover off entirely gives the cursor straight back.
    private func returnCursorNow() {
        if penHoldsCursor, let home = mouseHome {
            CGWarpMouseCursorPosition(home)
            CGAssociateMouseAndMouseCursorPosition(1)
        }
        penHoldsCursor = false
        mouseHome = nil
    }

    private func post(_ type: CGEventType, at point: CGPoint, button: CGMouseButton, sample: PenSample?) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: point, mouseButton: button) else { return }

        if type == .leftMouseDown || type == .leftMouseUp ||
           type == .rightMouseDown || type == .rightMouseUp {
            event.setIntegerValueField(.mouseEventClickState, value: 1)
        }

        if let sample {
            // Carry the tablet data through, so other apps see real pressure.
            event.setIntegerValueField(.mouseEventSubtype, value: 1)   // tablet point
            event.setDoubleValueField(.mouseEventPressure, value: sample.pressure)
            event.setDoubleValueField(.tabletEventPointPressure, value: sample.pressure)
            event.setDoubleValueField(.tabletEventTiltX, value: sample.tiltX / 60)
            event.setDoubleValueField(.tabletEventTiltY, value: sample.tiltY / 60)
            event.setIntegerValueField(.tabletEventDeviceID, value: 1)
            var buttons = 0
            if sample.tip { buttons |= 1 }
            if sample.button1 { buttons |= 2 }
            if sample.button2 { buttons |= 4 }
            event.setIntegerValueField(.tabletEventPointButtons, value: Int64(buttons))
        }

        event.post(tap: .cghidEventTap)
    }
}
