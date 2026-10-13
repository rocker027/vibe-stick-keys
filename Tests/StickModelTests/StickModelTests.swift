import Testing
@testable import StickModel
@testable import StudioProtocol

private func hex(_ text: String) -> [UInt8] {
    let chars = Array(text)
    return stride(from: 0, to: chars.count, by: 2).map { UInt8(String(chars[$0...$0 + 1]), radix: 16)! }
}

/// 2026-10-13 實機 get_keymap 回應（snapshots/2026-10-13-before.txt，request_id 3）。
private let REAL_KEYMAP_RESPONSE = "0AB90108032AB4010AB1010A3612094C3020E9BB98E8AEA41A0208321A06081010A8801C1A06081010A9801C1A07081010AB809C201A04081810021A04081810011A000A37080112094C3120E5AFBCE888AA1A06081010D2801C1A06081010D1801C1A06081010D0801C1A06081010CF801C1A0208301A0208301A000A3A0802120C4C3220E5A49AE5AA92E4BD931A06081010E981301A06081010EA81301A06081010E281301A06081010CD81301A0208301A0208301A0010031814"

/// 實機 behaviors.get_behavior_details 讀到的名稱（同日 probe 紀錄）。
private let REAL_BEHAVIOR_NAMES: [Int32: String] = [
    8: "Key Press", 12: "Momentary Layer", 13: "Layer-Tap", 14: "Mod-Tap", 15: "None",
    21: "To Layer", 22: "Toggle Layer", 24: "Transparent", 25: "vibe_ptt",
]

private func realKeymap() throws -> StickKeymap {
    guard case .response(_, .keymap(let keymap)) = try StudioMessage.decode(hex(REAL_KEYMAP_RESPONSE)) else {
        Issue.record("實機 keymap 回應沒有解成 keymap")
        throw ProtoDecodeError.truncated
    }
    return StickKeymap(keymap: keymap, behaviorNames: REAL_BEHAVIOR_NAMES)
}

private func keyboard(_ usage: UInt32, _ isPressed: Bool) -> HidEvent {
    HidEvent(page: 0x07, usage: usage, isPressed: isPressed)
}


private func keyPress(_ param: UInt32) -> KeyBinding { KeyBinding(behaviorId: 8, param1: param, param2: 0) }
private let TRANSPARENT = KeyBinding(behaviorId: 24, param1: 0, param2: 0)

/// 合成兩層配置：L1 的位置 1 為 Transparent，用來驗證往下層找的推論。
private func syntheticKeymap(base: [KeyBinding], upper: [KeyBinding]) -> StickKeymap {
    StickKeymap(keymap: Keymap(layers: [
        KeymapLayer(id: 0, name: "L0", bindings: base),
        KeymapLayer(id: 1, name: "L1", bindings: upper),
    ]), behaviorNames: REAL_BEHAVIOR_NAMES)
}

@Suite("實機 keymap 解碼")
struct KeymapDecodingTests {
    @Test("實機 get_keymap 回應解出三層與層名稱")
    func decodesLayers() throws {
        let keymap = try realKeymap()
        #expect(keymap.layers.map(\.name) == ["L0 默认", "L1 导航", "L2 多媒体"])
        #expect(keymap.layers.map(\.id) == [0, 1, 2])
    }

