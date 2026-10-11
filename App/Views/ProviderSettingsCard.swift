import SwiftUI

/// 单个额度来源的设置卡片。表单由 `provider.credentialFields` 动态生成，
/// 接入新厂商时这里不需要任何改动。
struct ProviderSettingsCard: View {
    let provider: ProviderDescriptor

    @Environment(AppEnvironment.self) private var environment
    @State private var credential = ProviderCredential()
    @State private var testState: TestState = .idle
    @State private var saveError: String?

    private enum TestState: Equatable {
        case idle
        case testing
        case success(String)
        case failure(String)
    }

    private var metadata: ProviderMetadata { provider.metadata }
    private var providerID: ProviderID { metadata.id }
    private var isEnabled: Bool { environment.settings.isEnabled(providerID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if isEnabled {
                Divider()
                fields
                footer
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        .task {
            credential = CredentialStore.loadCredential(for: providerID)
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(metadata.displayName)
                    .font(.subheadline.weight(.semibold))
                Text(metadata.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { isEnabled },
                set: { newValue in
                    environment.settings.setEnabled(newValue, for: providerID)
                    if newValue {
                        credential = CredentialStore.loadCredential(for: providerID)
                        testState = .idle
                    } else {
                        credential = ProviderCredential()
                    }
                    Task { await environment.store.refreshAll() }
                }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    // MARK: - 表单

    private var fields: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(provider.credentialFields) { field in
                fieldView(field)
            }
        }
    }

    @ViewBuilder
    private func fieldView(_ field: CredentialField) -> some View {
        switch field.kind {
        case .text:
            labeled(field) {
                TextField("", text: valueBinding(for: field.id))
                    .textFieldStyle(.roundedBorder)
            }
        case .secret:
            labeled(field) {
                SecureField("", text: valueBinding(for: field.id))
                    .textFieldStyle(.roundedBorder)
            }
        case let .picker(options):
            labeled(field) {
                Picker("", selection: valueBinding(for: field.id)) {
                    ForEach(options) { option in
                        Text(option.title).tag(option.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 220, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func labeled(
        _ field: CredentialField,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(field.title)
                    .font(.caption.weight(.medium))
                if field.isOptional {
                    Text("可选")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            content()
            if let hint = field.hint {
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 输入即写入钥匙串。cookie 这类凭据不适合要求用户额外点一次保存，
    /// 而钥匙串写入本身很快，逐次写不会造成卡顿。
    private func valueBinding(for key: String) -> Binding<String> {
        Binding(
            get: { credential[key] ?? "" },
            set: { newValue in
                credential[key] = newValue
                testState = .idle
                persist()
            }
        )
    }

    private func persist() {
        do {
            try CredentialStore.save(credential, for: providerID)
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
    }

    // MARK: - 底部操作

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button("测试连接") { runTest() }
                    .disabled(testState == .testing)
                if let url = metadata.consoleURL {
                    Link("打开控制台", destination: url)
                        .font(.callout)
                }
                Spacer()
            }

            if let hint = metadata.consoleHint {
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let saveError {
                Text(saveError)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
            statusView
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch testState {
        case .idle:
            EmptyView()
        case .testing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small).scaleEffect(0.7)
                Text("正在查询…").font(.caption2).foregroundStyle(.secondary)
            }
        case let .success(message):
            Label(message, systemImage: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.green)
        case let .failure(message):
            Label(message, systemImage: "xmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func runTest() {
        testState = .testing
        Task {
            do {
                let snapshot = try await provider.fetchSnapshot(credential: credential)
                let primary = snapshot.primaryWindow
                let summary = [
                    snapshot.planName,
                    primary.map { "\($0.title)剩余 \(Int(($0.remainingRatio * 100).rounded()))%" },
                ]
                .compactMap { $0 }
                .joined(separator: " · ")
                testState = .success(summary.isEmpty ? "连接成功" : summary)

                // 测试通了就把额度概览和小组件都刷新掉。
                await environment.refresh()
            } catch let error as QuotaError {
                testState = .failure(error.errorDescription ?? "查询失败")
            } catch {
                testState = .failure(error.localizedDescription)
            }
        }
    }
}