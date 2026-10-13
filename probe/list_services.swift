// 唯讀 GATT 探測：列出已連線 BLE HID 裝置的服務與特徵值。
// 不寫入任何特徵值。
import CoreBluetooth
import Foundation

let target = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "YuVibeStick"
let studioService = CBUUID(string: "00000000-0196-6107-C967-C5CFB1C2482A")

final class Probe: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var central: CBCentralManager!
    var peripheral: CBPeripheral?
    var pendingServices = 0

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        print("central state:", c.state.rawValue, "(5 = poweredOn)")
        guard c.state == .poweredOn else {
            if c.state == .unauthorized { print("Bluetooth permission denied for this terminal app") ; exit(2) }
            return
        }
        // macOS 已連上的 HID（0x1812）裝置不會廣播，必須直接取得。
        let connected = c.retrieveConnectedPeripherals(withServices: [CBUUID(string: "1812"), CBUUID(string: "180F"), studioService])
        for p in connected { print("connected peripheral:", p.name ?? "?", p.identifier) }
        guard let p = connected.first(where: { ($0.name ?? "").contains(target) }) else {
            print("target not found among system-connected peripherals"); exit(1)
        }
        peripheral = p
        p.delegate = self
        c.connect(p, options: nil)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        print("app-level connect OK:", p.name ?? "?")
        p.discoverServices(nil)
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        print("connect failed:", error?.localizedDescription ?? "?"); exit(1)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { print("discover services error:", error); exit(1) }
        let services = p.services ?? []
        pendingServices = services.count
        for s in services {
            let tag = s.uuid == studioService ? "   <== ZMK Studio RPC service" : ""
            print("service:", s.uuid.uuidString, s.uuid, tag)
            p.discoverCharacteristics(nil, for: s)
        }
        if services.isEmpty { exit(0) }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for ch in s.characteristics ?? [] {
            print("  [\(s.uuid)] chrc:", ch.uuid.uuidString, "props:", ch.properties.rawValue)
        }
        pendingServices -= 1
        if pendingServices == 0 {
            let hasStudio = (p.services ?? []).contains { $0.uuid == studioService }
            print("ZMK Studio service present:", hasStudio)
            central.cancelPeripheralConnection(p)
            exit(0)
        }
    }
}

let probe = Probe()
DispatchQueue.main.asyncAfter(deadline: .now() + 20) { print("timeout"); exit(3) }
RunLoop.main.run()
