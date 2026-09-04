import Foundation
import IOKit.hid

let VENDOR = 0x256C, PRODUCT = 0x2008

final class Dumper {
    var bufs: [ObjectIdentifier: UnsafeMutablePointer<UInt8>] = [:]
    var seen = Set<String>()
    var count = 0
}
let dumper = Dumper()

func prop(_ d: IOHIDDevice, _ k: String) -> Int {
    (IOHIDDeviceGetProperty(d, k as CFString) as? NSNumber)?.intValue ?? -1
}

let access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
print("IOHIDCheckAccess(listen) = \(access.rawValue)  (0=granted 1=denied 2=unknown)")
if access != kIOHIDAccessTypeGranted {
    let ok = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    print("IOHIDRequestAccess -> \(ok)")
}

let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(mgr, [kIOHIDVendorIDKey: VENDOR, kIOHIDProductIDKey: PRODUCT] as CFDictionary)
let r = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
if r != kIOReturnSuccess {
    let u = UInt32(bitPattern: Int32(r))
    FileHandle.standardError.write("IOHIDManagerOpen failed: 0x\(String(u, radix:16))\n".data(using:.utf8)!)
    if u == 0xE00002E2 {
        FileHandle.standardError.write("=> kIOReturnNotPermitted: 入力監視(Input Monitoring)の許可が必要です\n".data(using:.utf8)!)
    }
}

guard let set = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice> else { exit(1) }
for d in set {
    let up = prop(d, kIOHIDPrimaryUsagePageKey), us = prop(d, kIOHIDPrimaryUsageKey)
    let size = max(prop(d, kIOHIDMaxInputReportSizeKey), 64)
    let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
    buf.initialize(repeating: 0, count: size)
    dumper.bufs[ObjectIdentifier(d)] = buf
    let tag = String(format: "up%02x/us%02x", up, us)
    let ctx = UnsafeMutableRawPointer(mutating: (tag as NSString).utf8String!)
    IOHIDDeviceRegisterInputReportCallback(d, buf, size, { ctx, result, sender, type, reportID, report, len in
        let tag = String(cString: ctx!.assumingMemoryBound(to: CChar.self))
        var hex = ""
        for i in 0..<Int(len) { hex += String(format: "%02x ", report[i]) }
        var extra = ""
        if reportID == 0x0A && len >= 10 {
            let b = report[1]
            let x = Int(report[2]) | Int(report[3]) << 8
            let y = Int(report[4]) | Int(report[5]) << 8
            let p = Int(report[6]) | Int(report[7]) << 8
            let tx = Int(Int8(bitPattern: report[8])), ty = Int(Int8(bitPattern: report[9]))
            extra = String(format: "  | tip=%d barrel=%d eraser=%d invert=%d range=%d  X=%5d Y=%5d P=%5d tilt=%+3d,%+3d",
                           b & 1, (b>>1)&1, (b>>2)&1, (b>>3)&1, (b>>6)&1, x, y, p, tx, ty)
        }
        print("[\(tag)] id=0x\(String(format:"%02x",reportID)) len=\(len)  \(hex)\(extra)")
        fflush(stdout)
        dumper.count += 1
    }, ctx)
    IOHIDDeviceScheduleWithRunLoop(d, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    print("listening: \(tag) maxIn=\(prop(d, kIOHIDMaxInputReportSizeKey))")
}
fflush(stdout)
print("--- ペンをタブレットに当てて動かしてください (25秒) ---"); fflush(stdout)
DispatchQueue.main.asyncAfter(deadline: .now() + 25) {
    print("--- 終了: 受信レポート数 \(dumper.count) ---"); fflush(stdout); exit(0)
}
CFRunLoopRun()
