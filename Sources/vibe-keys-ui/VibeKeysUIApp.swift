import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 從終端機啟動的裸執行檔預設不會出現在 Dock，也拿不到鍵盤焦點
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
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
                .onAppear { viewModel.start() }
        }
        .windowResizability(.contentSize)
    }
}
