import Foundation
import IOKit.hid

/// One decoded sample from the pen.
struct PenSample {
    var inRange = false
    var tip = false
    var button1 = false
    var button2 = false
    var button3 = false
    var eraser = false            // the tail of the pen, where the device reports one
    var pressure: Double = 0      // 0…1
    var tiltX: Double = 0         // degrees
    var tiltY: Double = 0
    var x: Double = 0             // 0…1 across the tablet's active area
    var y: Double = 0             // 0…1, 0 = the end the device calls zero
    var rawX = 0, rawY = 0, rawPressure = 0
    var mode: Mode = .vendor

    enum Mode: String {
        case vendor = "vendor 0x08"       // HUION raw mode
        case digitizer = "HID digitizer 0x0A"  // standard mode, no vendor driver
    }
}

/// Reads the HUION Kamvas 13 Gen3 (GS1333) directly over IOHIDManager.
///
/// The tablet speaks two dialects and this handles both, so the app keeps
/// working whether or not HUION's own driver is installed:
///
///   report 0x08 — 14 bytes, vendor interface (usage page 0xFF00)
///     [1] bit0 tip · bit1 button1 · bit2 button2 · bit3 button3 · bit7 in range
///     [2:4] X u16LE 0…58760   [4:6] Y u16LE 0…33040   [6:8] pressure u16LE 0…16383
///     [10] tilt X i8          [11] tilt Y i8          [12] tool id (0x03 = pen)
///
///   report 0x0A — 10 bytes, standard digitizer (usage page 0x0D)
///     [1] bit0 tip · bit1 barrel · bit2 eraser · bit3 invert · bit6 in range
///     [2:4] X u16LE 0…32767   [4:6] Y u16LE 0…32767   [6:8] pressure u16LE 0…16383
///     [8] tilt X i8           [9] tilt Y i8
final class TabletHID {
    static let vendorID = 0x256C          // HUION
    static let productID = 0x2008         // Kamvas 13 Gen3 / GS1333

    // Measured on the device itself — 5080 LPI over a 293.76 × 165.24 mm area.
    var vendorMaxX = 58760.0
    var vendorMaxY = 33040.0
    var vendorMaxPressure = 16383.0
    var digitizerMaxXY = 32767.0
    var digitizerMaxPressure = 16383.0

    var onSample: ((PenSample) -> Void)?
    var onStatus: ((String) -> Void)?
    /// The tablet's own keys, as a standard HID keyboard report (0x03).
    var onKeys: ((UInt8, Set<UInt8>) -> Void)?
    /// A touch strip (0x11): relative movement, a finger, and the key inside it.
    var onStrip: ((Int, Bool, Bool) -> Void)?

    private(set) var isConnected = false
    private(set) var latest = PenSample()
    private(set) var lastOpenStatus: IOReturn = kIOReturnNotOpen

    private var manager: IOHIDManager?
    private var buffers: [UnsafeMutablePointer<UInt8>] = []
    private var retryTimer: Timer?
    private var didRequestAccess = false

    /// Take the device exclusively. macOS otherwise keeps driving the cursor
    /// from the same reports we are reading, and the two event streams fight —
    /// interleaved presses and releases, strokes cut in half. Seizing needs no
    /// root, only the Input Monitoring grant we already hold.
    private(set) var isSeizing = false

    /// True when reports can actually be read: the device matched and the
    /// manager opened. Presence, in the sense the app cares about.
    var isReadable: Bool { isConnected && lastOpenStatus == kIOReturnSuccess }

