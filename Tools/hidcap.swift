import Foundation
import IOKit.hid

let VENDOR = 0x256C, PRODUCT = 0x2008
let seconds = Double(CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "45") ?? 45
let label   = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "capture"

final class Stats {
    var n = 0
    var xMin = Int.max, xMax = Int.min
    var yMin = Int.max, yMax = Int.min
    var pMin = Int.max, pMax = Int.min
    var txMin = Int.max, txMax = Int.min
    var tyMin = Int.max, tyMax = Int.min
    var flags = [UInt8: Int]()          // byte1 histogram
    var b8 = Set<UInt8>(), b9 = Set<UInt8>(), b12 = Set<UInt8>(), b13 = Set<UInt8>()
    var otherReports = [String: Int]()  // non-0x08 reports, hex -> count
    var log = ""
}
let st = Stats()

func prop(_ d: IOHIDDevice, _ k: String) -> Int {
    (IOHIDDeviceGetProperty(d, k as CFString) as? NSNumber)?.intValue ?? -1
}

let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(mgr, [kIOHIDVendorIDKey: VENDOR, kIOHIDProductIDKey: PRODUCT] as CFDictionary)
IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
guard let set = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice> else { exit(1) }

for d in set {
    let size = max(prop(d, kIOHIDMaxInputReportSizeKey), 64)
    let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
    buf.initialize(repeating: 0, count: size)
    let tag = String(format: "up%02x", prop(d, kIOHIDPrimaryUsagePageKey))
    let ctx = UnsafeMutableRawPointer(mutating: (tag as NSString).utf8String!)
    IOHIDDeviceRegisterInputReportCallback(d, buf, size, { ctx, _, _, _, rid, rep, len in
        let tag = String(cString: ctx!.assumingMemoryBound(to: CChar.self))
        let n = Int(len)
        var hex = ""; for i in 0..<n { hex += String(format: "%02x ", rep[i]) }
        st.log += "[\(tag)] \(hex)\n"
        if rid == 0x08 && n >= 14 {
            let x  = Int(rep[2]) | Int(rep[3]) << 8
            let y  = Int(rep[4]) | Int(rep[5]) << 8
            let p  = Int(rep[6]) | Int(rep[7]) << 8
            let tx = Int(Int8(bitPattern: rep[10])), ty = Int(Int8(bitPattern: rep[11]))
            st.n += 1
            st.xMin = min(st.xMin, x); st.xMax = max(st.xMax, x)
            st.yMin = min(st.yMin, y); st.yMax = max(st.yMax, y)
            st.pMin = min(st.pMin, p); st.pMax = max(st.pMax, p)
            st.txMin = min(st.txMin, tx); st.txMax = max(st.txMax, tx)
            st.tyMin = min(st.tyMin, ty); st.tyMax = max(st.tyMax, ty)
            st.flags[rep[1], default: 0] += 1
            st.b8.insert(rep[8]); st.b9.insert(rep[9]); st.b12.insert(rep[12]); st.b13.insert(rep[13])
        } else {
            st.otherReports[hex.trimmingCharacters(in: .whitespaces), default: 0] += 1
        }
    }, ctx)
    IOHIDDeviceScheduleWithRunLoop(d, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
}

DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
    func hx(_ s: Set<UInt8>) -> String { s.sorted().map { String(format:"0x%02x",$0) }.joined(separator: ",") }
    print("=== \(label): \(st.n) pen reports ===")
    if st.n > 0 {
        print("X   : \(st.xMin) .. \(st.xMax)")
        print("Y   : \(st.yMin) .. \(st.yMax)")
        print("P   : \(st.pMin) .. \(st.pMax)")
        print("tiltX: \(st.txMin) .. \(st.txMax)   tiltY: \(st.tyMin) .. \(st.tyMax)")
        print("byte1 flags seen:")
        for (f, c) in st.flags.sorted(by: { $0.key < $1.key }) {
            let b = (0...7).reversed().map { (f >> UInt8($0)) & 1 == 1 ? "1" : "0" }.joined()
            print(String(format: "   0x%02x  %@  x%d", f, b, c))
        }
        print("byte8: \(hx(st.b8))   byte9: \(hx(st.b9))   byte12: \(hx(st.b12))   byte13: \(hx(st.b13))")
    }
    if !st.otherReports.isEmpty {
        print("--- other reports ---")
        for (h, c) in st.otherReports.sorted(by: { $0.value > $1.value }).prefix(25) { print("   x\(c)  \(h)") }
    }
    try? st.log.write(toFile: "/tmp/hidcap-\(label).log", atomically: true, encoding: .utf8)
    print("raw log -> /tmp/hidcap-\(label).log")
    exit(0)
}
CFRunLoopRun()
