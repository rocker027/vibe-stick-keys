import AppKit
import Foundation
import StickModel
import StudioBle

/// UI 狀態：從鍵盤讀到的配置、HID 監聽狀態，以及按鍵推論結果。所有更新都在主執行緒。
@MainActor
final class StickViewModel: ObservableObject {
    enum LoadState: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    /// 鍵盤是否經藍牙連上這台 Mac，依系統是否出現 YuVibeStick 的 HID 裝置判斷。
    enum ConnectionStatus: Equatable {
        case checking
        case connected
        case disconnected
        /// 沒有 HID 監聽（例如缺輸入監控權限），無法判斷。
        case unavailable
    }

    struct LogEntry: Identifiable, Equatable {
        let id = UUID()
        let time: String
        let text: String
        /// 未對應輸入、斷線等需要注意的事件以橘色顯示。
        let isWarning: Bool
    }

    static let MAX_LOG_ENTRIES = 14
    /// MIC 鍵帽在韌體裡綁定的 behavior 名稱；按住時經自訂服務收音。
    static let MIC_BEHAVIOR = "vibe_ptt"
    static let BYTES_PER_KILOBYTE = 1024.0
    /// 收音每 20 ms 一個 80 B 封包；推論為 8 kHz、4-bit IMA ADPCM（封包框架未確認，見 docs/button-map.md）。
    static let SAMPLE_RATE: UInt32 = 8000
    static let RECORDINGS_FOLDER = "VibeStickKeys/recordings"

    @Published private(set) var loadState = LoadState.loading
    @Published private(set) var keymap: StickKeymap?
    @Published private(set) var hidStatus = "啟動中"
    @Published private(set) var connectionStatus = ConnectionStatus.checking
    /// 最近一次連線狀態改變的時間。
    @Published private(set) var connectionChangedAt: String?
    @Published private(set) var pressedPositions: Set<Int> = []
    @Published private(set) var inferredLayerKeys: Set<Int> = []
    @Published private(set) var activeLayerIndex = 0
    /// 是否已收到至少一個對得上配置的按鍵；在那之前無法推論背面開關的位置。
    @Published private(set) var hasObservedKey = false
    @Published private(set) var log: [LogEntry] = []
    /// nil 表示自動跟隨推論的目前層。
    @Published var layerOverride: Int?
    @Published private(set) var micSession = MicSession()
    @Published private(set) var micMonitorStatus = VendorServiceMonitor.Status.idle
    @Published private(set) var lastRecordingByteCount = 0
    @Published private(set) var exportedWav: URL?
    @Published private(set) var exportMessage: String?

    private var tracker: PressTracker?
    private let listener = HidKeyListener()
    private var vendorMonitor: VendorServiceMonitor?
    /// 原始聲音資料不放進 @Published，避免每筆封包都複製整段陣列。
    private var audioBuffer = MicAudioBuffer()
    private var player: NSSound?
    private var hasStarted = false
    private var loadTask: Task<Void, Never>?
    /// 讀取進行中又重新連線時記下，讀完若失敗再補讀一次。
    private var shouldReloadAfterCurrentLoad = false

    var displayedLayerIndex: Int { layerOverride ?? activeLayerIndex }

    /// 綁定 vibe_ptt 的位置；配置還沒讀到時退回印字為 MIC 的鍵帽。
    var micPositions: Set<Int> {
        if let positions = keymap?.basePositions(withBehavior: Self.MIC_BEHAVIOR), !positions.isEmpty { return positions }
        return Set(StickProfile.BUTTONS.filter { $0.legend == "MIC" }.map(\.position))
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        // HID 回呼排在主執行緒的 run loop，所以可以直接視為在 MainActor 上
        let outcome = listener.start(
            onEvent: { [weak self] event in MainActor.assumeIsolated { self?.handle(event) } },
            onConnectionChange: { [weak self] isConnected in MainActor.assumeIsolated { self?.updateConnection(isConnected) } }
        )
        switch outcome {
        case .listening:
            hidStatus = "監聽中"
        case .failed(let reason):
            hidStatus = reason
            connectionStatus = .unavailable
        }
        diagnose("按鍵監聽：\(hidStatus)")
        startMicMonitor()
        reload()
    }

    /// 關閉 App 前呼叫：先把自訂服務的通知訂閱關回去。
    func shutdown(completion: @escaping () -> Void) {
        guard let vendorMonitor else { completion(); return }
        vendorMonitor.stop(completion: completion)
    }

    private func startMicMonitor() {
        let monitor = VendorServiceMonitor(
            onStatus: { [weak self] status in MainActor.assumeIsolated { self?.updateMicMonitor(status) } },
            onNotification: { [weak self] characteristic, bytes in
                MainActor.assumeIsolated { self?.handleVendor(characteristic: characteristic, bytes: bytes) }
            }
        )
        vendorMonitor = monitor
        monitor.start()
    }

    private func updateMicMonitor(_ status: VendorServiceMonitor.Status) {
        guard status != micMonitorStatus else { return }
        micMonitorStatus = status
        diagnose("麥克風通知：\(status)")
    }

