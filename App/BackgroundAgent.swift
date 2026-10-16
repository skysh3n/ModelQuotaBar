import Darwin
import Foundation

/// 后台常驻代理。
///
/// 小组件要实时重画，`WidgetCenter.reloadAllTimelines()` 只能由「拥有该小组件扩展的
/// 那个 app」来调——系统没给跨进程的入口。所以想让用户彻底退出主程序（⌘Q）之后
/// 小组件仍然刷新，只能让一个**同一个 bundle 的进程**常驻后台。
///
/// 做法：往 `~/Library/LaunchAgents/` 写一个 launchd 用户代理，用
/// `--background` 参数拉起同一个可执行文件。该模式下应用不开窗口、不进 Dock，
/// 只跑轮询 + 写共享容器 + 通知小组件重画。`RunAtLoad` 让它开机自启，
/// `KeepAlive` 让它意外退出后自动重启。
enum BackgroundAgent {
    static let label = "com.skysh3n.ModelQuotaBar.background"
    static let backgroundFlag = "--background"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try install()
        } else {
            try uninstall()
        }
    }

    private static func install() throws {
        // 指向当前安装位置的绝对路径。若 app 之后被移动，需重新开关一次本开关。
        let executable = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/ModelQuotaBar").path
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable, backgroundFlag],
            "RunAtLoad": true,
            "KeepAlive": true,
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)
        _ = run("launchctl", ["bootstrap", "gui/\(getuid())", plistURL.path])
    }

    private static func uninstall() throws {
        _ = run("launchctl", ["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: plistURL)
    }

    /// 跑一个 launchctl 命令，失败不抛错（bootout 时服务可能本就没在跑）。
    @discardableResult
    private static func run(_ tool: String, _ args: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/\(tool)")
        process.arguments = args
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}