    /// What the OS says about listening, in the two terms that actually decide
    /// whether reports arrive: the TCC verdict and the result of opening.
    var diagnostics: String {
        let access: String
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: access = "許可"
        case kIOHIDAccessTypeDenied: access = "拒否"
        default: access = "未確定"
        }
        let code = UInt32(bitPattern: Int32(lastOpenStatus))
        let open = lastOpenStatus == kIOReturnSuccess ? "成功" : "0x\(String(code, radix: 16))"
        return "入力監視 \(access) / open \(open)\(isSeizing ? "(排他)" : "")"
    }

    // MARK: - Lifecycle

    func start() {
        openManager()
        // Input Monitoring normally only takes effect on relaunch. Re-opening on
        // a timer means granting it while the app runs is enough.
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            guard let self, self.lastOpenStatus != kIOReturnSuccess else { return }
            self.teardown()
            self.openManager()
        }
        RunLoop.main.add(timer, forMode: .common)
        retryTimer = timer
    }

    private func teardown() {
        guard let mgr = manager else { return }
        IOHIDManagerUnscheduleFromRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(mgr, IOOptionBits(isSeizing ? kIOHIDOptionsTypeSeizeDevice : kIOHIDOptionsTypeNone))
        manager = nil
        isConnected = false
    }

    /// Re-open with a different exclusivity. Safe to call at any time.
    func setSeizing(_ seize: Bool) {
        guard seize != isSeizing else { return }
        isSeizing = seize
        teardown()
        openManager()
        if lastOpenStatus != kIOReturnSuccess && seize {
            // Fall back rather than leave the tablet dead.
            isSeizing = false
            teardown()
            openManager()
            onStatus?("排他確保に失敗したため通常モードに戻しました")
        }
    }

    private func openManager() {
        // Ask at most once — the open is retried on a timer, and re-requesting
        // each time would stack up system dialogs.
        if !didRequestAccess, IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted {
            didRequestAccess = true
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }

        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = mgr
        IOHIDManagerSetDeviceMatching(mgr, [
            kIOHIDVendorIDKey: Self.vendorID,
            kIOHIDProductIDKey: Self.productID,
        ] as CFDictionary)

        let me = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(mgr, { ctx, _, _, device in
            guard let ctx else { return }
            Unmanaged<TabletHID>.fromOpaque(ctx).takeUnretainedValue().attach(device)
        }, me)
        IOHIDManagerRegisterDeviceRemovalCallback(mgr, { ctx, _, _, _ in
            guard let ctx else { return }
            let hid = Unmanaged<TabletHID>.fromOpaque(ctx).takeUnretainedValue()
            hid.isConnected = false
            hid.onStatus?("タブレット未接続")
        }, me)

        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let options = IOOptionBits(isSeizing ? kIOHIDOptionsTypeSeizeDevice : kIOHIDOptionsTypeNone)
        lastOpenStatus = IOHIDManagerOpen(mgr, options)
        if lastOpenStatus != kIOReturnSuccess {
            onStatus?("HIDを開けません — \(diagnostics)")
        }
    }

    private func attach(_ device: IOHIDDevice) {
        let size = max((IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? NSNumber)?.intValue ?? 64, 64)
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        buf.initialize(repeating: 0, count: size)
        buffers.append(buf)

        IOHIDDeviceRegisterInputReportCallback(device, buf, size, { ctx, _, _, _, reportID, report, length in
            guard let ctx else { return }
            Unmanaged<TabletHID>.fromOpaque(ctx).takeUnretainedValue()
                .decode(reportID: Int(reportID), bytes: report, length: Int(length))
        }, Unmanaged.passUnretained(self).toOpaque())
        // commonModes, not defaultMode: AppKit runs a tracking loop while a
        // button is held or a menu is open, and in defaultMode the pen would go
        // silent for exactly as long as the press lasts — no release event, and
        // the watchdog yanking the cursor back mid-click.
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)

        if !isConnected {
            isConnected = true
            let name = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? "HUION"
            onStatus?("\(name) 接続")
        }
    }

    // MARK: - Decoding

    private func decode(reportID: Int, bytes: UnsafeMutablePointer<UInt8>, length: Int) {
        var s = PenSample()

        switch (reportID, length) {
        case (0x08, 14...):
            let flags = bytes[1]
            s.mode = .vendor
            s.inRange = flags & 0x80 != 0
            s.tip = flags & 0x01 != 0
            s.button1 = flags & 0x02 != 0
            s.button2 = flags & 0x04 != 0
            s.button3 = flags & 0x08 != 0
            s.rawX = Int(bytes[2]) | Int(bytes[3]) << 8
            s.rawY = Int(bytes[4]) | Int(bytes[5]) << 8
            s.rawPressure = Int(bytes[6]) | Int(bytes[7]) << 8
            s.x = Double(s.rawX) / vendorMaxX
            s.y = Double(s.rawY) / vendorMaxY
            s.pressure = Double(s.rawPressure) / vendorMaxPressure
            s.tiltX = Double(Int8(bitPattern: bytes[10]))
            s.tiltY = Double(Int8(bitPattern: bytes[11]))

        case (0x0A, 10...):
            let flags = bytes[1]
            s.mode = .digitizer
            s.inRange = flags & 0x40 != 0
            s.tip = flags & 0x01 != 0
            // bit1 Barrel, bit2 Eraser, bit3 Invert in the descriptor's words —
            // exposed as buttons 1-3 so they can be assigned like any other.
            s.button1 = flags & 0x02 != 0
            s.button2 = flags & 0x04 != 0
            s.button3 = flags & 0x08 != 0
            s.eraser = false
            s.rawX = Int(bytes[2]) | Int(bytes[3]) << 8
            s.rawY = Int(bytes[4]) | Int(bytes[5]) << 8
            s.rawPressure = Int(bytes[6]) | Int(bytes[7]) << 8
            s.x = Double(s.rawX) / digitizerMaxXY
            s.y = Double(s.rawY) / digitizerMaxXY
            s.pressure = Double(s.rawPressure) / digitizerMaxPressure
            s.tiltX = Double(Int8(bitPattern: bytes[8]))
            s.tiltY = Double(Int8(bitPattern: bytes[9]))

        case (0x03, 8...):
            // Not the boot-keyboard shape: this descriptor has no reserved byte,
            // so the six usages start at byte 2, straight after the modifiers.
            // Reading from byte 3 silently misses every key the tablet sends.
            var pressed = Set<UInt8>()
            for i in 2..<min(length, 8) where bytes[i] != 0 { pressed.insert(bytes[i]) }
            onKeys?(bytes[1], pressed)
            return

        case (0x11, 4...):
            let delta = Int(Int16(bitPattern: UInt16(bytes[2]) | UInt16(bytes[3]) << 8))
            onStrip?(delta, bytes[1] & 0x02 != 0, bytes[1] & 0x01 != 0)
            return

        default:
            return
        }

        s.x = min(max(s.x, 0), 1)
        s.y = min(max(s.y, 0), 1)
        s.pressure = min(max(s.pressure, 0), 1)
        latest = s
        onSample?(s)
    }
}
