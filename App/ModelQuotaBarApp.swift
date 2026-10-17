import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 旧版本用 SMAppService 注册过「开机自启」。删代码不会自动注销，
        // 残留项会一直挂在「系统设置 → 通用 → 登录项与扩展」里，这里顺手清掉。
        if SMAppService.mainApp.status == .enabled {
            try? SMAppService.mainApp.unregister()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // 关闭主窗口即退出应用。小组件自己是独立取数的，退出后仍会按系统调度刷新。
        true
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
            CommandGroup(replacing: .newItem) {}
        }
    }
}