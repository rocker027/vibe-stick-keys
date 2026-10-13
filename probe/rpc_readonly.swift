// 唯讀 ZMK Studio RPC 探測工具（BLE）。
// 用法：rpc_readonly <hex 請求 payload>...；每個請求輸出一行 "<< hex" 回應。
// isReadOnly() 只放行不改狀態的請求（不送 set/save/discard/reset）。
// 不會寫入賣家自訂服務 1ACCAC91-...。
import CoreBluetooth
import Foundation

setbuf(stdout, nil) // 不緩衝：程式崩潰時仍保留已輸出的進度

let TARGET_NAME = "YuVibeStick"
let STUDIO_SERVICE = CBUUID(string: "00000000-0196-6107-C967-C5CFB1C2482A")
let RPC_CHRC = CBUUID(string: "00000001-0196-6107-C967-C5CFB1C2482A")
let TIMEOUT_SECONDS = 40.0

// 框架與 ZMK app/src/studio/msg_framing.h 相同；BLE 寫入直接進同一個 RPC ring buffer。
let SOF: UInt8 = 0xAB, ESC: UInt8 = 0xAC, EOF: UInt8 = 0xAD

func frame(_ payload: [UInt8]) -> Data {
    var out: [UInt8] = [SOF]
    for b in payload {
        if b == SOF || b == ESC || b == EOF { out.append(ESC) }
        out.append(b)
    }
    out.append(EOF)
    return Data(out)
}

func readVarint(_ b: [UInt8], _ i: inout Int) -> UInt64 {
    var r: UInt64 = 0, s: UInt64 = 0
    while i < b.count { let byte = b[i]; i += 1; r |= UInt64(byte & 0x7F) << s; if byte & 0x80 == 0 { break }; s += 7 }
    return r
}

/// 解析 hex 字串；長度為奇數或含非 hex 字元時回傳 nil。
func parseHex(_ hex: String) -> [UInt8]? {
    let chars = Array(hex)
    guard chars.count % 2 == 0 else { return nil }
    var bytes: [UInt8] = []
    for i in stride(from: 0, to: chars.count, by: 2) {
        guard let byte = UInt8(String(chars[i...i + 1]), radix: 16) else { return nil }
        bytes.append(byte)
    }
    return bytes
}

/// 白名單：core{get_device_info|get_lock_state}、behaviors{全部}、keymap{get_keymap|check_unsaved_changes|get_physical_layouts}。
/// 欄位編號依 zmk-studio-messages 的 studio.proto / core.proto / behaviors.proto / keymap.proto。
func isReadOnly(_ b: [UInt8]) -> Bool {
    var i = 0
    _ = readVarint(b, &i) // request_id 的 key
    _ = readVarint(b, &i) // request_id
    let subsystem = readVarint(b, &i) >> 3
    _ = readVarint(b, &i) // 子訊息長度
    let requestType = readVarint(b, &i) >> 3
    switch subsystem {
    case 3: return requestType == 1 || requestType == 2
    case 4: return requestType == 1 || requestType == 2
    case 5: return requestType == 1 || requestType == 3 || requestType == 6
    default: return false
    }
}

let requests: [(String, [UInt8])] = CommandLine.arguments.dropFirst().map { hex in
    guard let payload = parseHex(hex), isReadOnly(payload) else {
        print("refusing non-read-only or invalid payload \(hex)"); exit(4)
    }
    return (hex, payload)
}

final class StudioRpcProbe: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var central: CBCentralManager!
    var peripheral: CBPeripheral?
    var rpcCharacteristic: CBCharacteristic?
    var frameBuffer: [UInt8] = []
    var isInFrame = false, isEscaped = false
    var nextRequestIndex = 0

    override init() { super.init(); central = CBCentralManager(delegate: self, queue: nil) }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        guard c.state == .poweredOn else { return }
        // 系統已連上的 HID 裝置不會廣播，必須用 retrieveConnectedPeripherals 取得。
        let list = c.retrieveConnectedPeripherals(withServices: [STUDIO_SERVICE])
        guard let p = list.first(where: { ($0.name ?? "").contains(TARGET_NAME) }) else { print("not found"); exit(1) }
        peripheral = p; p.delegate = self; c.connect(p, options: nil)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) { p.discoverServices([STUDIO_SERVICE]) }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        print("connect failed:", error?.localizedDescription ?? "?"); exit(1)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let s = p.services?.first(where: { $0.uuid == STUDIO_SERVICE }) else { print("no studio svc"); exit(1) }
        p.discoverCharacteristics([RPC_CHRC], for: s)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        guard let ch = s.characteristics?.first(where: { $0.uuid == RPC_CHRC }) else { print("no rpc chrc"); exit(1) }
        rpcCharacteristic = ch
        p.setNotifyValue(true, for: ch) // 韌體在 indication 開啟前會丟掉所有寫入（handling_rx）
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor ch: CBCharacteristic, error: Error?) {
        if let error { print("subscribe error:", error.localizedDescription); exit(1) }
        print("indications enabled:", ch.isNotifying)
        sendNextRequest()
    }

    func sendNextRequest() {
        guard nextRequestIndex < requests.count, let p = peripheral, let ch = rpcCharacteristic else {
            if let p = peripheral { central.cancelPeripheralConnection(p) }
            print("done"); exit(0)
        }
        let (name, payload) = requests[nextRequestIndex]
        print(">> \(name)")
        p.writeValue(frame(payload), for: ch, type: .withResponse)
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor ch: CBCharacteristic, error: Error?) {
        if let error { print("write error:", error.localizedDescription); exit(1) }
    }

    // 一個回應可能分成多個 indication，累積到 EOF 才算完整。
    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard let chunk = ch.value else { return }
        for b in chunk {
            if !isInFrame { if b == SOF { isInFrame = true; frameBuffer = [] }; continue }
            if isEscaped { frameBuffer.append(b); isEscaped = false; continue }
            if b == ESC { isEscaped = true; continue }
            if b == EOF {
                isInFrame = false
                print("<< \(frameBuffer.map { String(format: "%02X", $0) }.joined())")
                nextRequestIndex += 1
                sendNextRequest()
                continue
            }
            frameBuffer.append(b)
        }
    }
}

let probe = StudioRpcProbe()
DispatchQueue.main.asyncAfter(deadline: .now() + TIMEOUT_SECONDS) { print("timeout"); exit(3) }
RunLoop.main.run()
