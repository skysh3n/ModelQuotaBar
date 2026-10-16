import SwiftUI
import WidgetKit

/// 主窗口。上半部分是额度概览，下半部分是配置。
struct DashboardView: View {
    @Environment(AppEnvironment.self) private var environment

    private var store: QuotaStore { environment.store }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                quotaSection
                Divider()
                sourcesSection
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

    // MARK: - 小组件

    private var widgetSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("桌面小组件")
                .font(.headline)

            if !SharedStore.isShared {
                Label(
                    "写不进小组件的数据目录，桌面上的小组件会一直显示空状态。",
                    systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("把小组件放到桌面：桌面右键 →「编辑小组件」→ 搜索「大模型额度」。组件库里有两条：「大模型额度」是小尺寸（选一个来源），「大模型额度 · 多来源」是中尺寸（可勾选多个并排显示）。加进来后右键点它 →「编辑」可改来源。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}