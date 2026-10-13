/// 最小 protobuf 線路格式工具：只支援 Studio RPC 用到的 varint（wire type 0）與 length-delimited（wire type 2）。
enum ProtoWire {
    static let MAX_VARINT_BYTES = 10

    static func varint(_ value: UInt64) -> [UInt8] {
        var remaining = value
        var bytes: [UInt8] = []
        while remaining >= 0x80 {
            bytes.append(UInt8(remaining & 0x7F) | 0x80)
            remaining >>= 7
        }
        return bytes + [UInt8(remaining)]
    }

    /// sint32 欄位（例如 behavior_id）使用 zigzag 編碼。
    static func zigzag(_ value: Int32) -> UInt64 {
        UInt64(UInt32(bitPattern: (value << 1) ^ (value >> 31)))
    }

    static func varintField(_ number: Int, _ value: UInt64) -> [UInt8] {
        varint(UInt64(number << 3)) + varint(value)
    }

    /// proto3 純量欄位為 0 時省略，與官方 protobuf 編碼器一致。
    static func optionalVarintField(_ number: Int, _ value: UInt64) -> [UInt8] {
        value == 0 ? [] : varintField(number, value)
    }

    static func messageField(_ number: Int, _ body: [UInt8]) -> [UInt8] {
        varint(UInt64(number << 3 | 2)) + varint(UInt64(body.count)) + body
    }
}

public enum ProtoDecodeError: Error, Equatable {
    case truncated
    case unsupportedWireType(Int)
}

/// 解出的單一 protobuf 欄位。
struct ProtoField: Equatable {
    enum Value: Equatable {
        case varint(UInt64)
        case bytes([UInt8])
    }

    let number: Int
    let value: Value
}

extension ProtoWire {
    static func parseFields(_ bytes: [UInt8]) throws -> [ProtoField] {
        var index = 0
        var fields: [ProtoField] = []
        while index < bytes.count {
            let key = try readVarint(bytes, &index)
            let number = Int(key >> 3)
            switch Int(key & 7) {
            case 0:
                fields.append(ProtoField(number: number, value: .varint(try readVarint(bytes, &index))))
            case 2:
                // 長度來自裝置，不可信：用 exactly 避免超大值轉 Int 時 trap
                guard let length = Int(exactly: try readVarint(bytes, &index)), length <= bytes.count - index else {
                    throw ProtoDecodeError.truncated
                }
                fields.append(ProtoField(number: number, value: .bytes(Array(bytes[index..<index + length]))))
                index += length
            case 1, 5:
                // fixed64／fixed32：目前協定沒用到，略過以相容未來韌體新增的欄位
                let width = key & 7 == 1 ? 8 : 4
                guard width <= bytes.count - index else { throw ProtoDecodeError.truncated }
                index += width
            case let wireType:
                throw ProtoDecodeError.unsupportedWireType(wireType)
            }
        }
        return fields
    }

    static func readVarint(_ bytes: [UInt8], _ index: inout Int) throws -> UInt64 {
        var value: UInt64 = 0
        for shift in 0..<MAX_VARINT_BYTES {
            guard index < bytes.count else { throw ProtoDecodeError.truncated }
            let byte = bytes[index]
            index += 1
            value |= UInt64(byte & 0x7F) << UInt64(shift * 7)
            if byte & 0x80 == 0 { return value }
        }
        throw ProtoDecodeError.truncated
    }
}

extension Array where Element == ProtoField {
    func varint(_ number: Int) -> UInt64? {
        for field in self where field.number == number {
            if case .varint(let value) = field.value { return value }
        }
        return nil
    }

    func message(_ number: Int) throws -> [ProtoField]? {
        for field in self where field.number == number {
            if case .bytes(let body) = field.value { return try ProtoWire.parseFields(body) }
        }
        return nil
    }
}