    private func handleVendor(characteristic: String, bytes: [UInt8]) {
        let event = VendorEventParser.parse(characteristic: characteristic, bytes: bytes)
        let now = Date().timeIntervalSince1970
        audioBuffer.handle(event, at: now)
        if !micSession.isRecording, lastRecordingByteCount != audioBuffer.lastRecording.count {
            lastRecordingByteCount = audioBuffer.lastRecording.count
        }
        switch micSession.handle(event, at: now) {
        case .started:
            append("MIC 開始收音", isWarning: false)
        case .stopped(let summary):
            let kilobytes = Double(summary.byteCount) / Self.BYTES_PER_KILOBYTE
            append(String(format: "MIC 停止收音（%.1f 秒，%d 筆，%.1f KB）", summary.duration, summary.packetCount, kilobytes),
                   isWarning: false)
        case nil:
            break
        }
    }

    /// 把上一次收音的原始資料與解碼後的 WAV 存到 Application Support；只有使用者按下按鈕才寫入。
    func exportLastRecording() {
        let raw = audioBuffer.lastRecording
        guard !raw.isEmpty else { return }
        do {
            let folder = try recordingsFolder()
            let stem = "vibestick-" + Self.fileTimestamp()
            let wavURL = folder.appendingPathComponent(stem + ".wav")
            try Data(raw).write(to: folder.appendingPathComponent(stem + ".adpcm"))
            let samples = PeakNormalizer.normalize(ImaAdpcmDecoder.decode(packets: audioBuffer.lastPackets))
            try Data(WavEncoder.encode(samples: samples, sampleRate: Self.SAMPLE_RATE)).write(to: wavURL)
            exportedWav = wavURL
            let truncatedNote = audioBuffer.isLastTruncated ? "（超過上限已截斷）" : ""
            exportMessage = "已存 \(wavURL.lastPathComponent)\(truncatedNote)"
            diagnose("收音已存：\(wavURL.path)，原始 \(raw.count) B，\(samples.count) 個取樣")
        } catch {
            exportMessage = "存檔失敗：\(error.localizedDescription)"
        }
    }

    func playExported() {
        guard let exportedWav else { return }
        player?.stop()
        player = NSSound(contentsOf: exportedWav, byReference: true)
        player?.play()
    }

    func revealExported() {
        guard let exportedWav else { return }
        NSWorkspace.shared.activateFileViewerSelecting([exportedWav])
    }

    private func recordingsFolder() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        let folder = support.appendingPathComponent(Self.RECORDINGS_FOLDER, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func fileTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    /// 經藍牙重新讀取配置（只送唯讀請求）。讀取中再呼叫會被忽略，避免同時開兩條 BLE 連線。
    func reload() {
        guard loadTask == nil else { return }
        loadState = .loading
        loadTask = Task {
            defer { finishLoad() }
            do {
                let loaded = try await KeymapLoader.load()
                keymap = loaded
                tracker = PressTracker(keymap: loaded)
                clearPresses() // 新的 tracker 沒有舊的按下狀態，畫面也要一起清掉
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

    private func finishLoad() {
        loadTask = nil
        if shouldReloadAfterCurrentLoad {
            shouldReloadAfterCurrentLoad = false
            if loadState != .loaded { reload() }
        }
    }

    func label(position: Int, layerIndex: Int) -> String {
        keymap?.label(layerIndex: layerIndex, position: position) ?? "—"
    }

    func layerName(index: Int) -> String {
        guard let layers = keymap?.layers, layers.indices.contains(index) else { return "L\(index)" }
        return layers[index].name
    }

    private func updateConnection(_ isConnected: Bool) {
        let status: ConnectionStatus = isConnected ? .connected : .disconnected
        guard status != connectionStatus else { return }
        let wasDisconnected = connectionStatus == .disconnected
        connectionStatus = status
        connectionChangedAt = Date().formatted(date: .omitted, time: .standard)
        append(isConnected ? "鍵盤已連線" : "鍵盤已斷線", isWarning: !isConnected)
        if !isConnected { clearPresses(); micSession.reset(); audioBuffer.reset() }
        if isConnected { vendorMonitor?.start() } // 斷線後訂閱會消失，重新連上時重訂
        // 斷線期間讀取會失敗；重新連上且還沒有成功讀到配置時自動補讀
        guard isConnected, wasDisconnected, loadState != .loaded else { return }
        if loadTask == nil { reload() } else { shouldReloadAfterCurrentLoad = true }
    }

    private func clearPresses() {
        tracker?.reset()
        pressedPositions = []
        inferredLayerKeys = []
        activeLayerIndex = 0
        hasObservedKey = false
    }

    private func handle(_ event: HidEvent) {
        guard var current = tracker else {
            if event.isPressed { append("收到 \(event.usage.displayName)（配置尚未載入）", isWarning: true) }
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
            append("\(legend) 按下 → \(label(position: position, layerIndex: layerIndex))（\(layerName(index: layerIndex))）", isWarning: false)
        case .unmatched(let usage):
            append("未對應的輸入：\(usage.displayName)", isWarning: true)
        case .released, .ignored:
            break
        }
    }

    private func append(_ text: String, isWarning: Bool) {
        let time = Date().formatted(date: .omitted, time: .standard)
        log = Array(([LogEntry(time: time, text: text, isWarning: isWarning)] + log).prefix(Self.MAX_LOG_ENTRIES))
        diagnose("\(time) \(text)")
    }

    /// 從終端機啟動時的診斷輸出，方便在看不到視窗時核對狀態。
    private func diagnose(_ message: String) {
        print("[vibe-keys-ui] \(message)")
        fflush(stdout)
    }
}
