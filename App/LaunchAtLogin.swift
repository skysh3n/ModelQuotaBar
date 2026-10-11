import Foundation
import ServiceManagement

/// 开机自启。
///
/// 小组件自己不抓数据，只读主应用写进共享容器的快照。主应用不常驻的话，
/// 桌面上的数字会一直停在退出前的状态，所以自启对这个应用算是刚需。
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// 系统可能要求应用位于「应用程序」目录，失败时把原因交给调用方展示。
    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}