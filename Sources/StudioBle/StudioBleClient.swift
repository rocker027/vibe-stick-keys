@preconcurrency import CoreBluetooth
import Foundation
import StudioProtocol

public enum StudioBleError: Error, CustomStringConvertible {
    case bluetoothUnavailable(String)
    case deviceNotFound(String)
    case setupFailed(String)
    case busy
    case mutationNotAllowed(String)
    case frameTooLong(Int)
    /// 斷線或逾時時若有請求已送出，韌體可能已經執行它，只是回應沒收到。
    case disconnected(inFlight: String?)
    case timeout(inFlight: String?)
    case writeFailed(String)
    case unexpectedResponse(String)

    public var description: String {
        switch self {
        case .bluetoothUnavailable(let reason): return "藍牙不可用：\(reason)"
        case .deviceNotFound(let name): return "找不到已連線的 \(name)"
        case .setupFailed(let reason): return "連線設定失敗：\(reason)"
        case .busy: return "上一個請求或連線尚未完成"
        case .mutationNotAllowed(let name): return "這個 client 不允許送出會改動鍵盤的請求（\(name)）"
        case .frameTooLong(let count): return "框架 \(count) 位元組超過韌體上限 \(Framing.MAX_FIRMWARE_FRAME_BYTES)"
        case .disconnected(let inFlight): return "連線中斷" + Self.inFlightNote(inFlight)
        case .timeout(let inFlight):
            // 韌體只在 BLE 是目前輸出端點時處理寫入；切到 USB 輸出時會默默丟棄，只能等到逾時
            return "逾時（若鍵盤輸出切到 USB，藍牙請求會被忽略）" + Self.inFlightNote(inFlight)
        case .writeFailed(let reason): return "寫入失敗：\(reason)"
        case .unexpectedResponse(let detail): return "回應無法解讀：\(detail)。請求可能已執行，請用 probe 讀回確認"
        }
    }

    private static func inFlightNote(_ inFlight: String?) -> String {
        guard let inFlight else { return "" }
        return "；\(inFlight) 已送出但未收到回應，鍵盤可能已執行。請用 probe 讀回確認；重跑 set／save 是安全的"
    }
}

