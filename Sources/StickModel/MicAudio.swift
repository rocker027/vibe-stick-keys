/// 收音的原始聲音資料緩衝。只在記憶體保留目前與上一次的收音，不會自動寫入磁碟。
/// 實測放開 MIC 後還會再來一筆封包，所以結束後短時間內到的封包仍併入上一次收音。
/// 保留封包邊界，因為裝置在每個封包開頭都重設編碼狀態，解碼時必須逐封包處理。
public struct MicAudioBuffer {
    /// 4-bit ADPCM 約每秒 4,000 B；上限約 2 分鐘，避免忘記放開時無限增長。
    public static let MAX_BYTES = 480_000
    static let STRAGGLER_WINDOW_SECONDS = 0.2

    public private(set) var lastPackets: [[UInt8]] = []
    public private(set) var isLastTruncated = false
    private var currentPackets: [[UInt8]] = []
    private var currentByteCount = 0
    private var lastByteCount = 0
    private var isRecording = false
    private var stoppedAt: Double?

    public init() {}

    /// time 為秒（Double），與 MicSession 相同。
    public mutating func handle(_ event: VendorEvent, at time: Double) {
        switch event {
        case .micStarted:
            isRecording = true
            currentPackets = []
            currentByteCount = 0
            stoppedAt = nil
        case .micStopped:
            guard isRecording else { return }
            isRecording = false
            stoppedAt = time
            lastPackets = currentPackets
            lastByteCount = currentByteCount
            isLastTruncated = currentByteCount >= Self.MAX_BYTES
        case .audioPacket(let bytes):
            append(bytes, at: time)
        case .other:
            break
        }
    }

    /// 上一次收音的原始位元組（各封包依序相接），用於存成 .adpcm。
    public var lastRecording: [UInt8] { lastPackets.flatMap { $0 } }

    private mutating func append(_ bytes: [UInt8], at time: Double) {
        if isRecording {
            guard currentByteCount + bytes.count <= Self.MAX_BYTES else { currentByteCount = Self.MAX_BYTES; return }
            currentPackets.append(bytes)
            currentByteCount += bytes.count
        } else if let stoppedAt, time - stoppedAt <= Self.STRAGGLER_WINDOW_SECONDS,
                  lastByteCount + bytes.count <= Self.MAX_BYTES {
            lastPackets.append(bytes)
            lastByteCount += bytes.count
        }
    }

    public mutating func reset() {
        currentPackets = []
        currentByteCount = 0
        isRecording = false
        stoppedAt = nil
    }
}

/// 標準 IMA ADPCM（4-bit）解碼。初始 predictor 與 step index 皆為 0。
/// YuVibeStick 的聲音格式尚未解開（docs/button-map.md「聲音格式」）：以 IMA ADPCM 解碼只是實驗性猜測，
/// 受控測試未能還原已知音調。預設先低 4 位並逐封包重設狀態。
public enum ImaAdpcmDecoder {
    public enum NibbleOrder: Equatable {
        /// 每個位元組先解低 4 位，再解高 4 位（WAV IMA ADPCM 的慣例）。
        case lowFirst
        case highFirst
    }

    static let STEP_TABLE: [Int32] = [
        7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88, 97,
        107, 118, 130, 143, 157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658, 724, 796,
        876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871,
        5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623,
        27086, 29794, 32767,
    ]
    static let INDEX_TABLE: [Int] = [-1, -1, -1, -1, 2, 4, 6, 8]

    /// 每個封包都從初始狀態解碼後相接。
    public static func decode(packets: [[UInt8]], order: NibbleOrder = .lowFirst) -> [Int16] {
        packets.flatMap { decode($0, order: order) }
    }

    /// 從初始狀態連續解碼一段位元組。
    public static func decode(_ bytes: [UInt8], order: NibbleOrder) -> [Int16] {
        var predictor: Int32 = 0
        var index = 0
        var samples: [Int16] = []
        samples.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            let nibbles = order == .lowFirst ? [byte & 0x0F, byte >> 4] : [byte >> 4, byte & 0x0F]
            for nibble in nibbles {
                predictor = nextPredictor(predictor, nibble: nibble, step: STEP_TABLE[index])
                index = min(max(index + INDEX_TABLE[Int(nibble & 0x07)], 0), STEP_TABLE.count - 1)
                samples.append(Int16(predictor))
            }
        }
        return samples
    }

    private static func nextPredictor(_ predictor: Int32, nibble: UInt8, step: Int32) -> Int32 {
        var difference = step >> 3
        if nibble & 0x04 != 0 { difference += step }
        if nibble & 0x02 != 0 { difference += step >> 1 }
        if nibble & 0x01 != 0 { difference += step >> 2 }
        let next = nibble & 0x08 != 0 ? predictor - difference : predictor + difference
        return min(max(next, Int32(Int16.min)), Int32(Int16.max))
    }
}

/// 把取樣等比例放大到峰值為滿刻度的 TARGET_PEAK_RATIO；裝置錄音約 −30 dBFS，不放大很難聽清楚。
public enum PeakNormalizer {
    public static let TARGET_PEAK_RATIO = 0.9

    public static func normalize(_ samples: [Int16]) -> [Int16] {
        let peak = samples.map { abs(Int32($0)) }.max() ?? 0
        guard peak > 0 else { return samples }
        let gain = TARGET_PEAK_RATIO * Double(Int16.max) / Double(peak)
        return samples.map { Int16(clamping: Int((Double($0) * gain).rounded())) }
    }
}

/// 產生 16-bit PCM 單聲道 WAV 檔的位元組。
public enum WavEncoder {
    public static func encode(samples: [Int16], sampleRate: UInt32) -> [UInt8] {
        let dataSize = UInt32(samples.count * 2)
        var bytes: [UInt8] = Array("RIFF".utf8) + littleEndian(36 + dataSize) + Array("WAVEfmt ".utf8)
        bytes += littleEndian(UInt32(16)) + littleEndian(UInt16(1)) + littleEndian(UInt16(1)) // PCM、單聲道
        bytes += littleEndian(sampleRate) + littleEndian(sampleRate * 2) + littleEndian(UInt16(2)) + littleEndian(UInt16(16))
        bytes += Array("data".utf8) + littleEndian(dataSize)
        for sample in samples { bytes += littleEndian(UInt16(bitPattern: sample)) }
        return bytes
    }

    private static func littleEndian<Value: FixedWidthInteger>(_ value: Value) -> [UInt8] {
        (0..<(Value.bitWidth / 8)).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
    }
}
