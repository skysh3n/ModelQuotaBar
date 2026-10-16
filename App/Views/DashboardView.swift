import SwiftUI
import WidgetKit

/// 主窗口。上半部分是额度概览，下半部分是配置。
struct DashboardView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var widgetSettings = SharedStore.loadWidgetSettings()
    @State private var launchAtLoginError: String?

    private var store: QuotaStore { environment.store }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                quotaSection
                Divider()
                sourcesSection
                Divider()
                generalSection
                Divider()
                widgetSection
            }
            .padding(20)
        }
        .frame(width: 520, height: 620)
    }

    // MARK: - 额度概览

    @ViewBuilder
    private var quotaSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("额度概览")
                    .font(.headline)
                Spacer()
                if store.isRefreshing {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                }
                Button {
                    Task { await environment.refresh() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(store.isRefreshing)
            }

            if store.results.isEmpty {
                emptyQuotaHint
            } else {
                ForEach(store.results) { result in
                    ProviderCardView(result: result)
                }
            }

            if let updated = store.lastRefreshAt {
                Text("\(Format.absolute(updated)) 更新")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var emptyQuotaHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("还没有启用任何额度来源")
                .font(.callout)
            Text("在下面的「额度来源」里打开通义千问，填入控制台 Cookie 即可开始。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - 额度来源

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("额度来源")
                .font(.headline)
            ForEach(ProviderRegistry.all) { provider in
                ProviderSettingsCard(provider: provider)
            }
        }
    }

    // MARK: - 通用

    private var generalSection: some View {
        return VStack(alignment: .leading, spacing: 12) {
            Text("通用")
                .font(.headline)

            LabeledContent("刷新") {
                Text("实时")
                    .foregroundStyle(.secondary)
            }
            Text("每个来源按自己的节奏轮询（DeepSeek 约每 5 秒，千问每 5 分钟），回到前台或系统唤醒时立即刷新；关掉本窗口后仍在后台刷新，桌面小组件会跟着更新。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            LabeledContent("开机自动启动") {
                Toggle("", isOn: Binding(
                    get: { LaunchAtLogin.isEnabled },
                    set: { newValue in
                        do {
                            try LaunchAtLogin.setEnabled(newValue)
                            launchAtLoginError = nil
                        } catch {
                            launchAtLoginError = error.localizedDescription
                        }
                    }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            if let launchAtLoginError {
                Text(launchAtLoginError)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 小组件

    private var widgetSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("桌面小组件")
                .font(.headline)

            LabeledContent("小组件显示") {
                Picker("", selection: Binding(
                    get: { widgetSettings.displayMode },
                    set: { newMode in
                        widgetSettings.displayMode = newMode
                        persistWidgetSettings()
                    }))
                {
                    Text("剩余额度").tag(WidgetSettings.DisplayMode.remainingPercent)
                    Text("已用额度").tag(WidgetSettings.DisplayMode.usedPercent)
                }
                .labelsHidden()
                .frame(width: 150)
            }

            if !SharedStore.isShared {
                Label(
                    "写不进小组件的数据目录，桌面上的小组件会一直显示空状态。",
                    systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("把小组件放到桌面：在桌面空白处右键 →「编辑小组件」→ 搜索「大模型额度」→ 拖到桌面。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func persistWidgetSettings() {
        SharedStore.saveWidgetSettings(widgetSettings)
        WidgetCenter.shared.reloadAllTimelines()
    }
}