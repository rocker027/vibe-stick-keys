// 唯讀探測：列出 YuVibeStick 賣家自訂服務 1ACCAC91-… 與 Device Information 的特徵值、描述，
// 並讀出可讀的值。不寫入任何特徵值或描述，也不訂閱通知（不寫 CCCD）。
import CoreBluetooth
import Foundation

setbuf(stdout, nil)

let TARGET_NAME = "YuVibeStick"
let VENDOR_SERVICE = CBUUID(string: "1ACCAC91-73C2-41CA-AF88-7C02247CA900")
let DEVICE_INFO_SERVICE = CBUUID(string: "180A")
let TIMEOUT_SECONDS = 20.0

func describeProperties(_ properties: CBCharacteristicProperties) -> String {
    let names: [(CBCharacteristicProperties, String)] = [
        (.read, "read"), (.write, "write"), (.writeWithoutResponse, "writeNoResp"),
        (.notify, "notify"), (.indicate, "indicate"),
    ]
    return names.filter { properties.contains($0.0) }.map(\.1).joined(separator: "|")
}

func describeValue(_ value: Data?) -> String {
    guard let value else { return "（無值）" }
    let hex = value.map { String(format: "%02X", $0) }.joined()
    let text = String(decoding: value, as: UTF8.self)
    let isPrintable = !value.isEmpty && value.allSatisfy { (0x20..<0x7F).contains($0) }
    return isPrintable ? "\(hex) \"\(text)\"" : hex
}

final class VendorServiceProbe: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var pendingReads = 0

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func centralManagerDidUpdateState(_ bleCentral: CBCentralManager) {
        guard bleCentral.state == .poweredOn else { return }
        let candidates = bleCentral.retrieveConnectedPeripherals(withServices: [VENDOR_SERVICE, DEVICE_INFO_SERVICE])
        guard let target = candidates.first(where: { ($0.name ?? "").contains(TARGET_NAME) }) else {
            print("找不到已連線的 \(TARGET_NAME)"); exit(1)
        }
        peripheral = target
        target.delegate = self
        bleCentral.connect(target, options: nil)
    }

    func centralManager(_ bleCentral: CBCentralManager, didConnect connected: CBPeripheral) {
        connected.discoverServices([VENDOR_SERVICE, DEVICE_INFO_SERVICE])
    }

    func peripheral(_ device: CBPeripheral, didDiscoverServices error: Error?) {
        for service in device.services ?? [] { track { device.discoverCharacteristics(nil, for: service) } }
    }

    func peripheral(_ device: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for characteristic in service.characteristics ?? [] {
            if characteristic.properties.contains(.read) { track { device.readValue(for: characteristic) } }
            track { device.discoverDescriptors(for: characteristic) }
        }
        finishOne()
    }

    func peripheral(_ device: CBPeripheral, didDiscoverDescriptorsFor characteristic: CBCharacteristic, error: Error?) {
        for descriptor in characteristic.descriptors ?? [] { track { device.readValue(for: descriptor) } }
        finishOne()
    }

    func peripheral(_ device: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let outcome = error.map { "讀取失敗：\($0.localizedDescription)" } ?? describeValue(characteristic.value)
        print("[\(characteristic.service?.uuid.uuidString ?? "?")] chrc \(characteristic.uuid.uuidString) "
              + "(\(describeProperties(characteristic.properties))) = \(outcome)")
        finishOne()
    }

    func peripheral(_ device: CBPeripheral, didUpdateValueFor descriptor: CBDescriptor, error: Error?) {
        let value = error.map { "讀取失敗：\($0.localizedDescription)" } ?? String(describing: descriptor.value ?? "（無值）")
        print("    desc \(descriptor.uuid.uuidString) of \(descriptor.characteristic?.uuid.uuidString ?? "?") = \(value)")
        finishOne()
    }

    private func track(_ operation: () -> Void) {
        pendingReads += 1
        operation()
    }

    private func finishOne() {
        pendingReads -= 1
        guard pendingReads == 0 else { return }
        print("完成")
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        exit(0)
    }
}

let probe = VendorServiceProbe()
DispatchQueue.main.asyncAfter(deadline: .now() + TIMEOUT_SECONDS) { print("逾時"); exit(3) }
RunLoop.main.run()
