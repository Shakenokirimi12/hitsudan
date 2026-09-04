import Foundation
import IOKit.hid

let VENDOR = 0x256C

func s(_ d: IOHIDDevice, _ k: String) -> String {
    guard let v = IOHIDDeviceGetProperty(d, k as CFString) else { return "-" }
    return "\(v)"
}
func n(_ d: IOHIDDevice, _ k: String) -> Int {
    (IOHIDDeviceGetProperty(d, k as CFString) as? NSNumber)?.intValue ?? -1
}

let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(mgr, [kIOHIDVendorIDKey: VENDOR] as CFDictionary)
let openRes = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
print("IOHIDManagerOpen -> 0x\(String(openRes, radix: 16))")

guard let set = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>, !set.isEmpty else {
    print("no HUION HID devices visible (permission or not connected)")
    exit(1)
}
let devices = Array(set).sorted { n($0, kIOHIDPrimaryUsagePageKey) < n($1, kIOHIDPrimaryUsagePageKey) }
print("found \(devices.count) interface(s)\n")

for (i, d) in devices.enumerated() {
    print("--- interface #\(i) ---")
    print("  Product        : \(s(d, kIOHIDProductKey))")
    print("  VID/PID        : 0x\(String(n(d, kIOHIDVendorIDKey), radix:16))/0x\(String(n(d, kIOHIDProductIDKey), radix:16))")
    print("  UsagePage/Usage: 0x\(String(n(d, kIOHIDPrimaryUsagePageKey), radix:16))/0x\(String(n(d, kIOHIDPrimaryUsageKey), radix:16))")
    print("  MaxInputReport : \(n(d, kIOHIDMaxInputReportSizeKey))")
    print("  MaxFeatureRep  : \(n(d, kIOHIDMaxFeatureReportSizeKey))")
    print("  LocationID     : \(n(d, kIOHIDLocationIDKey))")
    if let rd = IOHIDDeviceGetProperty(d, "ReportDescriptor" as CFString) as? Data {
        print("  ReportDescriptor (\(rd.count) bytes):")
        print("    " + rd.map { String(format: "%02x", $0) }.joined(separator: " "))
    } else {
        print("  ReportDescriptor: <unavailable>")
    }
    print("")
}
