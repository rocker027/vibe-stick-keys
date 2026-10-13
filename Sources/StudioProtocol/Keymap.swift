/// 一顆鍵的綁定，對應 keymap.proto 的 BehaviorBinding。behavior_id 為 0 表示該位置沒有綁定。
public struct KeyBinding: Equatable, Sendable {
    public let behaviorId: Int32
    public let param1: UInt32
    public let param2: UInt32

    public init(behaviorId: Int32, param1: UInt32, param2: UInt32) {
        self.behaviorId = behaviorId
        self.param1 = param1
        self.param2 = param2
    }
}

/// 一層配置；bindings 的索引就是 key position。
public struct KeymapLayer: Equatable, Sendable {
    public let id: UInt32
    public let name: String
    public let bindings: [KeyBinding]

    public init(id: UInt32, name: String, bindings: [KeyBinding]) {
        self.id = id
        self.name = name
        self.bindings = bindings
    }
}

/// get_keymap 的結果；layers 依韌體目前的層順序排列。
public struct Keymap: Equatable, Sendable {
    public let layers: [KeymapLayer]

    public init(layers: [KeymapLayer]) {
        self.layers = layers
    }

    /// 解析 keymap.proto 的 Keymap 訊息欄位。
    static func decode(_ fields: [ProtoField]) throws -> Keymap {
        Keymap(layers: try fields.messages(1).map { layer in
            KeymapLayer(
                id: UInt32(truncatingIfNeeded: layer.varint(1) ?? 0),
                name: layer.string(2) ?? "",
                bindings: try layer.messages(3).map(decodeBinding)
            )
        })
    }

    private static func decodeBinding(_ binding: [ProtoField]) -> KeyBinding {
        let rawBehavior = UInt32(truncatingIfNeeded: binding.varint(1) ?? 0)
        return KeyBinding(
            behaviorId: Int32(bitPattern: rawBehavior >> 1) ^ -Int32(bitPattern: rawBehavior & 1), // sint32 zigzag 還原
            param1: UInt32(truncatingIfNeeded: binding.varint(2) ?? 0),
            param2: UInt32(truncatingIfNeeded: binding.varint(3) ?? 0)
        )
    }
}

extension Array where Element == ProtoField {
    /// 取出所有同編號的子訊息（repeated message）。
    func messages(_ number: Int) throws -> [[ProtoField]] {
        try compactMap { field in
            guard field.number == number, case .bytes(let body) = field.value else { return nil }
            return try ProtoWire.parseFields(body)
        }
    }

    func string(_ number: Int) -> String? {
        for field in self where field.number == number {
            if case .bytes(let body) = field.value { return String(decoding: body, as: UTF8.self) }
        }
        return nil
    }
}
