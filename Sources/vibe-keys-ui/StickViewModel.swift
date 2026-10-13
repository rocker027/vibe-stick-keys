import Foundation
import StickModel

/// UI 狀態：從鍵盤讀到的配置、HID 監聽狀態，以及按鍵推論結果。所有更新都在主執行緒。
@MainActor
final class StickViewModel: ObservableObject {
    enum LoadState: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    struct LogEntry: Identifiable, Equatable {
        let id = UUID()
        let time: String
        let text: String
        let isUnmatched: Bool
    }

    static let MAX_LOG_ENTRIES = 14

    @Published private(set) var loadState = LoadState.loading
    @Published private(set) var keymap: StickKeymap?
    @Published private(set) var hidStatus = "啟動中"
    @Published private(set) var pressedPositions: Set<Int> = []
    @Published private(set) var inferredLayerKeys: Set<Int> = []
    @Published private(set) var activeLayerIndex = 0
    /// 是否已收到至少一個對得上配置的按鍵；在那之前無法推論背面開關的位置。
    @Published private(set) var hasObservedKey = false
    @Published private(set) var log: [LogEntry] = []
    /// nil 表示自動跟隨推論的目前層。
    @Published var layerOverride: Int?

    private var tracker: PressTracker?
    private let listener = HidKeyListener()
    private var hasStarted = false

    var displayedLayerIndex: Int { layerOverride ?? activeLayerIndex }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        hidStatus = listener.start { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) } // HID 回呼排在主執行緒的 run loop
        }
        diagnose("按鍵監聽：\(hidStatus)")
        reload()
    }

    func reload() {
        loadState = .loading
        Task {
            do {
                let loaded = try await KeymapLoader.load()
                keymap = loaded
                tracker = PressTracker(keymap: loaded)
                loadState = .loaded
                diagnose("配置讀取完成：" + loaded.layers.indices.map { index in
                    let labels = StickProfile.BUTTONS.map { loaded.label(layerIndex: index, position: $0.position) }
                    return "\(loaded.layers[index].name)［" + labels.joined(separator: "／") + "］"
                }.joined(separator: " "))
            } catch {
                loadState = .failed("\(error)")
                diagnose("配置讀取失敗：\(error)")
            }
        }
    }

    func label(position: Int, layerIndex: Int) -> String {
        keymap?.label(layerIndex: layerIndex, position: position) ?? "—"
    }

    func layerName(index: Int) -> String {
        guard let layers = keymap?.layers, layers.indices.contains(index) else { return "L\(index)" }
        return layers[index].name
    }

    private func handle(_ event: HidEvent) {
        guard var current = tracker else {
            if event.isPressed { append("收到 \(event.usage.displayName)（配置尚未載入）", isUnmatched: true) }
            return
        }
        let pressResult = current.handle(event)
        tracker = current
        pressedPositions = current.pressedPositions
        inferredLayerKeys = current.inferredLayerKeys
        activeLayerIndex = current.activeLayerIndex
        describe(pressResult)
    }

    private func describe(_ pressResult: PressResult) {
        switch pressResult {
        case .pressed(let position, let layerIndex):
            hasObservedKey = true
            let legend = StickProfile.button(at: position)?.legend ?? "位置 \(position)"
            append("\(legend) 按下 → \(label(position: position, layerIndex: layerIndex))（\(layerName(index: layerIndex))）", isUnmatched: false)
        case .unmatched(let usage):
            append("未對應的輸入：\(usage.displayName)", isUnmatched: true)
        case .released, .ignored:
            break
        }
    }

    private func append(_ text: String, isUnmatched: Bool) {
        let time = Date().formatted(date: .omitted, time: .standard)
        log = Array(([LogEntry(time: time, text: text, isUnmatched: isUnmatched)] + log).prefix(Self.MAX_LOG_ENTRIES))
        diagnose("\(time) \(text)")
    }

    /// 從終端機啟動時的診斷輸出，方便在看不到視窗時核對狀態。
    private func diagnose(_ message: String) {
        print("[vibe-keys-ui] \(message)")
        fflush(stdout)
    }
}
