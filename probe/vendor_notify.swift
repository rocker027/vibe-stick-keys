// 監聽 YuVibeStick 賣家自訂服務 1ACCAC91-… 的通知，用來判斷按下 MIC（vibe_ptt）時傳出什麼。
// 只訂閱通知（寫入標準 CCCD），不寫入任何特徵值；結束前把所有訂閱關回去。
// 用法：vendor_notify [秒數，預設 120]；收到 SIGINT／SIGTERM 也會先取消訂閱再結束。
import CoreBluetooth
import Foundation

setbuf(stdout, nil)

let TARGET_NAME = "YuVibeStick"
let VENDOR_SERVICE = CBUUID(string: "1ACCAC91-73C2-41CA-AF88-7C02247CA900")
let LISTEN_SECONDS = Double(CommandLine.arguments.dropFirst().first ?? "") ?? 120
let MAX_PRINTED_BYTES = 32
let UNSUBSCRIBE_GRACE_SECONDS = 3.0

func timestamp() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    return formatter.string(from: Date())
}

final class VendorNotifyListener: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var subscribed: [CBCharacteristic] = []
    private var byteCountByCharacteristic: [String: Int] = [:]
    private var notificationCountByCharacteristic: [String: Int] = [:]
    private var isStopping = false

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func centralManagerDidUpdateState(_ bleCentral: CBCentralManager) {
        guard bleCentral.state == .poweredOn, peripheral == nil else { return }
        let candidates = bleCentral.retrieveConnectedPeripherals(withServices: [VENDOR_SERVICE])
        guard let target = candidates.first(where: { ($0.name ?? "").contains(TARGET_NAME) }) else {
            print("找不到已連線的 \(TARGET_NAME)"); exit(1)
        }
        peripheral = target
        target.delegate = self
        bleCentral.connect(target, options: nil)
    }

    func centralManager(_ bleCentral: CBCentralManager, didConnect connected: CBPeripheral) {
        connected.discoverServices([VENDOR_SERVICE])
    }

    func peripheral(_ device: CBPeripheral, didDiscoverServices error: Error?) {
        for service in device.services ?? [] { device.discoverCharacteristics(nil, for: service) }
    }

    func peripheral(_ device: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let notifiable = (service.characteristics ?? []).filter { $0.properties.contains(.notify) }
        for characteristic in notifiable { device.setNotifyValue(true, for: characteristic) }
    }

    func peripheral(_ device: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        let suffix = String(characteristic.uuid.uuidString.suffix(4))
        if let error { print("\(timestamp()) \(suffix) 訂閱狀態變更失敗：\(error.localizedDescription)"); return }
        print("\(timestamp()) \(suffix) 通知\(characteristic.isNotifying ? "已開啟" : "已關閉")")
        if characteristic.isNotifying { subscribed.append(characteristic) } else { subscribed.removeAll { $0 == characteristic } }
        if isStopping && subscribed.isEmpty { finish() }
    }

    func peripheral(_ device: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let value = characteristic.value else { return }
        let suffix = String(characteristic.uuid.uuidString.suffix(4))
        byteCountByCharacteristic[suffix, default: 0] += value.count
        notificationCountByCharacteristic[suffix, default: 0] += 1
        let shown = value.prefix(MAX_PRINTED_BYTES).map { String(format: "%02X", $0) }.joined()
        print("\(timestamp()) \(suffix) [\(value.count) B] \(shown)\(value.count > MAX_PRINTED_BYTES ? "…" : "")")
    }

    /// 先關掉所有訂閱，讓 CCCD 回到原本的 0，再結束；裝置沒回應時寬限後強制結束。
    func stop() {
        guard !isStopping else { return }
        isStopping = true
        guard let device = peripheral, !subscribed.isEmpty else { finish(); return }
        for characteristic in subscribed { device.setNotifyValue(false, for: characteristic) }
        DispatchQueue.main.asyncAfter(deadline: .now() + UNSUBSCRIBE_GRACE_SECONDS) { self.finish() }
    }

    private func finish() {
        print("統計（特徵值：通知次數／位元組）：" + notificationCountByCharacteristic.keys.sorted().map {
            "\($0)：\(notificationCountByCharacteristic[$0]!)／\(byteCountByCharacteristic[$0]!)"
        }.joined(separator: "，"))
        print(subscribed.isEmpty ? "已取消全部訂閱" : "警告：仍有 \(subscribed.count) 個訂閱未確認關閉")
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        exit(0)
    }
}

let listener = VendorNotifyListener()
let signalSources = [SIGINT, SIGTERM].map { signalNumber -> DispatchSourceSignal in
    signal(signalNumber, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
    source.setEventHandler { listener.stop() }
    source.resume()
    return source
}
print("\(timestamp()) 開始監聽 \(Int(LISTEN_SECONDS)) 秒")
DispatchQueue.main.asyncAfter(deadline: .now() + LISTEN_SECONDS) { listener.stop() }
RunLoop.main.run()
