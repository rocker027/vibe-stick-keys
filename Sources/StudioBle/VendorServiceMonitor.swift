@preconcurrency import CoreBluetooth
import Foundation

/// 訂閱 YuVibeStick 賣家自訂服務 1ACCAC91-… 的通知（MIC 收音狀態與聲音資料）。
/// 只寫標準 CCCD 開關通知，從不寫入服務的特徵值；stop() 會先關掉訂閱再斷開。
/// CBCentralManager 用主佇列，所有回呼都在主執行緒。
public final class VendorServiceMonitor: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    public enum Status: Equatable {
        case idle
        case connecting
        case subscribed
        case disconnected
        case failed(String)
    }

    public static let SERVICE = CBUUID(string: "1ACCAC91-73C2-41CA-AF88-7C02247CA900")
    /// …A902 聲音資料、…A903 收音開始／結束。
    public static let SUBSCRIBED_CHARACTERISTICS = [
        CBUUID(string: "1ACCAC91-73C2-41CA-AF88-7C02247CA902"),
        CBUUID(string: "1ACCAC91-73C2-41CA-AF88-7C02247CA903"),
    ]
    static let UNSUBSCRIBE_GRACE_SECONDS = 1.0

    private let targetName: String
    private let onStatus: (Status) -> Void
    private let onNotification: (_ characteristic: String, _ bytes: [UInt8]) -> Void
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var subscribed: Set<CBUUID> = []
    private var stopCompletion: (() -> Void)?

    public init(targetName: String = "YuVibeStick",
                onStatus: @escaping (Status) -> Void,
                onNotification: @escaping (_ characteristic: String, _ bytes: [UInt8]) -> Void) {
        self.targetName = targetName
        self.onStatus = onStatus
        self.onNotification = onNotification
    }

    /// 開始或重新訂閱；已訂閱時不做事。鍵盤重新連上時可再呼叫。
    public func start() {
        guard subscribed.isEmpty, stopCompletion == nil else { return }
        guard let central else {
            central = CBCentralManager(delegate: self, queue: nil)
            return
        }
        connectIfPossible(central)
    }

    /// 關掉所有訂閱（CCCD 回到 0）後斷開；裝置沒回應時寬限後仍會完成。
    public func stop(completion: @escaping () -> Void) {
        guard let device = peripheral, !subscribed.isEmpty else { completion(); return }
        stopCompletion = completion
        for characteristic in device.services?.flatMap({ $0.characteristics ?? [] }) ?? []
        where subscribed.contains(characteristic.uuid) {
            device.setNotifyValue(false, for: characteristic)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.UNSUBSCRIBE_GRACE_SECONDS) { [weak self] in
            self?.finishStop()
        }
    }

    private func connectIfPossible(_ bleCentral: CBCentralManager) {
        guard bleCentral.state == .poweredOn else { return }
        let candidates = bleCentral.retrieveConnectedPeripherals(withServices: [Self.SERVICE])
        guard let target = candidates.first(where: { ($0.name ?? "").contains(targetName) }) else {
            onStatus(.disconnected)
            return
        }
        peripheral = target
        target.delegate = self
        onStatus(.connecting)
        bleCentral.connect(target, options: nil)
    }

    private func finishStop() {
        guard let completion = stopCompletion else { return }
        stopCompletion = nil
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        completion()
    }

    // MARK: - CBCentralManagerDelegate

    public func centralManagerDidUpdateState(_ bleCentral: CBCentralManager) {
        switch bleCentral.state {
        case .poweredOn: connectIfPossible(bleCentral)
        case .unauthorized: onStatus(.failed("沒有藍牙權限"))
        case .poweredOff, .unsupported: onStatus(.failed("藍牙不可用"))
        default: break
        }
    }

    public func centralManager(_ bleCentral: CBCentralManager, didConnect connected: CBPeripheral) {
        connected.discoverServices([Self.SERVICE])
    }

    public func centralManager(_ bleCentral: CBCentralManager, didFailToConnect failed: CBPeripheral, error: Error?) {
        onStatus(.failed("連線失敗：\(error?.localizedDescription ?? "未知原因")"))
    }

    public func centralManager(_ bleCentral: CBCentralManager, didDisconnectPeripheral lost: CBPeripheral, error: Error?) {
        subscribed = []
        onStatus(.disconnected)
        finishStop()
    }

    // MARK: - CBPeripheralDelegate

    public func peripheral(_ device: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = device.services?.first(where: { $0.uuid == Self.SERVICE }) else {
            onStatus(.failed("找不到自訂服務"))
            return
        }
        device.discoverCharacteristics(Self.SUBSCRIBED_CHARACTERISTICS, for: service)
    }

    public func peripheral(_ device: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for characteristic in service.characteristics ?? [] where characteristic.properties.contains(.notify) {
            device.setNotifyValue(true, for: characteristic)
        }
    }

    public func peripheral(_ device: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            onStatus(.failed("訂閱失敗：\(error.localizedDescription)"))
            return
        }
        if characteristic.isNotifying { subscribed.insert(characteristic.uuid) } else { subscribed.remove(characteristic.uuid) }
        if stopCompletion != nil, subscribed.isEmpty { finishStop(); return }
        if subscribed.count == Self.SUBSCRIBED_CHARACTERISTICS.count { onStatus(.subscribed) }
    }

    public func peripheral(_ device: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let value = characteristic.value else { return }
        onNotification(characteristic.uuid.uuidString, [UInt8](value))
    }
}
