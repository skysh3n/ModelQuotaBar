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
        webView.load(URLRequest(url: spec.url))
        context.coordinator.startWatching(webView: webView, spec: spec, status: $status, onCaptured: onCaptured)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        private var pollTask: Task<Void, Never>?
        private var spec: WebLoginSpec?
        private var didLeaveLoginPage = false

        func startWatching(
            webView: WKWebView,
            spec: WebLoginSpec,
            status: Binding<String>,
            onCaptured: @escaping (String) -> Void
        ) {
            self.spec = spec
            pollTask?.cancel()
            // 登录是在网页里异步完成的，没有回调可挂，轮询 Cookie 最简单可靠。
            pollTask = Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    if Task.isCancelled { return }
                    let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
                    guard let cookie = cookies.first(where: { $0.name == spec.cookieName }),
                          !cookie.value.isEmpty
                    else { continue }
                    status.wrappedValue = "已取得登录凭据，正在保存…"
                    pollTask?.cancel()
                    onCaptured(cookie.value)
                    return
                }
            }
        }

        /// 离开登录页说明登录完成，落回业务页——凭据是在那一步才下发的。
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let spec, let postLogin = spec.postLoginURL, !didLeaveLoginPage else { return }
            guard let host = webView.url?.host, host != spec.url.host else { return }
            didLeaveLoginPage = true
            webView.load(URLRequest(url: postLogin))
        }

        deinit { pollTask?.cancel() }
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
