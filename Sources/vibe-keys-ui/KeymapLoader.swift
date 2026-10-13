import StickModel
import StudioBle
import StudioProtocol

enum KeymapLoadError: Error, CustomStringConvertible {
    case rejected(String)
    case unexpected(String)

    var description: String {
        switch self {
        case .rejected(let summary): return "鍵盤拒絕讀取（\(summary)）"
        case .unexpected(let summary): return "收到非預期的回應：\(summary)"
        }
    }
}

/// 只送唯讀請求：get_keymap，以及 keymap 用到的每個 behavior 的 get_behavior_details。
enum KeymapLoader {
    static func load() async throws -> StickKeymap {
        let client = StudioBleClient()
        try await client.connect()
        defer { client.disconnect() }
        let keymap = try await readKeymap(client)
        let behaviorIds = Set(keymap.layers.flatMap { $0.bindings.map(\.behaviorId) }).filter { $0 > 0 }.sorted()
        var behaviorNames: [Int32: String] = [:]
        for behaviorId in behaviorIds {
            behaviorNames[behaviorId] = try await readBehaviorName(client, behaviorId: behaviorId)
        }
        return StickKeymap(keymap: keymap, behaviorNames: behaviorNames)
    }

    private static func readKeymap(_ client: StudioBleClient) async throws -> Keymap {
        switch try await client.send(.getKeymap) {
        case .keymap(let keymap): return keymap
        case let other: throw rejection(other)
        }
    }

    private static func readBehaviorName(_ client: StudioBleClient, behaviorId: Int32) async throws -> String {
        guard let id = UInt16(exactly: behaviorId) else { return "behavior #\(behaviorId)" }
        switch try await client.send(.getBehaviorDetails(behaviorId: id)) {
        case .behaviorDetails(_, let name): return name
        case let other: throw rejection(other)
        }
    }

    private static func rejection(_ outcome: StudioOutcome) -> KeymapLoadError {
        if case .metaError = outcome { return .rejected(outcome.summary) }
        return .unexpected(outcome.summary)
    }
}