    @Test("L0 的綁定與 probe 解碼結果一致")
    func decodesBaseLayerBindings() throws {
        let bindings = try realKeymap().layers[0].bindings
        #expect(bindings == [
            KeyBinding(behaviorId: 25, param1: 0, param2: 0),
            KeyBinding(behaviorId: 8, param1: 0x0007_0028, param2: 0),
            KeyBinding(behaviorId: 8, param1: 0x0007_0029, param2: 0),
            KeyBinding(behaviorId: 8, param1: 0x0407_002B, param2: 0),
            KeyBinding(behaviorId: 12, param1: 2, param2: 0),
            KeyBinding(behaviorId: 12, param1: 1, param2: 0),
            KeyBinding(behaviorId: 0, param1: 0, param2: 0),
        ])
    }

    @Test("實機 behavior 詳細資料回應解出 ID 與名稱")
    func decodesBehaviorDetails() throws {
        let keyPress = try StudioMessage.decode(hex("0A2408282220121E080812094B65792050726573731A0F0A0D0A034B65792A0608FF0110FF01"))
        #expect(keyPress == .response(requestId: 0x28, outcome: .behaviorDetails(id: 8, name: "Key Press")))
        let vibe = try StudioMessage.decode(hex("0A120839220E120C08191208766962655F707474"))
        #expect(vibe == .response(requestId: 0x39, outcome: .behaviorDetails(id: 25, name: "vibe_ptt")))
    }

    @Test("唯讀請求與實機已驗證的位元組相同")
    func encodesReadRequestsLikeVerifiedProbe() {
        #expect(StudioRequest.getKeymap.encode(requestId: 3) == hex("08032A020801"))
        #expect(StudioRequest.getBehaviorDetails(behaviorId: 8).encode(requestId: 0x28) == hex("0828220412020808"))
    }

    @Test("behavior 詳細資料只接受同一個 behavior ID 的回應")
    func matchesBehaviorDetailsById() {
        #expect(StudioRequest.getBehaviorDetails(behaviorId: 8).accepts(.behaviorDetails(id: 8, name: "Key Press")))
        #expect(!StudioRequest.getBehaviorDetails(behaviorId: 8).accepts(.behaviorDetails(id: 25, name: "vibe_ptt")))
    }
}

@Suite("按鍵標籤")
struct LabelTests {
    @Test("L0 每顆鍵顯示實際對應的按鍵")
    func labelsBaseLayer() throws {
        let keymap = try realKeymap()
        #expect((0...5).map { keymap.label(layerIndex: 0, position: $0) } == [
            "vibe_ptt", "Enter", "Esc", "⌥ Tab", "按住切到 L2 多媒体", "按住切到 L1 导航",
        ])
    }

    @Test("L1 的 Transparent 顯示下層實際生效的功能")
    func labelsTransparentThroughLowerLayer() throws {
        let keymap = try realKeymap()
        #expect((0...5).map { keymap.label(layerIndex: 1, position: $0) } == [
            "↑", "↓", "←", "→", "按住切到 L2 多媒体", "按住切到 L1 导航",
        ])
    }

    @Test("consumer 按鍵顯示中文名稱")
    func labelsConsumerKeys() throws {
        let keymap = try realKeymap()
        #expect((0...3).map { keymap.label(layerIndex: 2, position: $0) } == ["音量 +", "音量 −", "靜音", "播放／暫停"])
    }

    @Test("修飾鍵依 macOS 符號顯示，Cmd+Tab 為 ⌘ Tab")
    func labelsModifierSymbols() {
        #expect(KeyCode(param: 0x0807_002B).displayName == "⌘ Tab")
        #expect(KeyCode(param: 0x0307_0004).displayName == "⌃⇧ A")
    }

    @Test("沒有綁定的位置顯示未設定")
    func labelsUnboundPosition() throws {
        #expect(try realKeymap().label(layerIndex: 0, position: 6) == "（未設定）")
    }
}

@Suite("按鍵推回實體鍵")
struct PressTrackerTests {
    @Test("Enter 按下時對應第 2 顆（位置 1），放開後取消")
    func tracksEnterPressAndRelease() throws {
        var tracker = PressTracker(keymap: try realKeymap())
        #expect(tracker.handle(keyboard(0x28, true)) == .pressed(position: 1, layerIndex: 0))
        #expect(tracker.pressedPositions == [1])
        #expect(tracker.handle(keyboard(0x28, false)) == .released(position: 1))
        #expect(tracker.pressedPositions.isEmpty)
    }

    @Test("Option+Tab 依實機事件順序對應第 4 顆，伴隨的 Option 被略過")
    func tracksOptionTabFromRealSequence() throws {
        var tracker = PressTracker(keymap: try realKeymap())
        #expect(tracker.handle(keyboard(0x2B, true)) == .pressed(position: 3, layerIndex: 0))
        #expect(tracker.handle(keyboard(0xE2, true)) == .ignored)
        #expect(tracker.handle(keyboard(0x2B, false)) == .released(position: 3))
        #expect(tracker.handle(keyboard(0xE2, false)) == .ignored)
        #expect(tracker.pressedPositions.isEmpty)
    }

