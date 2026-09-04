import AppKit
import CoreGraphics

/// What a tablet button can be made to do.
enum BoardAction: String, CaseIterable {
    case passthrough, none, undo, redo, clear, send, toggleEraser, eraseWhileHeld, nextColor
    case thicker, thinner, rightClick, middleClick, previousPage, nextPage, newPage
    case color1, color2, color3, color4, color5
    case toggleLaser, laserWhileHeld

    /// Index into the swatch row, for the five colour actions.
    var colourIndex: Int? {
        switch self {
        case .color1: return 0
        case .color2: return 1
        case .color3: return 2
        case .color4: return 3
        case .color5: return 4
        default: return nil
        }
    }

    static let colourActions: [BoardAction] = [.color1, .color2, .color3, .color4, .color5]

    /// Acts on release as well as press.
    var isMomentary: Bool { self == .eraseWhileHeld || self == .laserWhileHeld }

    var label: String {
        switch self {
        case .passthrough: return "そのまま通す"
        case .none: return "なし"
        case .undo: return "元に戻す"
        case .redo: return "やり直す"
        case .clear: return "全消去"
        case .send: return "送る"
        case .toggleEraser: return "消しゴム切替"
        case .eraseWhileHeld: return "押している間だけ消しゴム"
        case .nextColor: return "次の色"
        case .thicker: return "太く"
        case .thinner: return "細く"
        case .rightClick: return "右クリック"
        case .middleClick: return "中クリック"
        case .previousPage: return "前のページ"
        case .nextPage: return "次のページ"
        case .newPage: return "新規ページ"
        case .color1: return "色1 墨"
        case .color2: return "色2 朱"
        case .color3: return "色3 青"
        case .color4: return "色4 緑"
        case .color5: return "色5 レーザー"
        case .toggleLaser: return "レーザー切替"
        case .laserWhileHeld: return "押している間だけレーザー"
        }
    }
}

/// Seizing the device takes the express keys away from macOS along with the
/// pen, since both live on the same HID interface. So every key we swallow is
/// either turned into a board action or posted straight back out as the key it
/// was — nothing is lost by taking the device.
final class InputMap {

    /// HID keyboard usage → macOS virtual key code.
    private static let virtualKeys: [UInt8: CGKeyCode] = [
        0x04: 0, 0x05: 11, 0x06: 8, 0x07: 2, 0x08: 14, 0x09: 3, 0x0A: 5, 0x0B: 4,
        0x0C: 34, 0x0D: 38, 0x0E: 40, 0x0F: 37, 0x10: 46, 0x11: 45, 0x12: 31, 0x13: 35,
        0x14: 12, 0x15: 15, 0x16: 1, 0x17: 17, 0x18: 32, 0x19: 9, 0x1A: 13, 0x1B: 7,
        0x1C: 16, 0x1D: 6,
        0x1E: 18, 0x1F: 19, 0x20: 20, 0x21: 21, 0x22: 23, 0x23: 22, 0x24: 26, 0x25: 28,
        0x26: 25, 0x27: 29,
        0x28: 36, 0x29: 53, 0x2A: 51, 0x2B: 48, 0x2C: 49, 0x2D: 27, 0x2E: 24, 0x2F: 33,
        0x30: 30, 0x31: 42, 0x33: 41, 0x34: 39, 0x35: 50, 0x36: 43, 0x37: 47, 0x38: 44,
        0x39: 57,
        0x3A: 122, 0x3B: 120, 0x3C: 99, 0x3D: 118, 0x3E: 96, 0x3F: 97, 0x40: 98, 0x41: 100,
        0x42: 101, 0x43: 109, 0x44: 103, 0x45: 111,
        0x4A: 115, 0x4B: 116, 0x4C: 117, 0x4D: 119, 0x4E: 121,
        0x4F: 124, 0x50: 123, 0x51: 125, 0x52: 126,
    ]

    private static let usageNames: [UInt8: String] = [
        0x28: "Return", 0x29: "Esc", 0x2A: "Delete", 0x2B: "Tab", 0x2C: "Space",
        0x2D: "-", 0x2E: "=", 0x2F: "[", 0x30: "]", 0x31: "\\",
        0x4F: "→", 0x50: "←", 0x51: "↓", 0x52: "↑",
    ]

