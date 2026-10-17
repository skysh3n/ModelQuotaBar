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
        // 关掉主窗口就退出整个应用。
        // 注意：会话保活只在本应用运行时生效，退出后保活也会停——但小组件的
        // timeline provider 是独立抓数据的，仍会按系统调度继续刷新。
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