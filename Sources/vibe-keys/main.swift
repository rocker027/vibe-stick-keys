// vibe-keys：透過 BLE 呼叫 ZMK Studio RPC，修改 YuVibeStick 的按鍵並存進鍵盤。
// 只會送出 CommandParser 建構的 set_layer_binding、save_changes、check_unsaved_changes；
// 讀回與解碼請用 probe/rpc_readonly 與 probe/decode_keymap.py。
import Foundation
import StudioBle
import StudioProtocol

setbuf(stdout, nil) // 不緩衝：中途失敗時仍保留已輸出的進度

func hexString(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02X", $0) }.joined()
}

let invocation: Invocation
do {
    invocation = try CommandParser.parse(Array(CommandLine.arguments.dropFirst()))
} catch {
    print("參數錯誤：\(error)\n\(CommandParser.USAGE)")
    exit(2)
}

if invocation.isDryRun {
    for (index, frame) in invocation.framedRequests().enumerated() {
        print(">> #\(index + 1) \(hexString(frame))（\(frame.count) 位元組）")
    }
    exit(0)
}

/// 依序送出請求；任何 meta 錯誤立即停止，其他失敗記下後繼續並以 exit 1 結束。
func run(_ requests: [StudioRequest]) async -> Int32 {
    let client = StudioBleClient()
    client.onTrace = { print($0) }
    var hasFailure = false
    do {
        try await client.connect()
        print("連線就緒")
        for (index, request) in requests.enumerated() {
            let outcome = try await client.send(request)
            print("   \(outcome.summary)")
            if case .metaError = outcome { print("裝置拒絕請求，停止"); return 1 }
            if !outcome.isSuccess { hasFailure = true }
            let isPostSaveCheck = index > 0 && requests[index - 1] == .saveChanges
            if isPostSaveCheck, outcome == .unsavedChanges(true) {
                print("   存檔後仍回報有未儲存變更")
                hasFailure = true
            }
        }
        client.disconnect()
    } catch {
        print("錯誤：\(error)")
        return 1
    }
    print(hasFailure ? "完成，但有失敗" : "完成")
    return hasFailure ? 1 : 0
}

Task {
    exit(await run(invocation.requests))
}
dispatchMain()
