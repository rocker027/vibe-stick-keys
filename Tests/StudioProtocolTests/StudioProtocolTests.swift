import Testing
@testable import StudioProtocol

private func hex(_ text: String) -> [UInt8] {
    let chars = Array(text)
    return stride(from: 0, to: chars.count, by: 2).map { UInt8(String(chars[$0...$0 + 1]), radix: 16)! }
}

private let LGUI_TAB: UInt32 = 0x0807_002B

@Suite("框架")
struct FramingTests {
    @Test("框架編碼在特殊位元組前插入跳脫字元")
    func escapesSpecialBytes() {
        #expect(Framing.encode([0x01, 0xAB, 0xAC, 0xAD]) == hex("AB01ACABACACACADAD"))
    }

    @Test("框架解碼可把跨片段的訊息組回完整內容")
    func reassemblesAcrossChunks() {
        var decoder = FrameDecoder()
        #expect(decoder.feed(hex("AB0801")).isEmpty)
        #expect(decoder.feed(hex("1A02AD")) == [hex("08011A02")])
    }

    @Test("框架解碼可從單一片段取出多則訊息")
    func splitsMultipleFramesInOneChunk() {
        var decoder = FrameDecoder()
        #expect(decoder.feed(hex("AB01ADAB02AD")) == [[0x01], [0x02]])
    }

    @Test("ESC 落在片段結尾時，下一片段的位元組仍被當成資料")
    func keepsEscapeStateAcrossChunks() {
        var decoder = FrameDecoder()
        #expect(decoder.feed(hex("AB01AC")).isEmpty)
        #expect(decoder.feed(hex("AD02AD")) == [hex("01AD02")])
    }

    @Test("框架中途出現未跳脫的 SOF 時丟棄前段並重新開始")
    func resynchronizesOnUnexpectedStart() {
        var decoder = FrameDecoder()
        #expect(decoder.feed(hex("AB0102AB0304AD")) == [hex("0304")])
    }

    @Test("框架編碼後再解碼得到原始內容")
    func roundTripsEscapedPayload() {
        let payload: [UInt8] = [0xAB, 0x00, 0xAD, 0xAC, 0x7F]
        var decoder = FrameDecoder()
        #expect(decoder.feed(Framing.encode(payload)) == [payload])
    }
}

@Suite("請求編碼契約")
struct RequestEncodingTests {
    @Test("set_layer_binding 依 proto 欄位編碼，behavior_id 用 zigzag")
    func encodesSetLayerBinding() {
        let change = LayerBindingChange(layerId: 0, keyPosition: 3, behaviorId: 8, param1: LGUI_TAB, param2: 0)
        let encoded = StudioRequest.setLayerBinding(change).encode(requestId: 1)
        #expect(encoded == hex("08012A0D120B10031A07081010AB809C40"))
    }

    @Test("set_layer_binding 的非零 layer 與 param2 會編碼")
    func encodesNonZeroLayerAndParam2() {
        let change = LayerBindingChange(layerId: 2, keyPosition: 0, behaviorId: 14, param1: 1, param2: 2)
        let encoded = StudioRequest.setLayerBinding(change).encode(requestId: 7)
        #expect(encoded == hex("08072A0C120A08021A06081C10011802"))
    }

    @Test("預定的 set 指令框架為 20 位元組，在韌體 RX 緩衝 30 位元組內")
    func plannedSetFrameFitsFirmwareBuffer() throws {
        let invocation = try CommandParser.parse(["set", "0", "3", "8", "0x0807002B"])
        #expect(invocation.framedRequests() == [hex("AB08012A0D120B10031A07081010ACAB809C40AD")])
        #expect(invocation.framedRequests()[0].count == 20)
    }

    @Test("請求只接受對應種類的回應，meta 錯誤對任何請求都成立")
    func matchesResponseKind() {
        #expect(StudioRequest.saveChanges.accepts(.saveChanges(isOk: true, errorCode: nil)))
        #expect(!StudioRequest.saveChanges.accepts(.unsavedChanges(false)))
        #expect(!StudioRequest.checkUnsavedChanges.accepts(.saveChanges(isOk: true, errorCode: nil)))
        #expect(StudioRequest.checkUnsavedChanges.accepts(.metaError(code: 1)))
    }

    @Test("只有 set 與 save 被視為會改動鍵盤的請求")
    func classifiesMutatingRequests() {
        let change = LayerBindingChange(layerId: 0, keyPosition: 3, behaviorId: 8, param1: LGUI_TAB, param2: 0)
        #expect(StudioRequest.setLayerBinding(change).isMutating)
        #expect(StudioRequest.saveChanges.isMutating)
        #expect(!StudioRequest.checkUnsavedChanges.isMutating)
        #expect(!StudioRequest.getKeymap.isMutating)
        #expect(!StudioRequest.getBehaviorDetails(behaviorId: 8).isMutating)
    }

