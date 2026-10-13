import AppKit
import ApplicationServices
import CoreGraphics

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

/// Keeps the real mouse and trackpad off the pen display.
///
/// The pen display belongs to the board: the pen never moves the system
/// cursor, and this stops every other pointing device from wandering onto it.
/// With the cursor unable to get there, nothing can be dropped or dragged onto
/// it with the mouse either.
///
/// An event tap cannot hold the cursor back by itself. By the time a session
/// tap sees a mouseMoved, the window server has already drawn the cursor at
/// the new spot, and swallowing the event would only hide the move from apps.
/// So a move that lands on the blocked display is rewritten to the nearest
/// point on the display it came from, and the cursor is warped back there.
final class MouseBarrier {

    enum State: Equatable {
        case off
        case active
        case needsAccessibility
        case unavailable(String)
    }

    /// Main thread only.
    private(set) var state: State = .off

    var summary: String {
        switch state {
        case .off: return "マウス制限 なし"
        case .active: return "マウス制限 有効（ペン用ディスプレイにマウスは入れません）"
        case .needsAccessibility: return "マウス制限 無効 — アクセシビリティの許可が必要です"
        case .unavailable(let why): return "マウス制限 無効 — \(why)"
        }
    }

    // Shared with the tap thread; every access goes through `lock`.
    private let lock = NSLock()
    private var blocked = CGRect.null
    /// The other displays' bounds, the main display first.
    private var refuges: [CGRect] = []
    /// Where the mouse last was off the blocked display, to send it back to
    /// the display it came from rather than whichever is nearest.
    private var lastAllowed: CGPoint?
    private var wantsTap = false

    /// Created once and kept: the tap's thread runs for the life of the app,
    /// and switching the barrier off only disables the tap.
    private var tap: CFMachPort?
    private var tapLoop: CFRunLoop?
    private var didPrompt = false

    /// A warp normally freezes local mouse input for 0.25 s, which against a
    /// wall the mouse hits many times a second would make it feel stuck.
    /// Re-associating mouse and cursor straight after each warp is what SDL
    /// and Wine do about it, and is the remedy relied on here. A combined-
    /// session source with the suppression interval at zero is also kept
    /// alive: its documented scope is events posted through that source, and
    /// whether it reaches warps as well is unverified, but it costs nothing.
    /// The deprecated global CGSetLocalEventsSuppressionInterval is not used.
    private let warpSource: CGEventSource? = {
        let source = CGEventSource(stateID: .combinedSessionState)
        source?.localEventsSuppressionInterval = 0
        return source
    }()

    /// Point the barrier at a display, or lift it with nil. Cheap enough to
    /// call on every presence check: it also picks up a display that moved or
    /// changed resolution, and installs the tap once Accessibility is granted.
    func update(blocking display: CGDirectDisplayID?) {
        state = configure(display)
    }

    private func configure(_ display: CGDirectDisplayID?) -> State {
        // A grant can be withdrawn while the app runs. The system then stops
        // the tap, which would otherwise go on being reported as active and
        // might not come back on re-enable; drop it so a fresh one is made
        // once the grant returns.
        if tap != nil, !AXIsProcessTrusted() { removeTap() }
        guard let display else { lift(); return .off }
        // Mirrored, the pen display shares its bounds with another one; the
        // barrier would wall the mouse out of that display too.
        if CGDisplayIsInMirrorSet(display) != 0 {
            lift()
            return .unavailable("ミラーリング中のため使えません")
        }
        // Without separate Spaces there is one menu bar, on the main display.
        // Walling that off would leave the menu bar, and with it this app's
        // own menu, out of reach of the mouse.
        if display == CGMainDisplayID(), !NSScreen.screensHaveSeparateSpaces {
            lift()
            return .unavailable("メニューバーのあるディスプレイなので制限しません")
        }
        let others = Self.activeDisplays().filter { $0 != display }
        let ordered = others.filter { CGDisplayIsMain($0) != 0 } + others.filter { CGDisplayIsMain($0) == 0 }
        guard !ordered.isEmpty else {
            lift()
            return .unavailable("ほかにディスプレイが無いため使えません")
        }
        guard installTap() else {
            lift()
            return AXIsProcessTrusted() ? .unavailable("イベントタップを作れませんでした") : .needsAccessibility
        }
        lock.lock()
        blocked = CGDisplayBounds(display)
        refuges = ordered.map { CGDisplayBounds($0) }
        wantsTap = true
        lock.unlock()
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        return .active
    }

    private func lift() {
        lock.lock()
        blocked = .null
        refuges = []
        // The tap sees nothing while lifted, so where the mouse was then says
        // nothing about where it is when the barrier comes back.
        lastAllowed = nil
        wantsTap = false
        lock.unlock()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
    }

