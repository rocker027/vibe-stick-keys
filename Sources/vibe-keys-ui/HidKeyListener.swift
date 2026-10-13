import Foundation
import IOKit.hid
import StickModel

/// 只監聽 YuVibeStick 送出的 HID 輸入值，不攔截按鍵（按鍵仍會送到前景視窗）。
/// 需要「輸入監控」權限；從終端機啟動時，權限屬於終端機程式。回呼在主執行緒的 run loop 上執行。
final class HidKeyListener {
    static let VENDOR_ID = 0x1D50
    static let PRODUCT_ID = 0x615E

    private var hidManager: IOHIDManager?
    private var onEvent: ((HidEvent) -> Void)?

    /// 開始監聽並回傳狀態說明。
    func start(onEvent: @escaping (HidEvent) -> Void) -> String {
        guard hidManager == nil else { return "監聽中" }
        let access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        if access != kIOHIDAccessTypeGranted && !IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) {
            return "沒有輸入監控權限：請到「系統設定 → 隱私權與安全性 → 輸入監控」允許終端機程式後重新啟動"
        }
        let deviceManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching = [kIOHIDVendorIDKey: Self.VENDOR_ID, kIOHIDProductIDKey: Self.PRODUCT_ID] as CFDictionary
        IOHIDManagerSetDeviceMatching(deviceManager, matching)
        IOHIDManagerRegisterInputValueCallback(deviceManager, { context, _, _, value in
            guard let context else { return }
            Unmanaged<HidKeyListener>.fromOpaque(context).takeUnretainedValue().deliver(value)
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerScheduleWithRunLoop(deviceManager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let openResult = IOHIDManagerOpen(deviceManager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            return String(format: "無法開啟 HID 監聽：0x%08X", openResult)
        }
        hidManager = deviceManager
        self.onEvent = onEvent
        let deviceCount = (IOHIDManagerCopyDevices(deviceManager) as? Set<IOHIDDevice>)?.count ?? 0
        return deviceCount > 0 ? "監聽中" : "監聽中，但目前沒有找到 YuVibeStick"
    }

    private func deliver(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        onEvent?(HidEvent(
            page: IOHIDElementGetUsagePage(element),
            usage: IOHIDElementGetUsage(element),
            isPressed: IOHIDValueGetIntegerValue(value) != 0
        ))
    }
}
