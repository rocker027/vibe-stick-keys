/// 單一按鍵的新綁定。欄位對應 zmk-studio-messages `keymap.proto` 的 SetLayerBindingRequest 與 BehaviorBinding。
/// 型別依韌體實際寬度收窄：layer ID 是 `zmk_keymap_layer_id_t`（uint8），behavior ID 是 `zmk_behavior_local_id_t`（uint16）；
/// proto 欄位較寬，超出範圍的值會被韌體截斷而寫到別的 layer／behavior，所以在型別層就排除。
public struct LayerBindingChange: Equatable, Sendable {
    public let layerId: UInt8
    public let keyPosition: UInt8
    /// 裝置本地的 behavior ID（來自 behaviors.list_all_behaviors），例如 YuVibeStick 的 8 = Key Press。
    public let behaviorId: UInt16
    public let param1: UInt32
    public let param2: UInt32

    public init(layerId: UInt8, keyPosition: UInt8, behaviorId: UInt16, param1: UInt32, param2: UInt32) {
        self.layerId = layerId
        self.keyPosition = keyPosition
        self.behaviorId = behaviorId
        self.param1 = param1
        self.param2 = param2
    }
}

/// 本專案能送出的所有請求種類。會改變鍵盤狀態的只有 set_layer_binding 與 save_changes，且只由 CLI 建構；
/// 刻意不提供 discard_changes、reset_settings、layer 增刪移動等請求，讓程式在型別層就無法送出它們。
public enum StudioRequest: Equatable, Sendable {
    case setLayerBinding(LayerBindingChange)
    case saveChanges
    case checkUnsavedChanges
    case getKeymap
    case getBehaviorDetails(behaviorId: UInt16)

    // studio.proto Request、keymap.proto Request、behaviors.proto Request 的欄位編號
    static let REQUEST_ID_FIELD = 1
    static let BEHAVIORS_SUBSYSTEM_FIELD = 4
    static let KEYMAP_SUBSYSTEM_FIELD = 5
    static let GET_KEYMAP_FIELD = 1
    static let SET_LAYER_BINDING_FIELD = 2
    static let CHECK_UNSAVED_CHANGES_FIELD = 3
    static let SAVE_CHANGES_FIELD = 4
    static let GET_BEHAVIOR_DETAILS_FIELD = 2
    // SetLayerBindingRequest、BehaviorBinding、GetBehaviorDetailsRequest 內的欄位編號
    static let LAYER_ID_FIELD = 1
    static let KEY_POSITION_FIELD = 2
    static let BINDING_FIELD = 3
    static let BEHAVIOR_ID_FIELD = 1
    static let PARAM1_FIELD = 2
    static let PARAM2_FIELD = 3
    static let DETAILS_BEHAVIOR_ID_FIELD = 1

    /// 會改變鍵盤狀態（執行中配置或永久設定）的請求；StudioBleClient 預設拒絕送出。
    public var isMutating: Bool {
        switch self {
        case .setLayerBinding, .saveChanges: return true
        case .checkUnsavedChanges, .getKeymap, .getBehaviorDetails: return false
        }
    }

    /// 編碼成 zmk.studio.Request 的 protobuf 位元組（尚未加框架）。
    public func encode(requestId: UInt32) -> [UInt8] {
        let (subsystemField, body) = subsystemBody()
        return ProtoWire.varintField(Self.REQUEST_ID_FIELD, UInt64(requestId))
            + ProtoWire.messageField(subsystemField, body)
    }

    /// 回應種類必須對得上請求；meta 錯誤對任何請求都成立（由呼叫端當成失敗處理）。
    public func accepts(_ outcome: StudioOutcome) -> Bool {
        switch (self, outcome) {
        case (_, .metaError), (.setLayerBinding, .setLayerBinding), (.saveChanges, .saveChanges),
             (.checkUnsavedChanges, .unsavedChanges), (.getKeymap, .keymap):
            return true
        case (.getBehaviorDetails(let requested), .behaviorDetails(let id, _)):
            return UInt32(requested) == id
        default:
            return false
        }
    }

    public var name: String {
        switch self {
        case .setLayerBinding: return "set_layer_binding"
        case .saveChanges: return "save_changes"
        case .checkUnsavedChanges: return "check_unsaved_changes"
        case .getKeymap: return "get_keymap"
        case .getBehaviorDetails: return "get_behavior_details"
        }
    }

    private func subsystemBody() -> (Int, [UInt8]) {
        switch self {
        case .setLayerBinding(let change):
            return (Self.KEYMAP_SUBSYSTEM_FIELD,
                    ProtoWire.messageField(Self.SET_LAYER_BINDING_FIELD, Self.encodeSetLayerBinding(change)))
        case .saveChanges:
            return (Self.KEYMAP_SUBSYSTEM_FIELD, ProtoWire.varintField(Self.SAVE_CHANGES_FIELD, 1))
        case .checkUnsavedChanges:
            return (Self.KEYMAP_SUBSYSTEM_FIELD, ProtoWire.varintField(Self.CHECK_UNSAVED_CHANGES_FIELD, 1))
        case .getKeymap:
            return (Self.KEYMAP_SUBSYSTEM_FIELD, ProtoWire.varintField(Self.GET_KEYMAP_FIELD, 1))
        case .getBehaviorDetails(let behaviorId):
            let details = ProtoWire.optionalVarintField(Self.DETAILS_BEHAVIOR_ID_FIELD, UInt64(behaviorId))
            return (Self.BEHAVIORS_SUBSYSTEM_FIELD, ProtoWire.messageField(Self.GET_BEHAVIOR_DETAILS_FIELD, details))
        }
    }

    private static func encodeSetLayerBinding(_ change: LayerBindingChange) -> [UInt8] {
        let binding = ProtoWire.optionalVarintField(Self.BEHAVIOR_ID_FIELD, ProtoWire.zigzag(Int32(change.behaviorId)))
            + ProtoWire.optionalVarintField(Self.PARAM1_FIELD, UInt64(change.param1))
            + ProtoWire.optionalVarintField(Self.PARAM2_FIELD, UInt64(change.param2))
        return ProtoWire.optionalVarintField(Self.LAYER_ID_FIELD, UInt64(change.layerId))
            + ProtoWire.optionalVarintField(Self.KEY_POSITION_FIELD, UInt64(change.keyPosition))
            + ProtoWire.messageField(Self.BINDING_FIELD, binding)
    }
}
