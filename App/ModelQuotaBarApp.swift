import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 旧版本用 SMAppService 注册过「开机自启」。现在小组件自己会刷新，
        // 不再需要它了；但删代码不会自动注销，残留项会一直挂在
        // 「系统设置 → 通用 → 登录项与扩展」里。这里顺手清掉。
        if SMAppService.mainApp.status == .enabled {
            try? SMAppService.mainApp.unregister()
        }

        // 窗口打开时 macOS 默认把焦点给第一个输入框，导致「控制台会话 Cookie」
        // 一进来就是蓝色高亮选中态。等视图建好后把焦点交还给窗口本身。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // 关掉窗口不退出进程：应用继续跑着，切到桌面时小组件能立刻拿到最新数据。
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
            CommandGroup(replacing: .newItem) {}
        }
    }
}