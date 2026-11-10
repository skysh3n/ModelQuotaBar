import SwiftUI
import WidgetKit
import Foundation

/// 小组件视图的桌面预览宿主：直接复用 Widget 源码，不需要把小组件放到桌面。
/// 真实快照来自共享容器；再插一条千问样例覆盖次要窗口/重置/到期天数的布局。
@main
struct WidgetPreviewApp: App {
    @Environment(\.openURL) private var openURL
    
    var body: some Scene {
        WindowGroup("Widget Preview") {
            if CommandLine.arguments.contains("--png") {
                // PNG 导出模式：离屏渲染后退出
                PngExportView()
            } else {
                // 正常预览模式：显示窗口
                WidgetPreviewContent()
            }
        }
        .windowResizability(.contentSize)
    }
}

// MARK: - PNG 导出模式

/// 离屏渲染视图：生成四张 PNG 后自动退出
struct PngExportView: View {
    @State private var exportComplete = false
    
    var body: some View {
        Group {
            if exportComplete {
                Text("PNG export complete")
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            NSApplication.shared.terminate(nil)
                        }
                    }
            } else {
                Text("Exporting PNGs...")
                    .onAppear {
                        Task { await exportPngs() }
                    }
            }
        }
    }
    
    private func exportPngs() async {
        let outputDir = getPngOutputDir()
        let fm = FileManager.default
        
        do {
            try fm.createDirectory(at: outputDir, withIntermediateDirectories: true)
            
            // 加载真实快照
            var snapshots = SharedStore.loadSnapshots()
            
            // 补充千问样例（仅当真实数据缺失时，标记 synthetic）
            var hasSyntheticQwen = false
            if snapshots.isEmpty || !snapshots.contains(where: { $0.id == "qwen-token-plan" }) {
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
                        WidgetWindow(id: "5h", title: "每 5 小时", remainingRatio: 0.998, resetsAt: Date().addingTimeInterval(2 * 3_600)),
                        WidgetWindow(id: "monthly", title: "每月", remainingRatio: 0.81, resetsAt: Date().addingTimeInterval(20 * 86_400)),
                    ],
                    remainingDays: 29,
                    updatedAt: Date())
                snapshots.insert(qwen, at: 0)
                hasSyntheticQwen = true
            }
            
            // 辅助函数：渲染并保存
            func render<V: View>(_ view: V, to name: String) throws {
                try renderAndSave(view, to: outputDir.appendingPathComponent(name))
                print("Exported: \(name)")
            }
            
            func dualEntry(_ s1: WidgetSnapshot, _ s2: WidgetSnapshot, sources: [WidgetSource]) -> QuotaEntry {
                QuotaEntry(date: Date(), allSnapshots: [s1, s2], sources: sources, isPlaceholder: false)
            }

            // MARK: 小尺寸矩阵（真实尺寸 164×164）
            // 小尺寸：qoder（两块包）、cursor、deepseek、qwen（synthetic）
            for snap in snapshots {
                let suffix = (snap.id == "qwen-token-plan" && hasSyntheticQwen) ? "_synthetic" : ""
                try render(SmallWidgetView(snapshot: snap)
                    .frame(width: 164, height: 164)
                    .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 22)),
                    to: "small_\(snap.id)\(suffix).png")

                // 真实小组件外壳：含系统内容边距 + 右上角刷新按钮，用来核对避让和底部留白。
                // 边距取桌面实测值（小卡 164pt：左右 18pt、上下 12pt）。
                // 预览宿主不是 WidgetKit 进程，widgetFamily 默认不是 small，必须显式指定。
                if let source = WidgetSource(rawValue: snap.id) {
                    try render(QuotaWidgetEntryView(
                        entry: QuotaEntry(
                            date: Date(), allSnapshots: [snap], sources: [source], isPlaceholder: false),
                        familyOverride: .systemSmall)
                        .padding(EdgeInsets(top: 12, leading: 18, bottom: 12, trailing: 18))
                        .frame(width: 164, height: 164)
                        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 22)),
                        to: "small_real_\(snap.id)\(suffix).png")
                }
            }

            // MARK: 中尺寸单来源矩阵（真实宽度 344 × 三种帧高）
            func singleViews(_ snap: WidgetSnapshot, source: WidgetSource, baseName: String) throws {
                try render(QuotaWidgetEntryView(entry: QuotaEntry(date: Date(), allSnapshots: [snap], sources: [source], isPlaceholder: false))
                    .frame(width: 344, height: 164)
                    .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 22)),
                    to: "\(baseName)_164.png")
                try render(QuotaWidgetEntryView(entry: QuotaEntry(date: Date(), allSnapshots: [snap], sources: [source], isPlaceholder: false))
                    .frame(width: 344, height: 150)
                    .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 22)),
                    to: "\(baseName)_150.png")
                try render(QuotaWidgetEntryView(entry: QuotaEntry(date: Date(), allSnapshots: [snap], sources: [source], isPlaceholder: false))
                    .frame(width: 344, height: 140)
                    .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 22)),
                    to: "\(baseName)_140.png")
            }
            if let qoder = snapshots.first(where: { $0.id == "qoder" }) {
                try singleViews(qoder, source: .qoder, baseName: "medium_single_qoder")
            }
            if let deepseek = snapshots.first(where: { $0.id == "deepseek" }) {
                try singleViews(deepseek, source: .deepseek, baseName: "medium_single_deepseek")
            }

            // MARK: 中尺寸双栏矩阵（真实宽度 344 × 三种帧高，仅用户启用的组合）
            func dualViewsReal(_ entry: QuotaEntry, baseName: String) throws {
                try render(QuotaWidgetEntryView(entry: entry).frame(width: 344, height: 164)
                    .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 22)),
                    to: "\(baseName)_164.png")
                try render(QuotaWidgetEntryView(entry: entry).frame(width: 344, height: 150)
                    .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 22)),
                    to: "\(baseName)_150.png")
                try render(QuotaWidgetEntryView(entry: entry).frame(width: 344, height: 140)
                    .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 22)),
                    to: "\(baseName)_140.png")
            }
            let qoder = snapshots.first(where: { $0.id == "qoder" })
            let cursor = snapshots.first(where: { $0.id == "cursor" })
            let deepseek = snapshots.first(where: { $0.id == "deepseek" })

            if let qoder, let cursor {
                try dualViewsReal(dualEntry(qoder, cursor, sources: [.qoder, .cursor]), baseName: "medium_dual_qoder_cursor")
            }
            if let qoder, let deepseek {
                try dualViewsReal(dualEntry(qoder, deepseek, sources: [.qoder, .deepseek]), baseName: "medium_dual_qoder_deepseek")
            }
            
            // MARK: 全量预览图
            let previewSnapshots = Array(snapshots.prefix(3))
            try render(WidgetPreviewContentView(snapshots: previewSnapshots).padding(28)
                .frame(width: 640, height: 520)
                .background(Color(nsColor: .windowBackgroundColor)),
                to: "full_preview.png")
            
            print("All PNGs exported to: \(outputDir.path)")
            exportComplete = true
            
        } catch {
            print("PNG export failed: \(error.localizedDescription)")
            exportComplete = true
        }
    }
    
    private func getPngOutputDir() -> URL {
        if let idx = CommandLine.arguments.firstIndex(of: "--png"),
           idx + 1 < CommandLine.arguments.count {
            return URL(fileURLWithPath: CommandLine.arguments[idx + 1])
        }
        return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("widget-preview-pngs")
    }
    
    private func renderAndSave<V: View>(_ view: V, to url: URL) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2.0
        
        guard let cgImage = renderer.cgImage else {
            throw NSError(domain: "WidgetPreview", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to render view"])
        }
        
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "WidgetPreview", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to encode PNG"])
        }
        
        try pngData.write(to: url)
    }
}

// MARK: - 原有预览内容（提取为独立视图以便复用）

struct WidgetPreviewContentView: View {
    let snapshots: [WidgetSnapshot]
    
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
    
    var body: some View {
        WidgetPreviewContentView(snapshots: snapshots)
            .padding(28)
            .frame(width: 640, height: 520)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}
