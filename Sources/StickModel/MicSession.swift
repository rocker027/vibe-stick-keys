/// 賣家自訂服務 1ACCAC91-… 的通知。格式由 2026-10-13 實測推得（docs/button-map.md），非官方文件。
public enum VendorEvent: Equatable {
    case micStarted
    case micStopped
    /// 收音期間每 20 ms 一筆的聲音資料（推測為 8 kHz、4-bit ADPCM，尚未解碼驗證）。
    case audioPacket([UInt8])
    case other(characteristic: String, bytes: [UInt8])
}

public enum VendorEventParser {
    public static let AUDIO_CHARACTERISTIC = "1ACCAC91-73C2-41CA-AF88-7C02247CA902"
    public static let MIC_STATE_CHARACTERISTIC = "1ACCAC91-73C2-41CA-AF88-7C02247CA903"
    static let MIC_ON: UInt8 = 0x01
    static let MIC_OFF: UInt8 = 0x00

    /// characteristic 為 CBUUID 的 uuidString（大寫）。
    public static func parse(characteristic: String, bytes: [UInt8]) -> VendorEvent {
        switch characteristic.uppercased() {
        case MIC_STATE_CHARACTERISTIC where bytes == [MIC_ON]: return .micStarted
        case MIC_STATE_CHARACTERISTIC where bytes == [MIC_OFF]: return .micStopped
        case AUDIO_CHARACTERISTIC: return .audioPacket(bytes)
        default: return .other(characteristic: characteristic, bytes: bytes)
        }
    }
}

/// 一次收音的統計。
public struct MicSummary: Equatable {
    /// 秒。
    public let duration: Double
    public let packetCount: Int
    public let byteCount: Int
}

public enum MicChange: Equatable {
    case started
    case stopped(MicSummary)
}

/// 追蹤 MIC 收音狀態與資料量。收音結束後才到的零星封包不計入（實測放開後會再來一筆）。
/// 時間以秒（Double）傳入，例如 Date().timeIntervalSince1970，方便測試。
public struct MicSession: Equatable {
    public private(set) var startedAt: Double?
    public private(set) var packetCount = 0
    public private(set) var byteCount = 0
    public private(set) var lastSummary: MicSummary?

    public init() {}

    public var isRecording: Bool { startedAt != nil }

    public mutating func handle(_ event: VendorEvent, at time: Double) -> MicChange? {
        switch event {
        case .micStarted:
            guard !isRecording else { return nil }
            startedAt = time
            packetCount = 0
            byteCount = 0
            return .started
        case .micStopped:
            guard let startedAt else { return nil }
            let summary = MicSummary(duration: time - startedAt, packetCount: packetCount, byteCount: byteCount)
            self.startedAt = nil
            lastSummary = summary
            return .stopped(summary)
        case .audioPacket(let bytes):
            guard isRecording else { return nil }
            packetCount += 1
            byteCount += bytes.count
            return nil
        case .other:
            return nil
        }
    }

    /// 斷線時呼叫：收音結束通知可能遺失，直接回到待命。
    public mutating func reset() {
        startedAt = nil
        packetCount = 0
        byteCount = 0
    }
}