    static func name(forUsage usage: UInt8) -> String {
        if let named = usageNames[usage] { return named }
        if (0x04...0x1D).contains(usage) {
            return String(UnicodeScalar(UInt8(usage - 0x04) + 65))
        }
        if (0x1E...0x26).contains(usage) { return String(usage - 0x1D) }
        if usage == 0x27 { return "0" }
        if (0x3A...0x45).contains(usage) { return "F\(usage - 0x39)" }
        return String(format: "0x%02X", usage)
    }

    static func modifierNames(_ modifiers: UInt8) -> String {
        var parts: [String] = []
        if modifiers & 0x11 != 0 { parts.append("⌃") }
        if modifiers & 0x22 != 0 { parts.append("⇧") }
        if modifiers & 0x44 != 0 { parts.append("⌥") }
        if modifiers & 0x88 != 0 { parts.append("⌘") }
        return parts.joined()
    }

    private static func flags(_ modifiers: UInt8) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers & 0x11 != 0 { flags.insert(.maskControl) }
        if modifiers & 0x22 != 0 { flags.insert(.maskShift) }
        if modifiers & 0x44 != 0 { flags.insert(.maskAlternate) }
        if modifiers & 0x88 != 0 { flags.insert(.maskCommand) }
        return flags
    }

    // MARK: - Assignments

    private let store = UserDefaults.standard
    private func key(_ input: String) -> String { "input.\(input)" }

    /// Sensible starting points: the pen's own buttons do pen things, and every
    /// tablet key keeps doing whatever it did before we took the device.
    private let defaults: [String: BoardAction] = [
        "pen.button1": .toggleEraser,
        "pen.button2": .rightClick,
        "pen.button3": .eraseWhileHeld,
        "slider.button": .toggleEraser,
    ]

    func action(for input: String) -> BoardAction {
        if let raw = store.string(forKey: key(input)), let action = BoardAction(rawValue: raw) {
            return action
        }
        return defaults[input] ?? .passthrough
    }

    func setAction(_ action: BoardAction, for input: String) {
        store.set(action.rawValue, forKey: key(input))
    }

    // MARK: - Passing a key back out

    private let source = CGEventSource(stateID: .hidSystemState)

    func click(_ button: CGMouseButton) {
        let where_ = CGEvent(source: nil)?.location ?? .zero
        let down: CGEventType = button == .right ? .rightMouseDown : .otherMouseDown
        let up: CGEventType = button == .right ? .rightMouseUp : .otherMouseUp
        for type in [down, up] {
            guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                      mouseCursorPosition: where_, mouseButton: button) else { continue }
            event.setIntegerValueField(.mouseEventClickState, value: 1)
            event.post(tap: .cghidEventTap)
        }
    }

    /// Keys the tablet has actually sent, so they can be listed for assignment
    /// even when nothing is being pressed.
    var seenKeys: [UInt8] {
        (store.array(forKey: "input.seenKeys") as? [Int] ?? []).map { UInt8($0 & 0xFF) }
    }

    /// Kept in the order the keys were first pressed, so "assign the five keys
    /// to the five colours" lines up with the order they sit on the tablet.
    func remember(usage: UInt8) {
        var seen = store.array(forKey: "input.seenKeys") as? [Int] ?? []
        guard !seen.contains(Int(usage)) else { return }
        seen.append(Int(usage))
        store.set(seen, forKey: "input.seenKeys")
    }

    func forgetKeys() { store.removeObject(forKey: "input.seenKeys") }

    func scroll(_ amount: Int) {
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel,
                                  wheelCount: 1, wheel1: Int32(amount), wheel2: 0, wheel3: 0)
        else { return }
        event.post(tap: .cghidEventTap)
    }

    func passThrough(usage: UInt8, modifiers: UInt8, down: Bool) {
        guard let code = Self.virtualKeys[usage] else { return }
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
        else { return }
        event.flags = Self.flags(modifiers)
        event.post(tap: .cghidEventTap)
    }
}
