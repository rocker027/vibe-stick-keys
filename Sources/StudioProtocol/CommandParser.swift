/// 解析後的一次執行：依序要送的請求，以及是否只印出位元組不連線。
public struct Invocation: Equatable {
    public let requests: [StudioRequest]
    public let isDryRun: Bool

    /// 依序加上 request_id（從 1 開始）並包好框架；dry-run 與實際傳送共用，確保印出的就是會送出的。
    public func framedRequests() -> [[UInt8]] {
        requests.enumerated().map { index, request in
            Framing.encode(request.encode(requestId: UInt32(index + 1)))
        }
    }
}

public enum CommandError: Error, Equatable {
    case usage
    case invalidNumber(String)
    case positionOutOfRange(UInt8)
    case frameTooLong(Int)
}

/// 把命令列參數轉成請求序列，並在送出前擋下不合法的輸入。
public enum CommandParser {
    /// YuVibeStick 的實體配置只有 6 個鍵（位置 0–5）；韌體的位置 6 沒有對應實體按鍵。
    public static let MAX_KEY_POSITION: UInt8 = 5
    static let DRY_RUN_FLAG = "--dry-run"

    public static let USAGE = """
        用法：
          vibe-keys set <layer> <position> <behavior> <param1> [param2] [--dry-run]
          vibe-keys save [--dry-run]
        數字可用十進位或 0x 十六進位，不可帶正負號。position 範圍 0–\(MAX_KEY_POSITION)。
        """

    public static func parse(_ arguments: [String]) throws -> Invocation {
        let isDryRun = arguments.contains(DRY_RUN_FLAG)
        let words = arguments.filter { $0 != DRY_RUN_FLAG }
        let invocation = Invocation(requests: try parseRequests(words), isDryRun: isDryRun)
        if let longest = invocation.framedRequests().map(\.count).max(), longest > Framing.MAX_FIRMWARE_FRAME_BYTES {
            throw CommandError.frameTooLong(longest)
        }
        return invocation
    }

    private static func parseRequests(_ words: [String]) throws -> [StudioRequest] {
        switch words.first {
        case "set":
            return [.setLayerBinding(try parseChange(Array(words.dropFirst())))]
        case "save" where words.count == 1:
            return [.checkUnsavedChanges, .saveChanges, .checkUnsavedChanges]
        default:
            throw CommandError.usage
        }
    }

    private static func parseChange(_ values: [String]) throws -> LayerBindingChange {
        guard values.count == 4 || values.count == 5 else { throw CommandError.usage }
        let position: UInt8 = try parseNumber(values[1])
        guard position <= MAX_KEY_POSITION else { throw CommandError.positionOutOfRange(position) }
        return LayerBindingChange(
            layerId: try parseNumber(values[0]),
            keyPosition: position,
            behaviorId: try parseNumber(values[2]),
            param1: try parseNumber(values[3]),
            param2: values.count == 5 ? try parseNumber(values[4]) : 0
        )
    }

    /// 接受十進位或 0x 十六進位的非負整數；拒絕正負號，超出目標型別範圍時拒絕而不是截斷。
    static func parseNumber<Number: FixedWidthInteger & UnsignedInteger>(_ text: String) throws -> Number {
        let isHex = text.lowercased().hasPrefix("0x")
        let digits = isHex ? String(text.dropFirst(2)) : text
        let isDigitOnly = !digits.isEmpty && digits.allSatisfy { isHex ? $0.isHexDigit : ("0"..."9").contains($0) }
        guard isDigitOnly, let value = Number(digits, radix: isHex ? 16 : 10) else {
            throw CommandError.invalidNumber(text)
        }
        return value
    }
}