    private static func activeDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    /// An active tap (one that rewrites events) needs Accessibility. Ask once
    /// per launch with the system prompt; after that the status line says what
    /// is missing, and the tap goes in by itself on the next update once the
    /// grant arrives.
    private func installTap() -> Bool {
        if tap != nil { return true }
        guard AXIsProcessTrusted() else {
            if !didPrompt {
                didPrompt = true
                let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
                _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
            }
            return false
        }
        let types: [CGEventType] = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                return Unmanaged<MouseBarrier>.fromOpaque(refcon).takeUnretainedValue().filter(type, event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        else { return false }
        tap = port
        CGEvent.tapEnable(tap: port, enable: false)
        // Its own thread, not the main run loop: every mouse move on the
        // system waits for this callback, and the main thread stalls now and
        // then (rasterising an SVG, writing a page). The system would then
        // disable the tap for being slow, and the whole desktop's mouse would
        // stutter while it did.
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            self?.tapLoop = CFRunLoopGetCurrent()
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "MouseBarrier"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        return true
    }

    private func removeTap() {
        lift()
        if let tap { CFMachPortInvalidate(tap) }
        if let tapLoop {
            // Queued rather than called: the thread may not have entered
            // CFRunLoopRun yet, and a stop sent before that is lost.
            CFRunLoopPerformBlock(tapLoop, CFRunLoopMode.commonModes.rawValue) { CFRunLoopStop(tapLoop) }
            CFRunLoopWakeUp(tapLoop)
        }
        tap = nil
        tapLoop = nil
    }

    // MARK: - On the tap thread

    private func filter(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        lock.lock()
        defer { lock.unlock() }

        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // The system switches a tap off when it is slow or when secure
            // input starts. Left off, the barrier would silently stop working.
            if wantsTap, let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            break
        default:
            return pass
        }

        let point = event.location
        // A fast flick can carry the mouse clean over the pen display in one
        // event when it sits between two others. Crossing it is as much
        // "entering" as landing on it, and letting it through would make the
        // far display reachable only at speed.
        // Two witnesses to where the move started, each wrong in its own way:
        // the event's delta is not guaranteed to be in the same units as the
        // location (acceleration, scaled displays, a cursor pinned at the outer
        // edge), and the last position seen here goes stale when something
        // else warps the cursor. Only when both say the move crossed the pen
        // display is it treated as a jump over it.
        let start = CGPoint(x: point.x - CGFloat(event.getDoubleValueField(.mouseEventDeltaX)),
                            y: point.y - CGFloat(event.getDoubleValueField(.mouseEventDeltaY)))
        let jumped = crosses(from: start, to: point, blocked)
            && (lastAllowed.map { crosses(from: $0, to: point, blocked) } ?? true)
        guard !blocked.isNull, blocked.contains(point) || jumped else {
            lastAllowed = point
            return pass
        }
        guard let home = refuges.first(where: { $0.contains(start) })
                ?? refuges.first(where: { $0.contains(lastAllowed ?? point) })
                ?? refuges.min(by: { distance(point, $0) < distance(point, $1) }) else { return pass }
        let target = CGPoint(x: min(max(point.x, home.minX), home.maxX - 1),
                             y: min(max(point.y, home.minY), home.maxY - 1))
        event.location = target
        CGWarpMouseCursorPosition(target)
        CGAssociateMouseAndMouseCursorPosition(1)
        lastAllowed = target
        return pass
    }

    /// Whether the straight move from `a` to `b` passes through `rect`
    /// (Liang-Barsky clipping of the segment against the rectangle).
    private func crosses(from a: CGPoint, to b: CGPoint, _ rect: CGRect) -> Bool {
        guard !rect.isNull else { return false }
        // CGRect.contains excludes the max edges; so must this, or a move that
        // only grazes the right or bottom edge would count as crossing.
        let rect = CGRect(x: rect.minX, y: rect.minY, width: rect.width - 0.001, height: rect.height - 0.001)
        let dx = b.x - a.x, dy = b.y - a.y
        var t0: CGFloat = 0, t1: CGFloat = 1
        for (p, q) in [(-dx, a.x - rect.minX), (dx, rect.maxX - a.x),
                       (-dy, a.y - rect.minY), (dy, rect.maxY - a.y)] {
            if p == 0 {
                if q < 0 { return false }
            } else {
                let r = q / p
                if p < 0 { t0 = max(t0, r) } else { t1 = min(t1, r) }
                if t0 > t1 { return false }
            }
        }
        return true
    }

    private func distance(_ point: CGPoint, _ rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return hypot(dx, dy)
    }
}