    @Test("keymap 中負數的 behavior_id 依 sint32 zigzag 還原")
    func decodesNegativeBehaviorId() throws {
        // Keymap{ layers{ id 0, bindings{ behavior_id = zigzag(-3) = 5 } } }，包在 get_keymap 回應裡
        let message = try StudioMessage.decode(hex("0A0C08012A080A060A041A020805"))
        guard case .response(_, .keymap(let keymap)) = message else { Issue.record("沒有解成 keymap"); return }
        #expect(keymap.layers.first?.bindings == [KeyBinding(behaviorId: -3, param1: 0, param2: 0)])
    }

    @Test("save_changes 請求編碼為 keymap 欄位 4")
    func encodesSaveChanges() {
        #expect(StudioRequest.saveChanges.encode(requestId: 2) == hex("08022A022001"))
    }

    @Test("check_unsaved_changes 請求與實機已驗證的位元組相同")
    func encodesCheckUnsavedLikeVerifiedProbe() {
        #expect(StudioRequest.checkUnsavedChanges.encode(requestId: 6) == hex("08062A021801"))
    }
}

// set／save 的回應向量為依 proto 與 nanopb oneof 行為手工合成；check_unsaved 與 lock state 為實機回傳。
@Suite("回應解析契約")
struct ResponseDecodingTests {
    @Test("set 成功回應解析為 OK")
    func decodesSetOk() throws {
        let message = try StudioMessage.decode(hex("0A0608012A021000"))
        #expect(message == .response(requestId: 1, outcome: .setLayerBinding(code: 0)))
        #expect(StudioOutcome.setLayerBinding(code: 0).isSuccess)
    }

    @Test("set 位置錯誤回應解析為 INVALID_LOCATION 且不算成功")
    func decodesSetInvalidLocation() throws {
        let message = try StudioMessage.decode(hex("0A0608012A021001"))
        #expect(message == .response(requestId: 1, outcome: .setLayerBinding(code: 1)))
        #expect(!StudioOutcome.setLayerBinding(code: 1).isSuccess)
        #expect(StudioOutcome.setLayerBinding(code: 1).summary.contains("INVALID_LOCATION"))
    }

    @Test("save 成功回應解析為 ok")
    func decodesSaveOk() throws {
        let message = try StudioMessage.decode(hex("0A0808022A0422020801"))
        #expect(message == .response(requestId: 2, outcome: .saveChanges(isOk: true, errorCode: nil)))
    }

    @Test("save 失敗回應帶錯誤碼且不算成功")
    func decodesSaveError() throws {
        let message = try StudioMessage.decode(hex("0A0808022A0422021003"))
        let outcome = StudioOutcome.saveChanges(isOk: false, errorCode: 3)
        #expect(message == .response(requestId: 2, outcome: outcome))
        #expect(!outcome.isSuccess)
        #expect(outcome.summary.contains("NO_SPACE"))
    }

    @Test("實機 check_unsaved_changes 回應解析為 true")
    func decodesRealUnsavedTrue() throws {
        let message = try StudioMessage.decode(hex("0A0608062A021801"))
        #expect(message == .response(requestId: 6, outcome: .unsavedChanges(true)))
    }

    @Test("check_unsaved_changes 為 false 時也能解析")
    func decodesUnsavedFalse() throws {
        let message = try StudioMessage.decode(hex("0A0608062A021800"))
        #expect(message == .response(requestId: 6, outcome: .unsavedChanges(false)))
    }

    @Test("meta 錯誤解析為 UNLOCK_REQUIRED 且不算成功")
    func decodesUnlockRequired() throws {
        let message = try StudioMessage.decode(hex("0A06080112021001"))
        #expect(message == .response(requestId: 1, outcome: .metaError(code: 1)))
        #expect(StudioOutcome.metaError(code: 1).summary.contains("UNLOCK_REQUIRED"))
    }

    @Test("Notification 不視為請求回應")
    func decodesNotification() throws {
        #expect(try StudioMessage.decode(hex("12042A020801")) == .notification)
    }

    @Test("既非回應也非通知的訊息解析為 unknown")
    func decodesUnknownTopLevel() throws {
        #expect(try StudioMessage.decode(hex("1801")) == .unknown)
    }

