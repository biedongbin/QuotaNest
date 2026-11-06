import AppKit
import SwiftUI

struct ModelCatalogControls: View {
    @ObservedObject var model: SettingsModel
    var savedAccount: AccountRow? = nil
    var modelSelection: Binding<String>? = nil
    @State private var models: [String] = []
    @State private var loadedConnection: Fingerprint?
    @State private var loadedResolved: ModelCatalogConnection?
    @State private var request: Task<Void, Never>?
    @State private var generation = UUID()
    @State private var busy = false
    @State private var feedback = L10n.resource("")
    private var feedbackText: String { L10n.string(feedback) }
    @State private var failure: Error?
    private var errorText: String? { failure.map(L10n.errorDescription) }
    @State private var copied = false
    @State private var showModels = false
    @State private var search = ""

    private struct Fingerprint: Equatable {
        let slug: String?
        let template: String?
        let values: DraftValues?
    }
    private var connection: Fingerprint? {
        if let account = savedAccount {
            return Fingerprint(slug: account.id, template: account.plugin.manifest.template, values: nil)
        }
        guard let draft = model.draft else { return nil }
        var values = draft.values
        // Model choice and schedule do not change the account's connection.
        values.model = ""; values.prompt = ""; values.times = []; values.autoTrigger = false
        return Fingerprint(slug: draft.slug, template: draft.template, values: values)
    }
    private var filteredModels: [String] {
        search.isEmpty ? models : models.filter { $0.localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button(busy ? L10n.tr("拉取中…") : L10n.tr("拉取供应商模型"), systemImage: "arrow.down.circle") { fetch(recommend: false) }
                    .barButton().disabled(busy)
                Button(L10n.tr("推荐轻量测试模型"), systemImage: "sparkles") { recommend() }
                    .barButton().disabled(busy)
            }
            Text(L10n.tr("轻量模型建议仅用于连通性测试，不能证明调用会启动 5h 窗口；请确认目标套餐支持。"))
                .font(Typo.small).foregroundStyle(Palette.muted)
            if !models.isEmpty {
                    Button(L10n.tr("选择模型（%@）", String(describing: models.count))) {
                        if cachedConnectionIsCurrent() { showModels.toggle() }
                        else { reset(); fetch(recommend: false) }
                    }.barButton(.ghost)
                        .popover(isPresented: $showModels) {
                            VStack(spacing: 10) {
                                TextField(L10n.tr("搜索模型"), text: $search).fieldBox()
                                ScrollView {
                                    LazyVStack(alignment: .leading, spacing: 2) {
                                        ForEach(filteredModels, id: \.self) { id in
                                            Button {
                                                guard select(id) else { return }
                                                feedback = savedAccount == nil ? L10n.resource("已选择 \(id)，保存后生效")
                                                    : L10n.resource("已选择 \(id)，仅用于本次测试")
                                                showModels = false
                                            } label: {
                                                Text(id).font(Typo.mono).lineLimit(2)
                                                    .frame(maxWidth: .infinity, alignment: .leading).padding(7)
                                                    .contentShape(Rectangle())
                                            }.buttonStyle(.plain)
                                        }
                                    }
                                }.frame(height: 280)
                            }.padding(14).frame(width: 360).background(Palette.surface)
                        }
                }
            if !feedbackText.isEmpty { Text(feedbackText).font(Typo.small).foregroundStyle(Palette.muted).textSelection(.enabled) }
            if let errorText {
                HStack {
                    Text(L10n.tr("获取模型失败")).font(Typo.small).foregroundStyle(Palette.danger)
                    Spacer()
                    Button(copied ? L10n.tr("已复制") : L10n.tr("复制完整错误")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(errorText, forType: .string)
                        copied = true
                    }.barButton(.ghost)
                }
                ScrollView {
                    Text(errorText).font(Typo.mono).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 140)
            }
        }
        .onChange(of: connection) { _, _ in reset() }
        .onDisappear { request?.cancel(); generation = UUID(); busy = false }
    }

    private func currentCallConfig() -> ProviderConfig? {
        if let account = savedAccount {
            guard let current = model.row(account.id) else { return nil }
            return model.readConfig(current.plugin)
        }
        guard let draft = model.draft else { return nil }
        return model.callConfigForDraft(draft.values)
    }
    private func cachedConnectionIsCurrent() -> Bool {
        guard let loadedResolved, let config = currentCallConfig(),
              let current = try? ProviderAuthentication.resolveCall(config) else { return false }
        return ModelCatalogConnection(callConfig: current) == loadedResolved
    }
    @discardableResult private func select(_ id: String) -> Bool {
        guard cachedConnectionIsCurrent() else {
            reset(); showModels = false
            feedback = L10n.resource("来源认证或接口已变化，请重新拉取模型列表")
            return false
        }
        if let modelSelection { modelSelection.wrappedValue = id }
        else { model.draft?.values.model = id }
        return true
    }

    private func reset() {
        request?.cancel(); generation = UUID(); busy = false
        models = []; loadedConnection = nil; loadedResolved = nil; feedback = L10n.resource(""); failure = nil; copied = false
    }
    private func recommend() {
        guard currentCallConfig()?.authMode != "auth", loadedConnection == connection, !models.isEmpty, cachedConnectionIsCurrent() else {
            fetch(recommend: true); return
        }
        applyRecommendation()
    }
    private func applyRecommendation() {
        guard let suggestion = ModelCatalogService.recommendation(from: models) else {
            feedback = L10n.resource("未找到可推荐的文本模型，请手动填写测试模型")
            return
        }
        guard select(suggestion.model) else { return }
        feedback = savedAccount == nil
            ? L10n.resource("轻量连通性测试建议 \(suggestion.model)：\(suggestion.reason)；保存后生效")
            : L10n.resource("已选择 \(suggestion.model)，仅用于本次测试")
    }
    private func fetch(recommend: Bool) {
        guard let snapshot = connection else { return }
        request?.cancel()
        let token = UUID(); generation = token
        busy = true; failure = nil; copied = false; feedback = L10n.resource("正在读取模型列表，不发起模型调用…")
        request = Task { @MainActor in
            defer { if generation == token { busy = false } }
            do {
                guard let snapshotConfig = currentCallConfig() else { return }
                let config = try ProviderAuthentication.resolveCall(snapshotConfig)
                let resolved = ModelCatalogConnection(callConfig: config)
                let result = try await ModelCatalogService.fetch(connection: resolved)
                guard !Task.isCancelled, generation == token, connection == snapshot else { return }
                guard let fresh = currentCallConfig() else { return }
                let current = try ProviderAuthentication.resolveCall(fresh)
                let currentConnection = ModelCatalogConnection(callConfig: current)
                guard currentConnection == resolved else {
                    models = []; loadedConnection = nil; loadedResolved = nil
                    feedback = L10n.resource("本机授权已变化，请重新拉取当前账号的模型列表")
                    return
                }
                models = result; loadedConnection = snapshot; loadedResolved = resolved
                feedback = L10n.resource("已拉取 \(String(result.count)) 个模型；请确认目标套餐支持所选模型")
                if recommend { applyRecommendation() }
                else { showModels = true }
            } catch {
                guard !Task.isCancelled, generation == token, connection == snapshot else { return }
                models = []; loadedConnection = nil; loadedResolved = nil; feedback = L10n.resource("")
                failure = error
            }
        }
    }
}