/// 透過 BLE 呼叫 ZMK Studio RPC 的 client：一次只處理一個請求，等到對應回應才完成。
/// 所有 CoreBluetooth 回呼與內部狀態都在同一條序列 queue 上，continuation 也只在這條 queue 上 resume。
/// 標為 @unchecked Sendable：所有可變狀態只在私有序列 queue 上讀寫；onTrace 與 allowsMutation 在建立時固定。
public final class StudioBleClient: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
    public static let STUDIO_SERVICE = CBUUID(string: "00000000-0196-6107-C967-C5CFB1C2482A")
    public static let RPC_CHARACTERISTIC = CBUUID(string: "00000001-0196-6107-C967-C5CFB1C2482A")
    static let MIN_WRITE_CHUNK = 20 // BLE 預設 ATT MTU 23 扣掉 3 位元組標頭

    private struct InFlight {
        let request: StudioRequest
        let requestId: UInt32
        let continuation: CheckedContinuation<StudioOutcome, Error>
        var description: String { "#\(requestId) \(request.name)" }
    }

    private let targetName: String
    private let queue = DispatchQueue(label: "vibe-stick-keys.ble")
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var rpcCharacteristic: CBCharacteristic?
    private var frameDecoder = FrameDecoder()
    private var pendingChunks: [Data] = []
    private var nextRequestId: UInt32 = 1
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var inFlight: InFlight?
    private var timeoutGeneration = 0

    /// 收發的原始框架與略過的通知；CLI 用來印出證據。回呼在 BLE queue 上執行。
    private let onTrace: ((String) -> Void)?
    /// 預設 false：只允許唯讀請求。只有 CLI 會明確開啟。
    private let allowsMutation: Bool

    public init(targetName: String = "YuVibeStick", allowsMutation: Bool = false, onTrace: ((String) -> Void)? = nil) {
        self.targetName = targetName
        self.allowsMutation = allowsMutation
        self.onTrace = onTrace
    }

    public func connect(timeout: TimeInterval = 15) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                // 每個 client 只連線一次；重複呼叫會覆寫 continuation 讓前一個呼叫永遠等不到結果
                guard self.central == nil, self.connectContinuation == nil else {
                    continuation.resume(throwing: StudioBleError.busy)
                    return
                }
                self.connectContinuation = continuation
                self.armTimeout(timeout)
                self.central = CBCentralManager(delegate: self, queue: self.queue)
            }
        }
    }

    /// 送出一個請求並等待回應。request_id 從 1 開始遞增，與 dry-run 印出的框架一致。
    public func send(_ request: StudioRequest, timeout: TimeInterval = 10) async throws -> StudioOutcome {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<StudioOutcome, Error>) in
            queue.async { self.start(request, timeout: timeout, continuation: continuation) }
        }
    }

    public func disconnect() {
        queue.async {
            if let peripheral = self.peripheral { self.central?.cancelPeripheralConnection(peripheral) }
        }
    }

    private func start(_ request: StudioRequest, timeout: TimeInterval, continuation: CheckedContinuation<StudioOutcome, Error>) {
        guard inFlight == nil, connectContinuation == nil else { continuation.resume(throwing: StudioBleError.busy); return }
        guard allowsMutation || !request.isMutating else {
            continuation.resume(throwing: StudioBleError.mutationNotAllowed(request.name))
            return
        }
        guard let device = peripheral, rpcCharacteristic != nil else {
            continuation.resume(throwing: StudioBleError.disconnected(inFlight: nil))
            return
        }
        let frame = Framing.encode(request.encode(requestId: nextRequestId))
        guard frame.count <= Framing.MAX_FIRMWARE_FRAME_BYTES else {
            continuation.resume(throwing: StudioBleError.frameTooLong(frame.count))
            return
        }
        inFlight = InFlight(request: request, requestId: nextRequestId, continuation: continuation)
        nextRequestId += 1
        onTrace?(">> #\(nextRequestId - 1) \(Framing.hexString(frame))")
        // 用 withoutResponse 的上限（ATT_MTU-3）切塊，讓每塊都是單一 Write Request、不走 Prepare/Execute 長寫入：
        // 韌體 write_rpc_req 忽略 offset，長寫入會出錯。
        let chunkSize = max(Self.MIN_WRITE_CHUNK, device.maximumWriteValueLength(for: .withoutResponse))
        pendingChunks = stride(from: 0, to: frame.count, by: chunkSize).map { Data(frame[$0..<min($0 + chunkSize, frame.count)]) }
        armTimeout(timeout)
        writeNextChunk()
    }

    private func writeNextChunk() {
        guard !pendingChunks.isEmpty, let device = peripheral, let characteristic = rpcCharacteristic else { return }
        device.writeValue(pendingChunks.removeFirst(), for: characteristic, type: .withResponse)
    }

    private func armTimeout(_ seconds: TimeInterval) {
        timeoutGeneration += 1
        let generation = timeoutGeneration
        queue.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, generation == self.timeoutGeneration else { return }
            self.failPending(StudioBleError.timeout(inFlight: self.inFlight?.description))
        }
    }

    private func failPending(_ error: Error) {
        timeoutGeneration += 1
        connectContinuation?.resume(throwing: error)
        connectContinuation = nil
        inFlight?.continuation.resume(throwing: error)
        inFlight = nil
        pendingChunks = []
    }

    private func completeConnect() {
        timeoutGeneration += 1
        connectContinuation?.resume()
        connectContinuation = nil
    }

    // MARK: - CBCentralManagerDelegate

    public func centralManagerDidUpdateState(_ bleCentral: CBCentralManager) {
        switch bleCentral.state {
        case .poweredOn: break
        case .unauthorized: failPending(StudioBleError.bluetoothUnavailable("沒有藍牙權限")); return
        case .unsupported, .poweredOff: failPending(StudioBleError.bluetoothUnavailable("state \(bleCentral.state.rawValue)")); return
        default: return
        }
        guard connectContinuation != nil, peripheral == nil else { return } // 只在初次連線時尋找裝置
        // 系統已連上的 HID 裝置不會廣播，必須用 retrieveConnectedPeripherals 取得。
        let candidates = bleCentral.retrieveConnectedPeripherals(withServices: [Self.STUDIO_SERVICE])
        guard let target = candidates.first(where: { ($0.name ?? "").contains(targetName) }) else {
            failPending(StudioBleError.deviceNotFound(targetName))
            return
        }
        peripheral = target
        target.delegate = self
        bleCentral.connect(target, options: nil)
    }

    public func centralManager(_ bleCentral: CBCentralManager, didConnect connected: CBPeripheral) {
        connected.discoverServices([Self.STUDIO_SERVICE])
    }

    public func centralManager(_ bleCentral: CBCentralManager, didFailToConnect failed: CBPeripheral, error: Error?) {
        failPending(StudioBleError.setupFailed(error?.localizedDescription ?? "無法連線"))
    }

    public func centralManager(_ bleCentral: CBCentralManager, didDisconnectPeripheral lost: CBPeripheral, error: Error?) {
        rpcCharacteristic = nil
        failPending(StudioBleError.disconnected(inFlight: inFlight?.description))
    }

    // MARK: - CBPeripheralDelegate

    public func peripheral(_ device: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let service = device.services?.first(where: { $0.uuid == Self.STUDIO_SERVICE }) else {
            failPending(StudioBleError.setupFailed("找不到 ZMK Studio 服務 \(error?.localizedDescription ?? "")"))
            return
        }
        device.discoverCharacteristics([Self.RPC_CHARACTERISTIC], for: service)
    }

    public func peripheral(_ device: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil, let characteristic = service.characteristics?.first(where: { $0.uuid == Self.RPC_CHARACTERISTIC }) else {
            failPending(StudioBleError.setupFailed("找不到 RPC 特徵值 \(error?.localizedDescription ?? "")"))
            return
        }
        rpcCharacteristic = characteristic
        // 回應以 indication 送回，必須先訂閱。韌體是否接受寫入另由「BLE 是否為目前輸出端點」決定（gatt_start_rx）。
        device.setNotifyValue(true, for: characteristic)
    }

    public func peripheral(_ device: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            failPending(StudioBleError.setupFailed("開啟 indication 失敗：\(error.localizedDescription)"))
            return
        }
        guard characteristic.isNotifying else { return }
        completeConnect()
    }

    public func peripheral(_ device: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            failPending(StudioBleError.writeFailed(error.localizedDescription))
            return
        }
        writeNextChunk()
    }

    public func peripheral(_ device: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let chunk = characteristic.value else { return }
        for payload in frameDecoder.feed([UInt8](chunk)) { handle(payload) }
    }

    private func handle(_ payload: [UInt8]) {
        onTrace?("<< \(Framing.hexString(payload))")
        let message: StudioMessage
        do { message = try StudioMessage.decode(payload) } catch {
            failPending(StudioBleError.unexpectedResponse("無法解碼 \(error)"))
            return
        }
        guard case .response(let requestId, let outcome) = message, let current = inFlight, requestId == current.requestId else {
            onTrace?("   （通知或非目前請求的回應，略過）")
            return
        }
        inFlight = nil
        timeoutGeneration += 1
        guard current.request.accepts(outcome) else {
            current.continuation.resume(throwing: StudioBleError.unexpectedResponse("\(current.description) 收到 \(outcome.summary)"))
            return
        }
        current.continuation.resume(returning: outcome)
    }
}
