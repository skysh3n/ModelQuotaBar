import AppKit
import Observation
import WebKit

/// 会话保活。
///
/// 控制台会话（`login_aliyunid_ticket`）是有有效期的，过期就得重新登录。但它按
/// **活跃度**续期——只要时不时用这个登录态访问一次控制台，服务端就会把会话续上。
///
/// 这里用一个隐藏的 WKWebView 干这件事：它和「登录获取」窗口共用同一个
/// `WKWebsiteDataStore`，所以你在登录窗口里登过一次之后，保活就一直用的是那个登录态，
/// 不需要再输账号密码。每次访问完顺手读一次 Cookie，票变了就更新存起来。
@MainActor
@Observable
final class WebSessionKeeper {
    struct Target: Sendable {
        let providerID: ProviderID
        let spec: WebLoginSpec
    }

    /// 保活间隔。按活跃度续期，几小时碰一次足够；太频繁没必要。
    private static let keepAliveInterval: TimeInterval = 6 * 3600
    /// 单次取票最多等多久（页面加载 + 服务端下发 Cookie）。
    private static let captureTimeout: TimeInterval = 30

    /// 取到（可能已更新的）凭据并已写回存储后的回调，用来刷新界面。
    var onCredentialRefreshed: ((ProviderID) -> Void)?

    private var window: NSWindow?
    private var webView: WKWebView?
    private var keepAliveTask: Task<Void, Never>?
    private var target: Target?

    var isRunning: Bool { target != nil }

    func start(target: Target) {
        stop()
        self.target = target

        let configuration = WKWebViewConfiguration()
        // 与「登录获取」窗口共用同一份数据存储，登录态因此是通的。
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
        self.webView = webView

        // WKWebView 要挂在窗口里才会正常加载/执行，所以给它一个屏幕外的 1×1 窗口。
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 1, height: 1),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.orderBack(nil)
        self.window = window

        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshNow()
                try? await Task.sleep(for: .seconds(Self.keepAliveInterval))
            }
        }
    }

    func stop() {
        keepAliveTask?.cancel()
        keepAliveTask = nil
        window?.orderOut(nil)
        window = nil
        webView = nil
        target = nil
    }

    /// 立刻访问一次控制台并取回凭据。票没变就什么都不做。
    @discardableResult
    func refreshNow() async -> String? {
        guard let webView, let target else { return nil }
        webView.load(URLRequest(url: target.spec.url))

        let deadline = Date().addingTimeInterval(Self.captureTimeout)
        while Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
            guard let cookie = cookies.first(where: { $0.name == target.spec.cookieName }),
                  !cookie.value.isEmpty
            else { continue }

            let stored = CredentialStore.loadCredential(for: target.providerID)
            guard stored[target.spec.targetFieldID] != cookie.value else { return cookie.value }
            var updated = stored
            updated[target.spec.targetFieldID] = cookie.value
            try? CredentialStore.save(updated, for: target.providerID)
            onCredentialRefreshed?(target.providerID)
            return cookie.value
        }
        return nil
    }
}
