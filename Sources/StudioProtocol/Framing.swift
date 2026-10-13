import Foundation

/// ZMK Studio RPC 的訊息框架，規則與 zmk `app/src/studio/msg_framing.h` 相同。
/// BLE 寫入會直接進韌體的 RPC ring buffer，所以 BLE 與 UART 共用這套框架。
public enum Framing {
    public static let START_OF_FRAME: UInt8 = 0xAB
    public static let ESCAPE: UInt8 = 0xAC
    public static let END_OF_FRAME: UInt8 = 0xAD
    /// 韌體 ZMK_STUDIO_RPC_RX_BUF_SIZE 預設 30。單次寫入超過時，韌體 BT 執行緒會在 ring buffer 滿時原地等待，
    /// 而負責清空它的 RPC 執行緒優先序最低，可能讓鍵盤卡住（zmk gatt_rpc_transport.c write_rpc_req）。
    public static let MAX_FIRMWARE_FRAME_BYTES = 30

    /// 把 protobuf 位元組包成一則框架；遇到三個特殊位元組時先插入跳脫字元。
    public static func encode(_ payload: [UInt8]) -> [UInt8] {
        let body = payload.flatMap { byte in isSpecial(byte) ? [ESCAPE, byte] : [byte] }
        return [START_OF_FRAME] + body + [END_OF_FRAME]
    }

    /// 以大寫十六進位連續印出，供 CLI 與診斷輸出共用。
    public static func hexString(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined()
    }

    static func isSpecial(_ byte: UInt8) -> Bool {
        byte == START_OF_FRAME || byte == ESCAPE || byte == END_OF_FRAME
    }
}

/// 把 BLE indication 片段組回完整訊息。
/// 一則回應可能跨多個片段，一個片段也可能含多則訊息，所以必須保留跨呼叫的狀態。
public struct FrameDecoder {
    private var pendingBytes: [UInt8] = []
    private var isInFrame = false
    private var isEscaped = false

    public init() {}

    /// 餵入一個片段，回傳這次湊齊的所有完整訊息（不含框架位元組）。
    public mutating func feed(_ chunk: [UInt8]) -> [[UInt8]] {
        var completedMessages: [[UInt8]] = []
        for byte in chunk {
            if let message = consume(byte) { completedMessages.append(message) }
        }
        return completedMessages
    }

    private mutating func consume(_ byte: UInt8) -> [UInt8]? {
        if !isInFrame {
            if byte == Framing.START_OF_FRAME { isInFrame = true; pendingBytes = [] }
            return nil
        }
        if isEscaped { isEscaped = false; pendingBytes.append(byte); return nil }
        switch byte {
        // 框架中出現未跳脫的 SOF 代表前一則不完整（例如漏收 indication），丟棄並重新開始
        case Framing.START_OF_FRAME: pendingBytes = []; return nil
        case Framing.ESCAPE: isEscaped = true; return nil
        case Framing.END_OF_FRAME: isInFrame = false; return pendingBytes
        default: pendingBytes.append(byte); return nil
        }
    }
}
