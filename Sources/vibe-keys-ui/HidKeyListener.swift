import Foundation
import IOKit.hid
import StickModel

/// 只監聽 YuVibeStick 送出的 HID 輸入值，不攔截按鍵（按鍵仍會送到前景視窗）。
/// 同時回報裝置是否存在：鍵盤經藍牙連上 Mac 時系統會出現這個 HID 裝置，斷線時移除，所以可當作藍牙連線狀態。
/// 需要「輸入監控」權限；從終端機啟動時，權限屬於終端機程式。回呼在主執行緒的 run loop 上執行。
final class HidKeyListener {
    static let VENDOR_ID = 0x1D50
    static let PRODUCT_ID = 0x615E
    /// 0x1D50:0x615E 是 ZMK 的預設 ID，其他 ZMK 鍵盤也會用；再以產品名稱（ioreg 的 Product）區分。
    static let PRODUCT_NAME = "YuVibeStick"

    enum StartOutcome: Equatable {
        case listening
        case failed(String)
    }

    private var hidManager: IOHIDManager?
    private var onEvent: ((HidEvent) -> Void)?
    private var onConnectionChange: ((Bool) -> Void)?
    private var connectedDevices: Set<IOHIDDevice> = []

    deinit {
        guard let hidManager else { return }
        IOHIDManagerUnscheduleFromRunLoop(hidManager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    /// 開始監聽。onConnectionChange 在裝置出現或消失時呼叫，參數為目前是否已連線。
    func start(onEvent: @escaping (HidEvent) -> Void, onConnectionChange: @escaping (Bool) -> Void) -> StartOutcome {
        guard hidManager == nil else { return .listening }
        let access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        if access != kIOHIDAccessTypeGranted && !IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) {
            return .failed("沒有輸入監控權限：請到「系統設定 → 隱私權與安全性 → 輸入監控」允許終端機程式後重新啟動")
        }
        self.onEvent = onEvent
        self.onConnectionChange = onConnectionChange
        let deviceManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching = [
            kIOHIDVendorIDKey: Self.VENDOR_ID, kIOHIDProductIDKey: Self.PRODUCT_ID, kIOHIDProductKey: Self.PRODUCT_NAME,
        ] as CFDictionary
        IOHIDManagerSetDeviceMatching(deviceManager, matching)
        registerCallbacks(deviceManager)
        // commonModes：開選單或拖曳視窗時事件也照常送達
        IOHIDManagerScheduleWithRunLoop(deviceManager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let openResult = IOHIDManagerOpen(deviceManager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            IOHIDManagerUnscheduleFromRunLoop(deviceManager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            return .failed(String(format: "無法開啟 HID 監聽：0x%08X", openResult))
        }
        hidManager = deviceManager
        // 已存在的裝置會稍後經由 matching 回呼回報；目前一台都沒有時先回報未連線
        if (IOHIDManagerCopyDevices(deviceManager) as? Set<IOHIDDevice>)?.isEmpty ?? true { onConnectionChange(false) }
        return .listening
    }

    private func registerCallbacks(_ deviceManager: IOHIDManager) {
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(deviceManager, { context, _, _, value in
            guard let context else { return }
            Unmanaged<HidKeyListener>.fromOpaque(context).takeUnretainedValue().deliver(value)
        }, context)
        IOHIDManagerRegisterDeviceMatchingCallback(deviceManager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<HidKeyListener>.fromOpaque(context).takeUnretainedValue().updateDevice(device, isPresent: true)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(deviceManager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<HidKeyListener>.fromOpaque(context).takeUnretainedValue().updateDevice(device, isPresent: false)
        }, context)
    }

    private func updateDevice(_ device: IOHIDDevice, isPresent: Bool) {
        if isPresent { connectedDevices.insert(device) } else { connectedDevices.remove(device) }
        onConnectionChange?(!connectedDevices.isEmpty)
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
