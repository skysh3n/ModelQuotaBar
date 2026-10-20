import Foundation

/// 所有已支持的额度来源。
///
/// 接入新厂商时只需在 `all` 里追加一行，设置界面与刷新逻辑会自动带上它。
public enum ProviderRegistry {
    public static let all: [ProviderDescriptor] = [
        QwenTokenPlanProvider.descriptor,
        DeepSeekProvider.descriptor,
        CursorProvider.descriptor,
    ]

    public static func descriptor(for id: ProviderID) -> ProviderDescriptor? {
        all.first { $0.id == id }
    }
}