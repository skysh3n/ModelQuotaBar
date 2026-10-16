import AppKit
import SwiftUI

/// 阻止窗口打开时把焦点自动丢给第一个输入框。
///
/// 背景：macOS 会把窗口里第一个可输入控件设为初始 first responder，于是「控制台会话
/// Cookie」一进设置页就是选中态，随手打字就把凭据覆盖了。
///
/// SwiftUI 层的办法都试过且无效：`defaultFocus` 传 nil、传按钮、传一个隐形可聚焦元素，
/// 焦点照样落在输入框上。所以退到 AppKit：这个视图进入窗口时先清掉
/// `initialFirstResponder`，再等一拍确认——如果第一个响应者确实是文本输入
/// （AppKit 里输入框用的是字段编辑器 `NSTextView`），就把它交还给窗口本身。
///
/// 关掉窗口再打开会重建视图，所以每条窗口路径都会重新走一遍，不存在遗漏。
struct InitialFocusSuppressor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { SuppressorView() }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class SuppressorView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.initialFirstResponder = nil
            // 系统设焦点发生在窗口显示之后，所以晚一拍再确认一次。
            DispatchQueue.main.async { [weak window] in
                guard let window, window.firstResponder is NSTextView else { return }
                window.makeFirstResponder(nil)
            }
        }
    }
}

extension View {
    /// 把焦点抑制器塞到内容背后，不占布局、不可见。
    func suppressingInitialTextFieldFocus() -> some View {
        background(InitialFocusSuppressor().frame(width: 0, height: 0))
    }
}
