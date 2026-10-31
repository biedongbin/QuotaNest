import AppKit
import SwiftUI

struct ModelCatalogControls: View {
    @ObservedObject var model: SettingsModel
    @State private var models: [String] = []
    @State private var loadedConnection: ModelCatalogConnection?
    @State private var request: Task<Void, Never>?
    @State private var generation = UUID()
    @State private var busy = false
    @State private var feedback = ""
    @State private var errorText: String?
    @State private var copied = false
    @State private var showModels = false
    @State private var search = ""

    private var connection: ModelCatalogConnection? {
        guard let draft = model.draft else { return nil }
        let config = model.callConfigForDraft(draft.values)
        return ModelCatalogConnection(baseURL: config.apiBaseURL, protocolName: config.refreshProtocol,
                                      apiKey: config.refreshKey, headers: config.refreshHeader)
    }
    private var filteredModels: [String] {
        search.isEmpty ? models : models.filter { $0.localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button(busy ? "拉取中…" : "拉取供应商模型", systemImage: "arrow.down.circle") { fetch(recommend: false) }
                    .barButton().disabled(busy)
                Button("推荐测试模型", systemImage: "sparkles") { recommend() }
                    .barButton().disabled(busy)
            }
            if !models.isEmpty {
                    Button("选择模型（\(models.count)）") { showModels.toggle() }.barButton(.ghost)
                        .popover(isPresented: $showModels) {
                            VStack(spacing: 10) {
                                TextField("搜索模型", text: $search).fieldBox()
                                ScrollView {
                                    LazyVStack(alignment: .leading, spacing: 2) {
                                        ForEach(filteredModels, id: \.self) { id in
                                            Button {
                                                model.draft?.values.model = id
                                                feedback = "已选择 \(id)，保存后生效"
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
            if !feedback.isEmpty { Text(feedback).font(Typo.small).foregroundStyle(Palette.muted).textSelection(.enabled) }
            if let errorText {
                HStack {
                    Text("获取模型失败").font(Typo.small).foregroundStyle(Palette.danger)
                    Spacer()
                    Button(copied ? "已复制" : "复制完整错误") {
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

    private func reset() {
        request?.cancel(); generation = UUID(); busy = false
        models = []; loadedConnection = nil; feedback = ""; errorText = nil; copied = false
    }
    private func recommend() {
        guard loadedConnection == connection, !models.isEmpty else { fetch(recommend: true); return }
        applyRecommendation()
    }
    private func applyRecommendation() {
        guard let suggestion = ModelCatalogService.recommendation(from: models) else {
            feedback = "未找到可推荐的文本模型，请手动填写测试模型"
            return
        }
        model.draft?.values.model = suggestion.model
        feedback = "推荐 \(suggestion.model)：\(suggestion.reason)；保存后生效"
    }
    private func fetch(recommend: Bool) {
        guard let snapshot = connection else { return }
        request?.cancel()
        let token = UUID(); generation = token
        busy = true; errorText = nil; copied = false; feedback = "正在读取模型列表，不发起模型调用…"
        request = Task { @MainActor in
            defer { if generation == token { busy = false } }
            do {
                let result = try await ModelCatalogService.fetch(connection: snapshot)
                guard !Task.isCancelled, generation == token, connection == snapshot else { return }
                models = result; loadedConnection = snapshot
                feedback = "已拉取 \(result.count) 个模型"
                if recommend { applyRecommendation() }
                else { showModels = true }
            } catch {
                guard !Task.isCancelled, generation == token, connection == snapshot else { return }
                models = []; loadedConnection = nil; feedback = ""
                errorText = error.localizedDescription
            }
        }
    }
}
