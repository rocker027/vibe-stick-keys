// 唯讀 HID 監聽：印出 YuVibeStick 送出的每個 HID 輸入值（usage page／usage／值）。
// 需要「輸入監控」權限（從終端機執行時是授權給終端機程式）。不攔截按鍵，按鍵仍會送到目前的視窗。
// 用法：hid_listen [秒數，預設 300]
import Foundation
import IOKit.hid

setbuf(stdout, nil)

let VENDOR_ID = 0x1D50
let PRODUCT_ID = 0x615E
let LISTEN_SECONDS = Double(CommandLine.arguments.dropFirst().first ?? "") ?? 300

func describeAccess(_ access: IOHIDAccessType) -> String {
    switch access {
    case kIOHIDAccessTypeGranted: return "已允許"
    case kIOHIDAccessTypeDenied: return "已拒絕"
    default: return "尚未決定"
    }
}

let access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
print("輸入監控權限：\(describeAccess(access))")
if access != kIOHIDAccessTypeGranted && !IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) {
    print("沒有輸入監控權限：請到「系統設定 → 隱私權與安全性 → 輸入監控」允許終端機程式，再重新執行")
    exit(2)
}

let hidManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(hidManager, [kIOHIDVendorIDKey: VENDOR_ID, kIOHIDProductIDKey: PRODUCT_ID] as CFDictionary)
IOHIDManagerRegisterInputValueCallback(hidManager, { _, _, _, value in
    let element = IOHIDValueGetElement(value)
    let line = String(format: "page 0x%02X usage 0x%02X value %ld",
                      IOHIDElementGetUsagePage(element), IOHIDElementGetUsage(element), IOHIDValueGetIntegerValue(value))
    print("\(Date().formatted(date: .omitted, time: .standard)) \(line)")
}, nil)
IOHIDManagerScheduleWithRunLoop(hidManager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

let openResult = IOHIDManagerOpen(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))
guard openResult == kIOReturnSuccess else {
    print(String(format: "IOHIDManagerOpen 失敗：0x%08X（0xE00002E2 表示沒有權限）", openResult))
    exit(1)
}
let deviceCount = (IOHIDManagerCopyDevices(hidManager) as? Set<IOHIDDevice>)?.count ?? 0
print("符合的裝置數：\(deviceCount)；開始監聽 \(Int(LISTEN_SECONDS)) 秒")
DispatchQueue.main.asyncAfter(deadline: .now() + LISTEN_SECONDS) { print("監聽結束"); exit(0) }
RunLoop.main.run()