    @Test("收到方向鍵時推論目前在 L1，並標出背面切換（位置 5）")
    func infersLayerOneFromArrowKey() throws {
        var tracker = PressTracker(keymap: try realKeymap())
        #expect(tracker.handle(keyboard(0x52, true)) == .pressed(position: 0, layerIndex: 1))
        #expect(tracker.activeLayerIndex == 1)
        #expect(tracker.inferredLayerKeys == [5])
    }

    @Test("回到 L0 的按鍵後，推論的切層鍵被清除")
    func clearsInferredLayerOnBaseKey() throws {
        var tracker = PressTracker(keymap: try realKeymap())
        _ = tracker.handle(keyboard(0x52, true))
        _ = tracker.handle(keyboard(0x52, false))
        #expect(tracker.handle(keyboard(0x29, true)) == .pressed(position: 2, layerIndex: 0))
        #expect(tracker.activeLayerIndex == 0)
        #expect(tracker.inferredLayerKeys.isEmpty)
    }

    @Test("音量鍵推論為 L2，並標出側邊按鈕（位置 4）")
    func infersLayerTwoFromConsumerKey() throws {
        var tracker = PressTracker(keymap: try realKeymap())
        #expect(tracker.handle(HidEvent(page: 0x0C, usage: 0xE9, isPressed: true)) == .pressed(position: 0, layerIndex: 2))
        #expect(tracker.inferredLayerKeys == [4])
    }

    @Test("對不上配置的按鍵列為未對應")
    func reportsUnmatchedKey() throws {
        var tracker = PressTracker(keymap: try realKeymap())
        #expect(tracker.handle(keyboard(0x68, true)) == .unmatched(HidUsage(page: 0x07, usage: 0x68)))
        #expect(tracker.handle(HidEvent(page: 0xFF00, usage: 0x01, isPressed: true))
            == .unmatched(HidUsage(page: 0xFF00, usage: 0x01)))
    }

    @Test("斷線重設後清掉按下中與推論的切層鍵，回到 L0")
    func resetsAfterDisconnect() throws {
        var tracker = PressTracker(keymap: try realKeymap())
        _ = tracker.handle(keyboard(0x52, true))
        tracker.reset()
        #expect(tracker.pressedPositions.isEmpty)
        #expect(tracker.inferredLayerKeys.isEmpty)
        #expect(tracker.activeLayerIndex == 0)
        #expect(tracker.handle(keyboard(0x52, false)) == .ignored)
    }

    @Test("上層 Transparent 的鍵按下時仍推論在上層，不誤判回到 L0")
    func keepsUpperLayerForTransparentKey() {
        let keymap = syntheticKeymap(
            base: [keyPress(0x0007_0052), keyPress(0x0007_0028), KeyBinding(behaviorId: 12, param1: 1, param2: 0)],
            upper: [keyPress(0x0007_0051), TRANSPARENT, TRANSPARENT]
        )
        var tracker = PressTracker(keymap: keymap)
        #expect(tracker.handle(keyboard(0x51, true)) == .pressed(position: 0, layerIndex: 1))
        _ = tracker.handle(keyboard(0x51, false))
        #expect(tracker.handle(keyboard(0x28, true)) == .pressed(position: 1, layerIndex: 1))
        #expect(tracker.activeLayerIndex == 1)
        #expect(tracker.inferredLayerKeys == [2])
    }

    @Test("伴隨送出的修飾鍵不會被當成另一顆綁了該修飾鍵的鍵")
    func ignoresImpliedModifierEvenIfBoundElsewhere() {
        let keymap = syntheticKeymap(base: [keyPress(0x0007_00E2), keyPress(0x0407_002B)], upper: [TRANSPARENT, TRANSPARENT])
        var tracker = PressTracker(keymap: keymap)
        #expect(tracker.handle(keyboard(0x2B, true)) == .pressed(position: 1, layerIndex: 0))
        #expect(tracker.handle(keyboard(0xE2, true)) == .ignored)
        #expect(tracker.pressedPositions == [1])
    }

    @Test("單獨綁定修飾鍵的鍵按下時仍能對應")
    func matchesStandaloneModifierBinding() {
        let keymap = syntheticKeymap(base: [keyPress(0x0007_00E2), keyPress(0x0407_002B)], upper: [TRANSPARENT, TRANSPARENT])
        var tracker = PressTracker(keymap: keymap)
        #expect(tracker.handle(keyboard(0xE2, true)) == .pressed(position: 0, layerIndex: 0))
    }

    @Test("同一個按鍵出現在多層時優先採用目前推論的層")
    func prefersCurrentLayerForSharedKey() {
        let keymap = syntheticKeymap(
            base: [keyPress(0x0007_0028), keyPress(0x0007_0029), KeyBinding(behaviorId: 12, param1: 1, param2: 0)],
            upper: [keyPress(0x0007_0052), keyPress(0x0007_0028), TRANSPARENT]
        )
        var tracker = PressTracker(keymap: keymap)
        #expect(tracker.handle(keyboard(0x28, true)) == .pressed(position: 0, layerIndex: 0))
        _ = tracker.handle(keyboard(0x28, false))
        _ = tracker.handle(keyboard(0x52, true))
        _ = tracker.handle(keyboard(0x52, false))
        #expect(tracker.handle(keyboard(0x28, true)) == .pressed(position: 1, layerIndex: 1))
    }

    @Test("consumer page 的集合 usage 0x01 被略過")
    func ignoresConsumerCollectionUsage() throws {
        var tracker = PressTracker(keymap: try realKeymap())
        #expect(tracker.handle(HidEvent(page: 0x0C, usage: 0x01, isPressed: true)) == .ignored)
    }

    @Test("macOS 陣列簿記值與滑鼠報告被略過")
    func ignoresBookkeepingAndMouse() throws {
        var tracker = PressTracker(keymap: try realKeymap())
        #expect(tracker.handle(keyboard(0xFFFF_FFFF, true)) == .ignored)
        #expect(tracker.handle(keyboard(0x01, false)) == .ignored)
        #expect(tracker.handle(HidEvent(page: 0x01, usage: 0x30, isPressed: true)) == .ignored)
        #expect(tracker.pressedPositions.isEmpty)
    }
}

