/// macOS 回報的一個 HID 輸入值。
public struct HidEvent: Equatable {
    public let usage: HidUsage
    public let isPressed: Bool

    public init(page: UInt32, usage: UInt32, isPressed: Bool) {
        self.usage = HidUsage(page: page, usage: usage)
        self.isPressed = isPressed
    }
}

public enum PressResult: Equatable {
    case pressed(position: Int, layerIndex: Int)
    case released(position: Int)
    /// 對不上任何 Key Press 綁定的輸入，例如未知功能送出的按鍵。
    case unmatched(HidUsage)
    /// 雜訊、伴隨的修飾鍵、或非鍵盤輸入。
    case ignored
}

/// 把裝置送出的按鍵推回是哪顆實體鍵。
/// HID 只看得到送出的按鍵，看不到切層鍵本身，所以目前層與切層鍵狀態都是從「最後按下的鍵屬於哪層」推論而來。
public struct PressTracker {
    public let keymap: StickKeymap
    public private(set) var pressedPositions: Set<Int> = []
    public private(set) var activeLayerIndex = 0
    /// 推論目前被按住（或背面開關撥著）的切層鍵位置。
    public private(set) var inferredLayerKeys: Set<Int> = []
    private var positionByUsage: [HidUsage: Int] = [:]
    /// 目前按下中的按鍵（含隱含修飾鍵），用來判斷伴隨送出的修飾鍵屬於哪顆鍵。
    private var pressedKeyCodes: [Int: KeyCode] = [:]

    public init(keymap: StickKeymap) {
        self.keymap = keymap
    }

    public mutating func handle(_ event: HidEvent) -> PressResult {
        guard Self.isKeyInput(event.usage) else { return .ignored }
        guard event.isPressed else { return release(event.usage) }
        // 例如 LAlt+Tab 會先送 Tab 再送 LAlt；這個 LAlt 屬於已按下的那顆鍵，不是另一顆綁了 LAlt 的鍵
        if event.usage.isModifier, pressedKeyCodes.values.contains(where: { $0.implies(modifier: event.usage) }) {
            return .ignored
        }
        let candidates = keymap.keyPressLocations(for: event.usage)
        guard !candidates.isEmpty else { return event.usage.isModifier ? .ignored : .unmatched(event.usage) }
        // 同一個按鍵出現在多層時，優先採用目前推論的層，其次是最底層
        let chosen = candidates.first { $0.layerIndex == activeLayerIndex } ?? candidates[0]
        activate(layerIndex: chosen.layerIndex)
        positionByUsage[event.usage] = chosen.position
        pressedKeyCodes[chosen.position] = chosen.keyCode
        pressedPositions.insert(chosen.position)
        return .pressed(position: chosen.position, layerIndex: chosen.layerIndex)
    }

    /// 鍵盤斷線時呼叫：放開事件會遺失，清掉按下中與推論的狀態，回到第 0 層。
    public mutating func reset() {
        pressedPositions = []
        inferredLayerKeys = []
        positionByUsage = [:]
        pressedKeyCodes = [:]
        activeLayerIndex = 0
    }

    private mutating func release(_ usage: HidUsage) -> PressResult {
        guard let position = positionByUsage.removeValue(forKey: usage) else { return .ignored }
        if !positionByUsage.values.contains(position) {
            pressedPositions.remove(position)
            pressedKeyCodes[position] = nil
        }
        return .released(position: position)
    }

    private mutating func activate(layerIndex: Int) {
        activeLayerIndex = layerIndex
        let layerId = keymap.layers[layerIndex].id
        inferredLayerKeys = layerIndex == 0 ? [] : keymap.layerKeyPositions(activating: layerId)
    }

    static let GENERIC_DESKTOP_PAGE: UInt32 = 0x01
    static let BUTTON_PAGE: UInt32 = 0x09
    static let ARRAY_BOOKKEEPING_USAGE: UInt32 = 0xFFFF_FFFF
    /// consumer page usage 0x01 是 Consumer Control 集合本身，不是按鍵。
    static let CONSUMER_CONTROL_COLLECTION: UInt32 = 0x01

    /// macOS 會為鍵盤陣列元素回報 usage 0xFFFFFFFF、0x01（ErrorRollOver）等簿記值，略過；
    /// 滑鼠報告（generic desktop、button page）也略過。其他未知 page 保留，以便列為未對應輸入。
    static func isKeyInput(_ usage: HidUsage) -> Bool {
        switch usage.page {
        case HidUsage.KEYBOARD_PAGE: return (0x04...0xE7).contains(usage.usage)
        case HidUsage.CONSUMER_PAGE: return ((CONSUMER_CONTROL_COLLECTION + 1)...0xFFFF).contains(usage.usage)
        case GENERIC_DESKTOP_PAGE, BUTTON_PAGE: return false
        default: return usage.usage != ARRAY_BOOKKEEPING_USAGE
        }
    }
}
