import Foundation


/// HID usage page 與 usage 的組合，例如鍵盤 page 0x07、consumer page 0x0C。
public struct HidUsage: Hashable {
    public let page: UInt32
    public let usage: UInt32

    public init(page: UInt32, usage: UInt32) {
        self.page = page
        self.usage = usage
    }

    public static let KEYBOARD_PAGE: UInt32 = 0x07
    public static let CONSUMER_PAGE: UInt32 = 0x0C

    public var isModifier: Bool { page == Self.KEYBOARD_PAGE && (0xE0...0xE7).contains(usage) }

    /// 人讀名稱；用 macOS 慣用的修飾鍵稱呼。
    public var displayName: String {
        let names = page == Self.KEYBOARD_PAGE ? HidUsageNames.KEYBOARD : page == Self.CONSUMER_PAGE ? HidUsageNames.CONSUMER : [:]
        return names[usage] ?? String(format: "page 0x%02X usage 0x%02X", page, usage)
    }
}

enum HidUsageNames {
    static let KEYBOARD: [UInt32: String] = {
        var names: [UInt32: String] = [
            0x28: "Enter", 0x29: "Esc", 0x2A: "Backspace", 0x2B: "Tab", 0x2C: "Space", 0x2D: "-", 0x2E: "=",
            0x2F: "[", 0x30: "]", 0x31: "\\", 0x33: ";", 0x34: "'", 0x35: "`", 0x36: ",", 0x37: ".", 0x38: "/",
            0x39: "Caps Lock", 0x46: "Print Screen", 0x49: "Insert", 0x4A: "Home", 0x4B: "Page Up", 0x4C: "Delete",
            0x4D: "End", 0x4E: "Page Down", 0x4F: "→", 0x50: "←", 0x51: "↓", 0x52: "↑",
            0xE0: "Control", 0xE1: "Shift", 0xE2: "Option", 0xE3: "Command",
            0xE4: "右 Control", 0xE5: "右 Shift", 0xE6: "右 Option", 0xE7: "右 Command",
        ]
        for offset in 0..<26 { names[0x04 + UInt32(offset)] = String(UnicodeScalar(UInt8(65 + offset))) }
        for offset in 0..<10 { names[0x1E + UInt32(offset)] = String((offset + 1) % 10) }
        for offset in 0..<12 { names[0x3A + UInt32(offset)] = "F\(offset + 1)" }
        for offset in 0..<12 { names[0x68 + UInt32(offset)] = "F\(offset + 13)" }
        return names
    }()

    static let CONSUMER: [UInt32: String] = [
        0xE9: "音量 +", 0xEA: "音量 −", 0xE2: "靜音", 0xCD: "播放／暫停", 0xB5: "下一首", 0xB6: "上一首",
        0xB7: "停止", 0x6F: "亮度 +", 0x70: "亮度 −",
    ]
}
