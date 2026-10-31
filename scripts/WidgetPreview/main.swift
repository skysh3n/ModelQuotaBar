import SwiftUI
import Foundation

/// 小组件视图的桌面预览宿主：直接复用 Widget 源码，不需要把小组件放到桌面。
/// 真实快照来自共享容器；再插一条千问样例覆盖次要窗口/重置/到期天数的布局。
@main
struct WidgetPreviewApp: App {
    var body: some Scene {
        WindowGroup("Widget Preview") {
            WidgetPreviewContent()
        }
        .windowResizability(.contentSize)
    }
}

struct WidgetPreviewContent: View {
    private let snapshots: [WidgetSnapshot] = {
        var loaded = SharedStore.loadSnapshots()
        let qwen = WidgetSnapshot(
            id: "qwen-token-plan",
            vendor: "通义千问",
            title: "通义千问 Token Plan",
            planName: "Pro 专业版",
            primaryTitle: "每周",
            primaryRemainingRatio: 0.725,
            primaryResetsAt: Date().addingTimeInterval(3 * 86_400),
            balanceRemaining: nil,
            balanceUnit: nil,
            secondaryWindows: [
                WidgetWindow(
                    id: "5h",
                    title: "每 5 小时",
                    remainingRatio: 0.998,
                    resetsAt: Date().addingTimeInterval(2 * 3_600)),
                WidgetWindow(
                    id: "monthly",
                    title: "每月",
                    remainingRatio: 0.81,
                    resetsAt: Date().addingTimeInterval(20 * 86_400)),
            ],
            remainingDays: 29,
            updatedAt: Date())
        loaded.insert(qwen, at: 0)
        return loaded
    }()

    private var smallSnapshots: [WidgetSnapshot] { Array(snapshots.prefix(3)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("小尺寸").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 18) {
                ForEach(smallSnapshots) { snapshot in
                    SmallWidgetView(snapshot: snapshot)
                        .padding(14)
                        .frame(width: 170, height: 170)
                        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 22))
                }
            }

            Text("实际小组件（中尺寸，含刷新按钮）").font(.caption).foregroundStyle(.secondary)
            QuotaWidgetEntryView(entry: QuotaEntry(
                date: Date(),
                allSnapshots: Array(snapshots.prefix(2)),
                sources: [.qwen, .deepseek],
                isPlaceholder: true))
                .frame(width: 360, height: 170)
                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 22))
        }
        .padding(28)
        .frame(width: 640, height: 520)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
