import SwiftUI
import WebKit

/// 内嵌网页登录：打开厂商控制台，用户登录后自动抓取指定 Cookie。
///
/// 相比「手动去开发者工具复制」，这里用 `WKHTTPCookieStore` 这个公开接口拿凭据，
/// 既不用读浏览器的 Cookie 文件（那需要「完全磁盘访问」），也不用让用户找 F12。
struct WebLoginSheet: View {
    let spec: WebLoginSpec
    let onCaptured: (String) -> Void
    let onCancel: () -> Void

    @State private var status: String

    init(spec: WebLoginSpec, onCaptured: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.spec = spec
        self.onCaptured = onCaptured
        self.onCancel = onCancel
        _status = State(initialValue: spec.hint)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("登录控制台")
                    .font(.headline)
                Spacer()
                Button("取消") { onCancel() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)

            Divider()

            ConsoleWebView(spec: spec, status: $status, onCaptured: onCaptured)

            Divider()

            HStack(spacing: 6) {
                Image(systemName: "lock.shield")
                    .foregroundStyle(.tertiary)
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            .padding(10)
        }
        .frame(width: 560, height: 640)
    }
}

/// 包一层 WKWebView，并在页面加载过程中轮询 Cookie。
private struct ConsoleWebView: NSViewRepresentable {
    let spec: WebLoginSpec
    @Binding var status: String
    let onCaptured: (String) -> Void

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // 用默认（持久）数据存储：登录态留在 App 里，下次不用重新登。
        configuration.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        let coordinator = context.coordinator
        let status = $status
        Task { @MainActor in
            webView.load(URLRequest(url: spec.url))
            coordinator.startWatching(webView: webView, spec: spec, status: status, onCaptured: onCaptured)
        }
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKHTTPCookieStoreObserver {
        private var pollTask: Task<Void, Never>?
        private var spec: WebLoginSpec?
        private var status: Binding<String>?
        private var onCaptured: ((String) -> Void)?
        private var didReachBusinessPage = false
        private var didSeeLoginPage = false
        private var didRedirectToPostLogin = false
        private var didCaptureCookie = false
        private var webView: WKWebView?
        /// 正在等服务端确认候选 Cookie 是否有效。
        private var isValidating = false
        /// 最近一次被服务端拒绝的候选值和拒绝时间。
        private var lastRejected: (value: String, at: Date)?
        /// 打开弹窗时存储里已有的凭据值。
        ///
        /// 不能靠「先删旧 Cookie」来防抓到过期的票：有些站点（如 Qoder）删掉后
        /// 不会静默重发，只能让用户重新手登。改成记住初始值：值变了说明是新下发的；
        /// 值没变但业务页加载成功，说明这张旧票服务端还认，两种情况才抓。
        private var initialCookieValue: String?

        func startWatching(
            webView: WKWebView,
            spec: WebLoginSpec,
            status: Binding<String>,
            onCaptured: @escaping (String) -> Void
        ) {
            self.spec = spec
            self.status = status
            self.onCaptured = onCaptured
            self.webView = webView
            pollTask?.cancel()

            // 注册 Cookie 观察者，当 Cookie 被设置时会立即收到通知
            webView.configuration.websiteDataStore.httpCookieStore.add(self)

            pollTask = Task { @MainActor in
                let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
                initialCookieValue = cookies.first(where: { $0.name == spec.cookieName })?.value

                // 登录是在网页里异步完成的，没有回调可挂，轮询 Cookie 最简单可靠。
                while !Task.isCancelled && !didCaptureCookie {
                    try? await Task.sleep(for: .seconds(1))
                    if Task.isCancelled || didCaptureCookie { return }
                    let current = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
                    guard let cookie = current.first(where: { $0.name == spec.cookieName }),
                          !cookie.value.isEmpty,
                          shouldCapture(value: cookie.value)
                    else { continue }
                    await attemptCapture(cookie.value)
                    if didCaptureCookie { return }
                }
            }
        }

        /// 新下发的票（值变了）随时可抓；旧票要等业务页加载成功证明它还有效。
        /// 见过登录页、或当前停在登录页，就说明旧票已被服务端拒绝，只能等新票。
        private func shouldCapture(value: String) -> Bool {
            if value != initialCookieValue { return true }
            guard didReachBusinessPage, !didSeeLoginPage, let webView else { return false }
            let onLoginPage = webView.url.map {
                $0.path.lowercased().contains("login") || $0.path.lowercased().contains("auth")
            } ?? true
            return !onLoginPage
        }

        /// 候选 Cookie 先在服务端确认有效，再采纳。
        ///
        /// 登录页本身可能先下发一张同名但匿名的 Cookie：只看名字会误判登录完成，
        /// 弹窗在用户登录前关闭，还存下一张 401 的票。没有校验器时维持原行为。
        private func attemptCapture(_ value: String) async {
            guard !didCaptureCookie, !isValidating else { return }
            guard let validator = spec?.validateCookie else {
                capture(value)
                return
            }
            // 同一张无效票短时间内不再重复请求，等页面下发新票或过一会儿再试。
            if let rejected = lastRejected,
               rejected.value == value,
               Date().timeIntervalSince(rejected.at) < 30
            {
                return
            }

            isValidating = true
            status?.wrappedValue = "正在确认登录状态…"
            let isValid = await validator(value)
            isValidating = false
            guard !didCaptureCookie, !Task.isCancelled else { return }

            if isValid {
                capture(value)
            } else {
                lastRejected = (value, Date())
                status?.wrappedValue = "还没登录成功，请在上方页面完成登录。"
            }
        }

        private func capture(_ value: String) {
            guard !didCaptureCookie else { return }
            didCaptureCookie = true
            status?.wrappedValue = "已取得登录凭据，正在保存…"
            pollTask?.cancel()
            onCaptured?(value)
        }

        /// WKHTTPCookieStoreObserver 协议方法：Cookie 变化时调用
        func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
            guard !didCaptureCookie, let spec else { return }
            Task { @MainActor in
                let cookies = await cookieStore.allCookies()
                guard let cookie = cookies.first(where: { $0.name == spec.cookieName }),
                      !cookie.value.isEmpty,
                      shouldCapture(value: cookie.value)
                else { return }
                await attemptCapture(cookie.value)
            }
        }

