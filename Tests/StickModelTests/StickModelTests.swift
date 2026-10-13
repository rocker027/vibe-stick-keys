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

    @Test("macOS 陣列簿記值與滑鼠報告被略過")
    func ignoresBookkeepingAndMouse() throws {
        var tracker = PressTracker(keymap: try realKeymap())
        #expect(tracker.handle(keyboard(0xFFFF_FFFF, true)) == .ignored)
        #expect(tracker.handle(keyboard(0x01, false)) == .ignored)
        #expect(tracker.handle(HidEvent(page: 0x01, usage: 0x30, isPressed: true)) == .ignored)
        #expect(tracker.pressedPositions.isEmpty)
    }
}