    @Test("工具不處理的子系統回應解析為 unrecognized")
    func decodesRealLockStateAsUnrecognized() throws {
        let message = try StudioMessage.decode(hex("0A0608021A021001"))
        #expect(message == .response(requestId: 2, outcome: .unrecognized))
        #expect(!StudioOutcome.unrecognized.isSuccess)
    }

    @Test("長度 varint 溢位時回報解碼錯誤而不是崩潰")
    func rejectsOverflowingLength() {
        #expect(throws: ProtoDecodeError.self) { try StudioMessage.decode(hex("0AFFFFFFFFFFFFFFFFFF0101")) }
    }

    @Test("未知的 fixed32／fixed64 欄位被略過")
    func skipsFixedWidthFields() throws {
        let message = try StudioMessage.decode(hex("0A0608062A021801") + hex("1D01020304") + hex("210102030405060708"))
        #expect(message == .response(requestId: 6, outcome: .unsavedChanges(true)))
    }

    @Test("截斷的資料回報解碼錯誤")
    func rejectsTruncatedPayload() {
        #expect(throws: ProtoDecodeError.self) { try StudioMessage.decode(hex("0A060801")) }
    }
}

@Suite("指令解析")
struct CommandParserTests {
    @Test("set 指令解析出 layer、position、behavior 與十六進位參數")
    func parsesSetCommand() throws {
        let invocation = try CommandParser.parse(["set", "0", "3", "8", "0x0807002B"])
        let change = LayerBindingChange(layerId: 0, keyPosition: 3, behaviorId: 8, param1: LGUI_TAB, param2: 0)
        #expect(invocation == Invocation(requests: [.setLayerBinding(change)], isDryRun: false))
    }

    @Test("save 指令依序產生 check、save、check 三個請求")
    func parsesSaveCommand() throws {
        let invocation = try CommandParser.parse(["save"])
        #expect(invocation.requests == [.checkUnsavedChanges, .saveChanges, .checkUnsavedChanges])
    }

    @Test("--dry-run 旗標被辨識")
    func parsesDryRun() throws {
        #expect(try CommandParser.parse(["save", "--dry-run"]).isDryRun)
    }

    @Test("position 超出實體按鍵範圍 0–5 被拒絕")
    func rejectsOutOfRangePosition() {
        #expect(throws: CommandError.self) { try CommandParser.parse(["set", "0", "6", "8", "4"]) }
        #expect(throws: CommandError.self) { try CommandParser.parse(["set", "0", "-1", "8", "4"]) }
    }

    @Test("非數字或超出型別範圍的參數被拒絕")
    func rejectsInvalidNumbers() {
        #expect(throws: CommandError.self) { try CommandParser.parse(["set", "0", "3", "eight", "4"]) }
        #expect(throws: CommandError.self) { try CommandParser.parse(["set", "0", "3", "8", "0x1FFFFFFFF"]) }
    }

    @Test("layer 超過 255 被拒絕，避免韌體截成 uint8 寫到別層")
    func rejectsLayerBeyondUInt8() {
        #expect(throws: CommandError.self) { try CommandParser.parse(["set", "256", "3", "8", "4"]) }
    }

    @Test("behavior 超過 65535 被拒絕，避免韌體截成 uint16 變成別的 behavior")
    func rejectsBehaviorBeyondUInt16() {
        #expect(throws: CommandError.self) { try CommandParser.parse(["set", "0", "3", "65544", "4"]) }
    }

    @Test("帶正負號的數字被拒絕")
    func rejectsSignedNumbers() {
        for text in ["0x-8", "0x+8", "+5", "-1"] {
            #expect(throws: CommandError.self) { try CommandParser.parse(["set", "0", "3", text, "4"]) }
        }
    }

    @Test("編碼後超過 30 位元組的框架在連線前被拒絕")
    func rejectsFrameBeyondFirmwareBuffer() {
        #expect(throws: CommandError.frameTooLong(31)) {
            try CommandParser.parse(["set", "255", "5", "65535", "0xFFFFFFFF", "0xFFFFFFFF"])
        }
    }

    @Test("缺少參數被拒絕")
    func rejectsMissingArguments() {
        #expect(throws: CommandError.self) { try CommandParser.parse(["set", "0", "3"]) }
    }

    @Test("沒有 discard、reset 等其他指令")
    func rejectsUnsupportedCommands() {
        #expect(throws: CommandError.self) { try CommandParser.parse(["discard"]) }
        #expect(throws: CommandError.self) { try CommandParser.parse(["reset"]) }
        #expect(throws: CommandError.self) { try CommandParser.parse([]) }
    }
}