@Suite("MIC 收音")
struct MicSessionTests {
    private let start = 1_000.0

    @Test("實機 A903 的 01／00 解析為收音開始／結束")
    func parsesRealMicState() {
        #expect(VendorEventParser.parse(characteristic: VendorEventParser.MIC_STATE_CHARACTERISTIC, bytes: [0x01]) == .micStarted)
        #expect(VendorEventParser.parse(characteristic: VendorEventParser.MIC_STATE_CHARACTERISTIC, bytes: [0x00]) == .micStopped)
    }

    @Test("A902 解析為聲音資料，其他特徵值保留原始內容")
    func parsesAudioAndOther() {
        let packet = [UInt8](repeating: 0x7A, count: 80)
        #expect(VendorEventParser.parse(characteristic: VendorEventParser.AUDIO_CHARACTERISTIC, bytes: packet) == .audioPacket(packet))
        let heartbeat = VendorEventParser.parse(characteristic: "1ACCAC91-73C2-41CA-AF88-7C02247CA905", bytes: [0x43, 0x00, 0x01])
        #expect(heartbeat == .other(characteristic: "1ACCAC91-73C2-41CA-AF88-7C02247CA905", bytes: [0x43, 0x00, 0x01]))
    }

    @Test("收音期間累計封包，結束時回報長度與資料量")
    func summarizesRecording() {
        var session = MicSession()
        #expect(session.handle(.micStarted, at: start) == .started)
        for _ in 0..<138 { _ = session.handle(.audioPacket([UInt8](repeating: 0, count: 80)), at: start) }
        #expect(session.isRecording)
        let change = session.handle(.micStopped, at: start + 2.5)
        #expect(change == .stopped(MicSummary(duration: 2.5, packetCount: 138, byteCount: 11040)))
        #expect(!session.isRecording)
    }

    @Test("收音結束後才到的封包不計入")
    func ignoresStragglerPacket() {
        var session = MicSession()
        _ = session.handle(.micStarted, at: start)
        _ = session.handle(.micStopped, at: start + 1)
        #expect(session.handle(.audioPacket([1, 2]), at: start + 1.01) == nil)
        #expect(session.byteCount == 0)
        #expect(session.lastSummary == MicSummary(duration: 1, packetCount: 0, byteCount: 0))
    }

