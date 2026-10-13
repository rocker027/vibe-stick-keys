import StudioProtocol

/// 從裝置讀到的 keymap 加上 behavior 名稱；提供標籤與「按鍵推回位置」需要的查詢。
/// behavior ID 是裝置本地編號，換韌體可能改變，所以一律用裝置回報的名稱判斷種類。
public struct StickKeymap: Equatable, Sendable {
    public let keymap: Keymap
    public let behaviorNames: [Int32: String]

    static let KEY_PRESS = "Key Press"
    static let TRANSPARENT = "Transparent"
    static let LAYER_BEHAVIORS: Set<String> = ["Momentary Layer", "Toggle Layer", "To Layer", "Sticky Layer", "Layer-Tap"]

    public init(keymap: Keymap, behaviorNames: [Int32: String]) {
        self.keymap = keymap
        self.behaviorNames = behaviorNames
    }

    public var layers: [KeymapLayer] { keymap.layers }

    func behaviorName(_ binding: KeyBinding) -> String? {
        behaviorNames[binding.behaviorId]
    }

    func binding(layerIndex: Int, position: Int) -> KeyBinding? {
        guard layers.indices.contains(layerIndex), layers[layerIndex].bindings.indices.contains(position) else { return nil }
        return layers[layerIndex].bindings[position]
    }

    /// Transparent 會往下一層找；回傳實際生效的綁定與它所在的層。
    public func effectiveBinding(layerIndex: Int, position: Int) -> (binding: KeyBinding, layerIndex: Int)? {
        for index in stride(from: layerIndex, through: 0, by: -1) {
            guard let binding = binding(layerIndex: index, position: position) else { return nil }
            if behaviorName(binding) != Self.TRANSPARENT { return (binding, index) }
        }
        return nil
    }

    /// 某顆鍵在指定層實際生效的人讀標籤。
    public func label(layerIndex: Int, position: Int) -> String {
        guard let (binding, _) = effectiveBinding(layerIndex: layerIndex, position: position) else { return "（無此鍵）" }
        return BindingLabel.text(binding, behaviorName: behaviorName(binding), layerName: layerName(id:))
    }

    public func layerName(id: UInt32) -> String {
        layers.first { $0.id == id }?.name ?? "L\(id)"
    }

    /// 第 0 層實際生效綁定為指定 behavior 的位置，例如 vibe_ptt（MIC 收音）。
    public func basePositions(withBehavior name: String) -> Set<Int> {
        guard let base = layers.first else { return [] }
        return Set(base.bindings.indices.filter { behaviorName(base.bindings[$0]) == name })
    }

    /// 第 0 層上會啟用指定層的切層鍵位置，例如 L1 → 位置 5（Momentary Layer 1）。
    func layerKeyPositions(activating layerId: UInt32) -> Set<Int> {
        guard let base = layers.first else { return [] }
        let positions = base.bindings.indices.filter { position in
            let binding = base.bindings[position]
            return Self.LAYER_BEHAVIORS.contains(behaviorName(binding) ?? "") && binding.param1 == layerId
        }
        return Set(positions)
    }

    /// 在各層實際生效（Transparent 往下找之後）為 Key Press 且 usage 相符的（層索引, 位置, 按鍵）。
    /// 用生效綁定而非原始綁定：上層 Transparent 的鍵按下時，上層仍是目前層，不能誤判回到下層。
    func keyPressLocations(for usage: HidUsage) -> [(layerIndex: Int, position: Int, keyCode: KeyCode)] {
        layers.indices.flatMap { layerIndex in
            layers[layerIndex].bindings.indices.compactMap { position -> (layerIndex: Int, position: Int, keyCode: KeyCode)? in
                guard let (binding, _) = effectiveBinding(layerIndex: layerIndex, position: position),
                      behaviorName(binding) == Self.KEY_PRESS else { return nil }
                let keyCode = KeyCode(param: binding.param1)
                return keyCode.usage == usage ? (layerIndex, position, keyCode) : nil
            }
        }
    }
}

/// ZMK Key Press 參數：bits 24–31 是隱含修飾鍵，bits 16–23 是 HID page，bits 0–15 是 usage。
struct KeyCode: Equatable {
    let modifiers: UInt8
    let usage: HidUsage

    init(param: UInt32) {
        modifiers = UInt8(truncatingIfNeeded: param >> 24)
        usage = HidUsage(page: (param >> 16) & 0xFF, usage: param & 0xFFFF)
    }

    // ZMK 隱含修飾鍵位元：低 4 位為左側 Ctrl／Shift／Alt／GUI，高 4 位為右側同順序
    static let CONTROL_MASK: UInt8 = 0x11
    static let SHIFT_MASK: UInt8 = 0x22
    static let OPTION_MASK: UInt8 = 0x44
    static let COMMAND_MASK: UInt8 = 0x88
    /// HID 修飾鍵 usage 0xE0–0xE7 依序對應的 ZMK 修飾鍵位元。
    static let MODIFIER_USAGE_BITS: [UInt32: UInt8] = [
        0xE0: 0x01, 0xE1: 0x02, 0xE2: 0x04, 0xE3: 0x08, 0xE4: 0x10, 0xE5: 0x20, 0xE6: 0x40, 0xE7: 0x80,
    ]

    /// 這個按鍵是否隱含指定的修飾鍵 usage，例如 LAlt+Tab 隱含 0xE2。
    func implies(modifier usage: HidUsage) -> Bool {
        guard let bit = Self.MODIFIER_USAGE_BITS[usage.usage], usage.page == HidUsage.KEYBOARD_PAGE else { return false }
        return modifiers & bit != 0
    }

    /// macOS 修飾鍵符號，順序同 macOS 選單：⌃ ⌥ ⇧ ⌘。左右鍵不區分。
    var displayName: String {
        let symbols: [(mask: UInt8, symbol: String)] = [
            (Self.CONTROL_MASK, "⌃"), (Self.OPTION_MASK, "⌥"), (Self.SHIFT_MASK, "⇧"), (Self.COMMAND_MASK, "⌘"),
        ]
        let prefix = symbols.filter { modifiers & $0.mask != 0 }.map(\.symbol).joined()
        return prefix.isEmpty ? usage.displayName : "\(prefix) \(usage.displayName)"
    }
}

enum BindingLabel {
    static func text(_ binding: KeyBinding, behaviorName: String?, layerName: (UInt32) -> String) -> String {
        guard let name = behaviorName else {
            return binding.behaviorId == 0 ? "（未設定）" : "behavior #\(binding.behaviorId)"
        }
        switch name {
        case StickKeymap.KEY_PRESS: return KeyCode(param: binding.param1).displayName
        case "Momentary Layer": return "按住切到 \(layerName(binding.param1))"
        case "Toggle Layer": return "切換 \(layerName(binding.param1))"
        case "To Layer": return "切到 \(layerName(binding.param1))"
        case "Sticky Layer": return "單次 \(layerName(binding.param1))"
        case "Layer-Tap": return "按住 \(layerName(binding.param1))／點按 \(KeyCode(param: binding.param2).displayName)"
        case "Mod-Tap":
            return "按住 \(KeyCode(param: binding.param1).displayName)／點按 \(KeyCode(param: binding.param2).displayName)"
        case StickKeymap.TRANSPARENT: return "（同下層）"
        case "None": return "（無）"
        default: return name
        }
    }
}
