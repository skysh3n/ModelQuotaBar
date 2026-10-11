import Foundation

/// 千问 Token Plan 的接入站点。
///
/// 个人版与国际站是两套完全隔离的控制台：域名、网关 action、consoleSite 都不同，
/// 但请求结构与响应信封一致，因此共用同一份实现，仅由本枚举提供差异项。
public enum QwenTokenPlanRegion: String, CaseIterable, Sendable, Codable {
    /// 中国大陆站（bailian.console.aliyun.com）
    case chinaMainland = "cn"
    /// 国际站（modelstudio.console.alibabacloud.com）
    case international = "intl"

    public var displayName: String {
        switch self {
        case .chinaMainland: "中国大陆站"
        case .international: "国际站"
        }
    }

    /// 用量网关 host。与控制台页面所在 host 不同，不要混用。
    var quotaBaseURL: String {
        switch self {
        case .chinaMainland: "https://bailian-cs.console.aliyun.com"
        case .international: "https://bailian-singapore-cs.alibabacloud.com"
        }
    }

    /// 控制台 origin，用于拼 `Origin` / `Referer` 头。
    var consoleOrigin: String {
        switch self {
        case .chinaMainland: "https://bailian.console.aliyun.com"
        case .international: "https://modelstudio.console.alibabacloud.com"
        }
    }

    /// Token Plan 订阅页地址，设置界面里「打开控制台」按钮指向它。
    var consoleURL: URL {
        switch self {
        case .chinaMainland:
            URL(string: "https://bailian.console.aliyun.com/cn-beijing?tab=plan#/efm/subscription/token-plan/personal")!
        case .international:
            URL(string: "https://modelstudio.console.alibabacloud.com/ap-southeast-1?tab=plan#/efm/subscription/token-plan/personal")!
        }
    }

    /// 网关 action 名。
    var gatewayAction: String {
        switch self {
        case .chinaMainland: "BroadScopeAspnGateway"
        case .international: "IntlBroadScopeAspnGateway"
        }
    }

    /// `cornerstoneParam.consoleSite`。国际站这个值里有官方保留的历史拼写错误，
    /// 必须原样照抄，否则网关判为未授权。
    var consoleSite: String {
        switch self {
        case .chinaMainland: "BAILIAN_ALIYUN"
        case .international: "MODELSTUDIO_ALBABACLOUD"
        }
    }

    /// 表单里的 `region` 字段。
    var regionID: String {
        switch self {
        case .chinaMainland: "cn-beijing"
        case .international: "ap-southeast-1"
        }
    }

    /// 请求语言，只影响服务端返回的提示文案。
    var language: String {
        switch self {
        case .chinaMainland: "zh-CN"
        case .international: "en-US"
        }
    }

    /// 控制台页面 host，用于 `cornerstoneParam.domain`。
    var consoleHost: String {
        URL(string: consoleOrigin)?.host ?? consoleOrigin
    }
}