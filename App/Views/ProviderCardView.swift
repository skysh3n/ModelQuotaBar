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
                loadingBody
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
                if let balance = snapshot.balance, balance.unit != "Credits" {
                    accountCredits(balance)
                }
            }
            footnote(snapshot)
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
                Text(balance.unit == "USD" ? "剩余 Credits" : "账户余额")
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

    @ViewBuilder
    private func footnote(_ snapshot: QuotaSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let balance = snapshot.balance, balance.unit == "Credits", !snapshot.windows.isEmpty {
                Text("用量包剩余 \(Format.credits(balance.remaining)) \(balance.unit)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
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
}