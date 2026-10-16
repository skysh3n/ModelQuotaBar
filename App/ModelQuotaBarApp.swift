import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 已经处理过焦点的窗口。关掉窗口再打开会新建窗口，所以不能只在启动时清一次。
    private var focusHandledWindows = Set<ObjectIdentifier>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 旧版本用 SMAppService 注册过「开机自启」。删代码不会自动注销，
        // 残留项会一直挂在「系统设置 → 通用 → 登录项与扩展」里，这里顺手清掉。
        if SMAppService.mainApp.status == .enabled {
            try? SMAppService.mainApp.unregister()
        }

        // 窗口每次出现（首次打开、关掉再打开）时，macOS 会把焦点给第一个输入框，
        // 于是「控制台会话 Cookie」一进来就是蓝色选中态。把焦点交还给窗口本身。
        //
        // 每个窗口只处理第一次成为 key 的那次：否则用户点回窗口继续输入时，
        // 会被这段逻辑抢走光标。
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let window = note.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                let id = ObjectIdentifier(window)
                guard !self.focusHandledWindows.contains(id) else { return }
                self.focusHandledWindows.insert(id)
                // 等 SwiftUI 建好视图、设好初始焦点之后再抢回来。
                DispatchQueue.main.async { window.makeFirstResponder(nil) }
            }
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