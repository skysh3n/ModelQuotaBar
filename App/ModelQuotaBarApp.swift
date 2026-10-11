import SwiftUI

@main
struct ModelQuotaBarApp: App {
    @State private var environment = AppEnvironment()

    var body: some Scene {
        WindowGroup("大模型额度") {
            DashboardView()
                .environment(environment)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 520, height: 620)
        .commands {
            // 这个应用没有「关于」「偏好设置」之类的标准菜单项需求，去掉新建窗口。
            CommandGroup(replacing: .newItem) {}
        }
    }
}