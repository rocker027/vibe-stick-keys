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

    /// 第 0 層上會啟用指定層的切層鍵位置，例如 L1 → 位置 5（Momentary Layer 1）。
    func layerKeyPositions(activating layerId: UInt32) -> Set<Int> {
        guard let base = layers.first else { return [] }
        let positions = base.bindings.indices.filter { position in
            let binding = base.bindings[position]
            return Self.LAYER_BEHAVIORS.contains(behaviorName(binding) ?? "") && binding.param1 == layerId
        }
        return Set(positions)
    }

    /// 所有綁定為 Key Press 且 usage 相符的（層索引, 位置）。
    func keyPressLocations(for usage: HidUsage) -> [(layerIndex: Int, position: Int)] {
        layers.indices.flatMap { layerIndex in
            layers[layerIndex].bindings.indices.compactMap { position -> (layerIndex: Int, position: Int)? in
                let binding = layers[layerIndex].bindings[position]
                guard behaviorName(binding) == Self.KEY_PRESS, KeyCode(param: binding.param1).usage == usage else { return nil }
                return (layerIndex, position)
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

    /// macOS 修飾鍵符號，順序同 macOS 選單：⌃ ⌥ ⇧ ⌘。左右鍵不區分。
    var displayName: String {
        let symbols: [(mask: UInt8, symbol: String)] = [(0x11, "⌃"), (0x44, "⌥"), (0x22, "⇧"), (0x88, "⌘")]
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