    @Test("斷線重設後回到待命")
    func resetsOnDisconnect() {
        var session = MicSession()
        _ = session.handle(.micStarted, at: start)
        session.reset()
        #expect(!session.isRecording)
        #expect(session.handle(.micStopped, at: start) == nil)
    }

    @Test("從實機配置找出綁定 vibe_ptt 的位置")
    func findsVibePttPosition() throws {
        #expect(try realKeymap().basePositions(withBehavior: "vibe_ptt") == [0])
    }
}

@Suite("收音解碼")
struct MicAudioTests {
    @Test("IMA ADPCM 依標準表解碼（手算：7→11、F→-19、0→-15、0→-12）")
    func decodesImaAdpcmLowNibbleFirst() {
        #expect(ImaAdpcmDecoder.decode([0xF7, 0x00], order: .lowFirst) == [11, -19, -15, -12])
    }

    @Test("高位元先解時，同樣的半位元組順序得到同樣結果")
    func decodesImaAdpcmHighNibbleFirst() {
        #expect(ImaAdpcmDecoder.decode([0x7F, 0x00], order: .highFirst) == [11, -19, -15, -12])
    }

    @Test("連續最大正值時 predictor 夾在 Int16 範圍內")
    func clampsPredictor() {
        let samples = ImaAdpcmDecoder.decode([UInt8](repeating: 0x77, count: 200), order: .highFirst)
        #expect(samples.last == Int16.max)
    }

    @Test("逐封包解碼時每個封包都從初始狀態開始")
    func decodesEachPacketFromInitialState() {
        #expect(ImaAdpcmDecoder.decode(packets: [[0xF7], [0xF7]]) == [11, -19, 11, -19])
        #expect(ImaAdpcmDecoder.decode(packets: [[0x7F], [0x7F]], order: .highFirst) == [11, -19, 11, -19])
        #expect(ImaAdpcmDecoder.decode([0xF7, 0xF7], order: .lowFirst) != [11, -19, 11, -19])
    }

    @Test("正規化把峰值放大到滿刻度的 90%，保持比例與正負號")
    func normalizesPeak() {
        #expect(PeakNormalizer.normalize([100, -200, 50]) == [14745, -29490, 7373])
        #expect(PeakNormalizer.normalize([0, 0]) == [0, 0])
    }

    @Test("WAV 標頭為 16-bit PCM 單聲道 8 kHz")
    func writesWavHeader() {
        let wav = WavEncoder.encode(samples: [1, -1], sampleRate: 8000)
        #expect(wav.count == 48)
        #expect(Array(wav[0..<4]) == Array("RIFF".utf8))
        #expect(Array(wav[4..<8]) == [40, 0, 0, 0])
        #expect(Array(wav[20..<36]) == [1, 0, 1, 0, 0x40, 0x1F, 0, 0, 0x80, 0x3E, 0, 0, 2, 0, 16, 0])
        #expect(Array(wav[40..<48]) == [4, 0, 0, 0, 1, 0, 0xFF, 0xFF])
    }

    @Test("收音緩衝保留整段資料，並併入結束後 0.2 秒內的最後一筆")
    func buffersRecordingWithStraggler() {
        var buffer = MicAudioBuffer()
        buffer.handle(.micStarted, at: 0)
        buffer.handle(.audioPacket([1, 2]), at: 0.02)
        buffer.handle(.micStopped, at: 0.04)
        buffer.handle(.audioPacket([3]), at: 0.05)
        buffer.handle(.audioPacket([4]), at: 1.0)
        #expect(buffer.lastPackets == [[1, 2], [3]])
        #expect(buffer.lastRecording == [1, 2, 3])
    }

    @Test("收音緩衝超過上限時截斷並標記")
    func truncatesLongRecording() {
        var buffer = MicAudioBuffer()
        buffer.handle(.micStarted, at: 0)
        buffer.handle(.audioPacket([UInt8](repeating: 0, count: MicAudioBuffer.MAX_BYTES - 40)), at: 1)
        buffer.handle(.audioPacket([UInt8](repeating: 0, count: 80)), at: 1.02)
        buffer.handle(.micStopped, at: 2)
        #expect(buffer.lastRecording.count == MicAudioBuffer.MAX_BYTES - 40)
        #expect(buffer.isLastTruncated)
    }
}
