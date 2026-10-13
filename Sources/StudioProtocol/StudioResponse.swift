/// 從裝置收到的一則訊息：可能是某個請求的回應，也可能是韌體主動推送的通知。
public enum StudioMessage: Equatable, Sendable {
    case notification
    case response(requestId: UInt32, outcome: StudioOutcome)
    /// 兩種都不是；呼叫端應忽略，不推進請求序列。
    case unknown

    // studio.proto Response／RequestResponse 與 meta.proto、keymap.proto 的欄位編號
    static let REQUEST_RESPONSE_FIELD = 1
    static let NOTIFICATION_FIELD = 2
    static let REQUEST_ID_FIELD = 1
    static let META_FIELD = 2
    static let BEHAVIORS_FIELD = 4
    static let KEYMAP_FIELD = 5
    // meta.Response、behaviors.Response、keymap.Response 與其子訊息的欄位編號
    static let META_SIMPLE_ERROR_FIELD = 2
    static let BEHAVIOR_DETAILS_FIELD = 2
    static let DETAILS_ID_FIELD = 1
    static let DETAILS_NAME_FIELD = 2
    static let GET_KEYMAP_FIELD = 1
    static let SET_LAYER_BINDING_FIELD = 2
    static let CHECK_UNSAVED_FIELD = 3
    static let SAVE_CHANGES_FIELD = 4
    static let SAVE_OK_FIELD = 1
    static let SAVE_ERROR_FIELD = 2

    /// 解析一則已去除框架的 zmk.studio.Response。
    public static func decode(_ payload: [UInt8]) throws -> StudioMessage {
        let top = try ProtoWire.parseFields(payload)
        if try top.message(NOTIFICATION_FIELD) != nil { return .notification }
        guard let requestResponse = try top.message(REQUEST_RESPONSE_FIELD) else { return .unknown }
        let requestId = UInt32(truncatingIfNeeded: requestResponse.varint(REQUEST_ID_FIELD) ?? 0)
        return .response(requestId: requestId, outcome: try decodeOutcome(requestResponse))
    }

    private static func decodeOutcome(_ requestResponse: [ProtoField]) throws -> StudioOutcome {
        if let meta = try requestResponse.message(META_FIELD) {
            return meta.varint(META_SIMPLE_ERROR_FIELD).map { .metaError(code: $0) } ?? .unrecognized
        }
        if let behaviors = try requestResponse.message(BEHAVIORS_FIELD) {
            guard let details = try behaviors.message(BEHAVIOR_DETAILS_FIELD) else { return .unrecognized }
            return .behaviorDetails(id: UInt32(truncatingIfNeeded: details.varint(DETAILS_ID_FIELD) ?? 0),
                                    name: details.string(DETAILS_NAME_FIELD) ?? "")
        }
        guard let keymap = try requestResponse.message(KEYMAP_FIELD) else { return .unrecognized }
        if let keymapFields = try keymap.message(GET_KEYMAP_FIELD) { return .keymap(try Keymap.decode(keymapFields)) }
        if let code = keymap.varint(SET_LAYER_BINDING_FIELD) { return .setLayerBinding(code: code) }
        if let isUnsaved = keymap.varint(CHECK_UNSAVED_FIELD) { return .unsavedChanges(isUnsaved != 0) }
        if let save = try keymap.message(SAVE_CHANGES_FIELD) {
            let errorCode = save.varint(SAVE_ERROR_FIELD)
            return .saveChanges(isOk: save.varint(SAVE_OK_FIELD) == 1 && errorCode == nil, errorCode: errorCode)
        }
        return .unrecognized
    }
}

/// 單一請求的結果。summary 使用 proto 內的列舉名稱，方便對照上游原始碼。
public enum StudioOutcome: Equatable, Sendable {
    case metaError(code: UInt64)
    case setLayerBinding(code: UInt64)
    case saveChanges(isOk: Bool, errorCode: UInt64?)
    case unsavedChanges(Bool)
    case keymap(Keymap)
    case behaviorDetails(id: UInt32, name: String)
    case unrecognized

    static let META_ERRORS = ["GENERIC", "UNLOCK_REQUIRED", "RPC_NOT_FOUND", "MSG_DECODE_FAILED", "MSG_ENCODE_FAILED"]
    static let SET_BINDING_RESULTS = ["OK", "INVALID_LOCATION", "INVALID_BEHAVIOR", "INVALID_PARAMETERS"]
    static let SAVE_ERRORS = ["OK", "GENERIC", "NOT_SUPPORTED", "NO_SPACE"]

    public var isSuccess: Bool {
        switch self {
        case .setLayerBinding(let code): return code == 0
        case .saveChanges(let isOk, _): return isOk
        case .unsavedChanges, .keymap, .behaviorDetails: return true
        case .metaError, .unrecognized: return false
        }
    }

    public var summary: String {
        switch self {
        case .metaError(let code): return "meta 錯誤 \(Self.name(code, in: Self.META_ERRORS))"
        case .setLayerBinding(let code): return "set_layer_binding \(Self.name(code, in: Self.SET_BINDING_RESULTS))"
        case .saveChanges(true, _): return "save_changes ok"
        case .saveChanges(false, let code): return "save_changes 失敗 \(Self.name(code ?? 1, in: Self.SAVE_ERRORS))"
        case .unsavedChanges(let isUnsaved): return "check_unsaved_changes \(isUnsaved)"
        case .keymap(let keymap): return "get_keymap \(keymap.layers.count) 層"
        case .behaviorDetails(let id, let name): return "behavior \(id) = \(name)"
        case .unrecognized: return "無法辨識的回應"
        }
    }

    private static func name(_ code: UInt64, in names: [String]) -> String {
        code < names.count ? "\(names[Int(code)])(\(code))" : "未知代碼(\(code))"
    }
}
