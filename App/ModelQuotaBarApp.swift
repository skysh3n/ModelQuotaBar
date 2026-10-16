import AppKit
import SwiftUI

/// 处理后台模式与「关窗口不退出」。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        guard AppEnvironment.isBackgroundMode else { return }
        // 必须在窗口创建之前设成 accessory，否则后台进程启动时会先亮一下 Dock 图标。
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard AppEnvironment.isBackgroundMode else { return }
        // 无窗口后台模式：把自动开出的窗口立即关掉（此时 Dock 图标已不显示）。
        NSApp.windows.forEach { $0.close() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // 关掉窗口不退出进程，后台继续刷新，桌面小组件保持实时。
        false
    }
}

@main
struct ModelQuotaBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var environment = AppEnvironment()

    var body: some Scene {
        WindowGroup("大模型额度") {
            DashboardView()
                .environment(environment)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 520, height: 620)
        .commands {
            // 没有「新建窗口」之类的需求。
            CommandGroup(replacing: .newItem) {}
        }
    }
}