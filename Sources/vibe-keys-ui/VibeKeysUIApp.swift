import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 結束前的清理（關掉自訂服務的通知訂閱）；完成後呼叫傳入的 closure。
    var onTerminate: ((@escaping () -> Void) -> Void)?
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 從終端機啟動的裸執行檔預設不會出現在 Dock，也拿不到鍵盤焦點
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // 從終端機用 Ctrl-C 或 kill 結束時，也走正常結束流程，讓訂閱有機會關回去。
        // terminate 會開巢狀事件迴圈等待清理；若直接在主佇列的 GCD 區塊裡呼叫，主佇列被佔住，
        // 藍牙回呼與計時都跑不到而卡死，所以延到下一輪 run loop 再呼叫。
        signalSources = [SIGINT, SIGTERM].map { signalNumber in
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0) }
            source.resume()
            return source
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let onTerminate else { return .terminateNow }
        // 清理若同步完成，必須直接回 terminateNow；在回傳 terminateLater 之前呼叫 reply 會被 AppKit 忽略而永遠不結束
        var isInsideCall = true
        var isFinishedSynchronously = false
        onTerminate {
            if isInsideCall { isFinishedSynchronously = true } else { NSApp.reply(toApplicationShouldTerminate: true) }
        }
        isInsideCall = false
        return isFinishedSynchronously ? .terminateNow : .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct VibeKeysUIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var viewModel = StickViewModel()

    var body: some Scene {
        WindowGroup("YuVibeStick 按鍵") {
            ContentView(viewModel: viewModel)
                .onAppear {
                    viewModel.start()
                    appDelegate.onTerminate = { [viewModel] done in
                        MainActor.assumeIsolated { viewModel.shutdown(completion: done) }
                    }
                }
        }
        .windowResizability(.contentSize)
    }
}
