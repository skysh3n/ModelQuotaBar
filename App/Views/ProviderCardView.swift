import SwiftUI

/// 一个额度来源的完整卡片。
struct ProviderCardView: View {
    let result: ProviderResult

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let snapshot = result.snapshot {
                snapshotBody(snapshot)
            }
            // 错误一定要显示。会话过期时旧数据还在，如果只在「没有数据」时才报错，
            // 用户会看到一堆过期数字加一句含糊的「数据可能已过期」，却不知道要去更新 Cookie。
            if let error = result.error {
                errorBody(error)
            } else if result.snapshot == nil {
                // 未自动拉取：空闲时提示手动刷新，只有 isLoading 才转圈。
                if result.isLoading {
                    loadingBody
                } else {
                    idleBody
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - 标题

    private var header: some View {
        HStack(spacing: 6) {
            Text(result.metadata.displayName)
                .font(.subheadline.weight(.semibold))
            if let plan = result.snapshot?.planName {
                Text(plan)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.tint.opacity(0.15), in: Capsule())
            }
            Spacer()
            if let status = result.snapshot?.status, status.uppercased() != "VALID" {
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - 正常数据

    private func snapshotBody(_ snapshot: QuotaSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if snapshot.windows.isEmpty, let balance = snapshot.balance {
                balanceHero(balance, isAvailable: snapshot.isAvailable)
                // 多块资源包时，第一块已经在 hero 里显示，其余的单独列出。
                if snapshot.resourcePackages.count > 1 {
                    resourcePackageRows(snapshot.resourcePackages.dropFirst())
                }
            } else {
                if let primary = snapshot.primaryWindow {
                    heroNumber(primary)
                }
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(snapshot.windows) { window in
                        QuotaWindowRow(
                            window: window,
                            isPrimary: window.id == snapshot.primaryWindow?.id)
                    }
                }
                // 资源包列表：每块一行，显示标签、剩余/总量、到期时间。
                if !snapshot.resourcePackages.isEmpty {
                    resourcePackageRows(snapshot.resourcePackages)
                }
            }
            footnote(snapshot)
        }
    }

    /// 渲染多块资源包，每块一行。
    private func resourcePackageRows(_ packages: some RandomAccessCollection<ResourcePackageInfo>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(packages), id: \.self) { package in
                ResourcePackageRow(package: package)
            }
        }
    }

    private func heroNumber(_ window: QuotaWindow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(String(format: "%.1f%%", window.remainingRatio * 100))
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(QuotaPalette.color(remainingRatio: window.remainingRatio))
            Text("\(window.title)剩余")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func accountCredits(_ balance: CreditBalance) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(CurrencySymbol.format(balance.remaining, unit: balance.unit))
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text("剩余 Credits")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func balanceHero(_ balance: CreditBalance, isAvailable: Bool?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(CurrencySymbol.format(balance.remaining, unit: balance.unit))
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(isAvailable == false ? Color.orange : Color.primary)
                // 优先使用资源包自带的 label；否则按单位兜底。
                Text(balance.label ?? balanceLabel(for: balance.unit))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            if isAvailable == false {
                Text("余额不足，API 调用会被拒绝")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    /// 按单位推断兜底标签：Credits →「用量包剩余」，其他 →「账户余额」。
    private func balanceLabel(for unit: String) -> String {
        if unit.caseInsensitiveCompare("Credits") == .orderedSame {
            return "用量包剩余"
        }
        return "账户余额"
    }

    @ViewBuilder
    private func footnote(_ snapshot: QuotaSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            // Credits 单位的资源包已经在 resourcePackageRows 里显示，不再重复。
            // 这里只保留套餐剩余天数 / 到期时间。
            if let days = snapshot.remainingDays {
                Text("套餐剩余 \(days) 天")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else if let expiresAt = snapshot.expiresAt {
                Text("套餐 \(Format.absolute(expiresAt)) 到期")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - 异常状态

    private func errorBody(_ error: QuotaError) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(error.errorDescription ?? "查询失败")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if case .sessionExpired = error {
                Text("在下方「额度来源」里点「登录获取」重新登录，或粘贴新的凭据。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var loadingBody: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small).scaleEffect(0.7)
            Text("正在查询…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var idleBody: some View {
        Text("点右上角「刷新」获取额度")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

// MARK: - 资源包行

/// 一块资源包的展示行：标签 + 剩余/总量 + 到期时间。
private struct ResourcePackageRow: View {
    let package: ResourcePackageInfo

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(displayLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if let total = package.total, total > 0 {
                Text("\(Format.credits(package.remaining)) / \(Format.credits(total)) \(package.unit)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.primary)
            } else {
                Text("\(Format.credits(package.remaining)) \(package.unit)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.primary)
            }
        }
        if let expiresAt = package.expiresAt {
            Text("\(Format.absolute(expiresAt)) 到期")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    /// 展示标签：优先资源包自带的 label，否则按单位兜底。
    ///
    /// 兜底逻辑只按单位区分：Credits →「用量包剩余」，其他（CNY/USD 等）→「账户余额」。
    /// 展示层不再猜测具体币种；具体文案由各 Provider 在构造时通过 label 传入。
    private var displayLabel: String {
        if let label = package.label, !label.isEmpty {
            return label
        }
        // 按单位兜底：Credits 是套餐外用量的单位，其他（CNY/USD/EUR 等）是充值余额。
        if package.unit.caseInsensitiveCompare("Credits") == .orderedSame {
            return "用量包剩余"
        }
        return "账户余额"
    }
}