        /// 离开登录页说明登录完成，落回业务页——凭据是在那一步才下发的。
        ///
        /// 不能只比较 host：阿里云登录完成后可能先回到 `account.aliyun.com` 的首页，
        /// host 没变，但如果一直不跳控制台，业务票据可能就不会下发。这里改看路径：
        /// 仍在登录页（路径含 login）就等，已经到目标控制台就不重复加载。
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let spec,
                  let url = webView.url
            else { return }

            // 判断是否还在登录页：路径包含 "login" 或 "auth" 说明还没登完
            let isLoginPage = url.path.lowercased().contains("login")
                || url.path.lowercased().contains("auth")
            if isLoginPage {
                didSeeLoginPage = true
                return
            }

            // 业务页加载完成：旧票若还有效，轮询下一轮就会抓走。
            didReachBusinessPage = true

            guard let postLogin = spec.postLoginURL,
                  !didRedirectToPostLogin
            else { return }
            if url.host == postLogin.host, url.path == postLogin.path { return }

            didRedirectToPostLogin = true
            webView.load(URLRequest(url: postLogin))
        }

        deinit {
            pollTask?.cancel()
            if let webView = webView {
                webView.configuration.websiteDataStore.httpCookieStore.remove(self)
            }
        }
    }
}

private extension WKHTTPCookieStore {
    /// `getAllCookies` 只有回调版，这里桥成 async。
    func allCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            getAllCookies { continuation.resume(returning: $0) }
        }
    }
}
