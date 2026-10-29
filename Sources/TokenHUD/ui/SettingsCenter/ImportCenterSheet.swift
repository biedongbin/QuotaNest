import SwiftUI
import AppKit

// MARK: - 导入 sheet (源 → 扫描 → 预览 → 导入所选 → 逐项结果/重试)

@MainActor
final class ImportCenterModel: ObservableObject {
    enum Source: String, CaseIterable, Identifiable {
        case nineRouter, ccSwitch, cpamp
        var id: String { rawValue }
        var label: String {
            switch self {
            case .nineRouter: return "9router"
            case .ccSwitch: return "cc-switch"
            case .cpamp: return "CPAMP"
            }
        }
        var path: String {
            switch self {
            case .nineRouter: return "~/.9router/db/data.sqlite"
            case .ccSwitch: return "~/.cc-switch/cc-switch.db"
            case .cpamp: return "~/.cli-proxy-api/*.json"
            }
        }
    }

    enum RowState: Equatable {
        case addable        // 可新增
        case exists         // 已存在
        case unsupported    // 不支持
        case unadapted      // 额度未适配

        var text: String {
            switch self {
            case .addable: return "可新增"
            case .exists: return "已存在"
            case .unsupported: return "不支持"
            case .unadapted: return "额度未适配"
            }
        }
        var pickable: Bool {
            self == .addable || self == .unadapted
        }
    }

    struct Row: Identifiable {
        let id = UUID()
        let candidate: ImportCandidate
        var state: RowState
        var note: String
        var imported = false
        var failure: String?
    }

    enum ScanState: Equatable {
        case idle
        case scanning
        case scanned
        case timedOut
        case failed(String)
        case empty
    }

    @Published var source: Source = .nineRouter
    @Published var scanState: ScanState = .idle
    @Published var rows: [Row] = []
    @Published var picked: Set<UUID> = []
    @Published var importing = false
    @Published var lastMessage = ""

    let engine: DataEngine
    let hudDir: URL
    let userDir: URL

    init(engine: DataEngine, hudDir: URL, userDir: URL) {
        self.engine = engine
        self.hudDir = hudDir
        self.userDir = userDir
    }

    /// 切换源: 清空结果并重新扫描
    func switchTo(_ s: Source) {
        guard s != source || scanState == .idle else { return }
        source = s
        rows = []; picked = []; lastMessage = ""
        scanState = .idle
        scan()
    }

    /// 离屏渲染专用: 同步扫描 (真实数据源, 无超时)
    func scanSynchronously() {
        let home = NSHomeDirectory()
        let list: [ImportCandidate]
        switch source {
        case .nineRouter: list = ProviderImporter.from9Router(home: home)
        case .ccSwitch: list = ProviderImporter.fromCCSwitch(home: home)
        case .cpamp: list = ProviderImporter.fromCPAMP(home: home)
        }
        apply(list)
    }

    func scan() {
        guard scanState != .scanning else { return }
        scanState = .scanning
        rows = []; picked = []
        let src = source
        let home = NSHomeDirectory()
        // 可取消 + 超时: 错误/超时不得等同于"空结果"
        Task { [weak self] in
            let result = await Self.scanWithTimeout(src: src, home: home, seconds: 8)
            guard let self else { return }
            guard self.source == src else { return }
            switch result {
            case .success(let list):
                self.apply(list)
            case .failure(.timeout):
                self.scanState = .timedOut
                self.lastMessage = "扫描超时（8 秒）。源可能被占用，可稍后重试。"
            case .failure(.error(let msg)):
                self.scanState = .failed(msg)
                self.lastMessage = "扫描失败：\(msg)"
            }
        }
    }

    private enum ScanError: Error {
        case timeout
        case error(String)
    }

    private nonisolated static func scanWithTimeout(src: Source, home: String,
                                                    seconds: Double) async -> Result<[ImportCandidate], ScanError> {
        await withTaskGroup(of: Result<[ImportCandidate], ScanError>?.self) { group in
            group.addTask {
                await withCheckedContinuation { cont in
                    DispatchQueue.global(qos: .userInitiated).async {
                        let list: [ImportCandidate]
                        switch src {
                        case .nineRouter: list = ProviderImporter.from9Router(home: home)
                        case .ccSwitch: list = ProviderImporter.fromCCSwitch(home: home)
                        case .cpamp: list = ProviderImporter.fromCPAMP(home: home)
                        }
                        cont.resume(returning: .success(list))
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return .failure(.timeout)
            }
            defer { group.cancelAll() }
            for await r in group {
                if let r { return r }
            }
            return .failure(.timeout)
        }
    }

    private func apply(_ list: [ImportCandidate]) {
        let existing = engine.allPlugins
        rows = list.map { c in
            let state = stateOf(c, existing: existing)
            return Row(candidate: c, state: state, note: noteOf(c, state: state))
        }
        picked = Set(rows.filter { $0.state.pickable }.map(\.id))
        scanState = rows.isEmpty ? .empty : .scanned
        lastMessage = rows.isEmpty ? "该源没有可导入的账号（未安装、未登录，或凭证格式不支持）。" : ""
    }

    private func stateOf(_ c: ImportCandidate, existing: [PluginProvider]) -> RowState {
        let duplicated = existing.contains { p in
            (c.template != nil && p.manifest.template == c.template
                && p.manifest.fullName == c.name)
                || (p.manifest.fullName == c.name)
        }
        if duplicated { return .exists }
        if c.apiKey.isEmpty && c.template == nil { return .unsupported }
        if c.template == nil { return .unadapted }
        if let t = c.template, let tmpl = engine.template(bySlug: t), tmpl.manifest.queryUrl == nil {
            return .unadapted
        }
        return .addable
    }

    private func noteOf(_ c: ImportCandidate, state: RowState) -> String {
        switch state {
        case .exists: return "已存在（同名账号），默认跳过，不覆盖 Key"
        case .unsupported: return "缺少凭证且无通用调用协议，无法导入"
        case .unadapted: return "额度查询未适配，可导入后手动调用"
        case .addable: return c.note
        }
    }

    var selectedCount: Int { rows.filter { picked.contains($0.id) && !$0.imported }.count }

    var failedRows: [Row] { rows.filter { $0.failure != nil } }

    func toggle(_ row: Row) {
        guard row.state.pickable, !row.imported else { return }
        if picked.contains(row.id) { picked.remove(row.id) } else { picked.insert(row.id) }
    }

    func toggleAll() {
        let pickable = rows.filter { $0.state.pickable && !$0.imported }
        if pickable.allSatisfy({ picked.contains($0.id) }) {
            pickable.forEach { picked.remove($0.id) }
        } else {
            pickable.forEach { picked.insert($0.id) }
        }
    }

    func importSelected() {
        let chosen = rows.indices.filter { picked.contains(rows[$0].id) && !rows[$0].imported }
        guard !chosen.isEmpty else {
            lastMessage = "请先勾选要导入的账号"
            return
        }
        importing = true
        var ok = 0, fail = 0
        for i in chosen {
            let c = rows[i].candidate
            do {
                try ProviderImporter.apply(c, templates: engine.templates, userDir: userDir, hudDir: hudDir)
                rows[i].imported = true
                rows[i].failure = nil
                rows[i].note = "已导入"
                if rows[i].state == .unadapted { rows[i].state = .unadapted }
                picked.remove(rows[i].id)
                ok += 1
            } catch {
                rows[i].failure = error.localizedDescription
                fail += 1
            }
        }
        engine.reloadRegistry()
        importing = false
        lastMessage = fail == 0
            ? "导入完成：\(ok) 个账号已加入列表。"
            : "部分失败：成功 \(ok) 个，失败 \(fail) 个。失败项已保留勾选，可重试；已成功的不再重复导入。"
        picked = Set(rows.filter { $0.failure != nil }.map(\.id))
    }
}

struct ImportCenterSheet: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var engine: DataEngine
    /// 离屏渲染时由外部持有 (sheet 在离屏窗口里不会弹出)
    @ObservedObject var im: ImportCenterModel
    @Environment(\.dismiss) private var dismiss

    init(model: SettingsModel, engine: DataEngine, im: ImportCenterModel) {
        self.model = model
        self.engine = engine
        _im = ObservedObject(wrappedValue: im)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(Palette.border).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    sourcePicker
                    bodyContent
                }
                .padding(20)
            }
            Rectangle().fill(Palette.border).frame(height: 1)
            footer
        }
        .frame(minWidth: 560, idealWidth: 720, minHeight: 380, idealHeight: 520)
        .background(Palette.surface)
        .onAppear { if im.scanState == .idle { im.scan() } }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("导入账号").font(Typo.section).foregroundStyle(Palette.ink)
                Text("从本机其他工具扫描已有配置，只读源数据，不修改对方文件。")
                    .font(Typo.small).foregroundStyle(Palette.muted)
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.muted)
            .accessibilityLabel("关闭导入")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var sourcePicker: some View {
        HStack(spacing: 4) {
            ForEach(ImportCenterModel.Source.allCases) { s in
                Button { im.switchTo(s) } label: {
                    Text(s.label).font(Typo.small)
                        .foregroundStyle(im.source == s ? Palette.accent : Palette.muted)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 28)
                        .background(Capsule().fill(im.source == s ? Palette.accentSoft : Palette.surface))
                        .overlay(Capsule().strokeBorder(im.source == s ? Palette.accent : Palette.border, lineWidth: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var bodyContent: some View {
        switch im.scanState {
        case .idle, .scanning:
            ResultBox(kind: .info, title: "正在扫描…", detail: "来源 \(im.source.path)，不会读取之外的任何文件。")
        case .timedOut:
            ResultBox(kind: .error, title: "扫描超时", detail: "8 秒内未返回。源可能被其他进程占用，可重试。")
        case .failed(let msg):
            ResultBox(kind: .error, title: "扫描失败", detail: msg)
        case .empty:
            ResultBox(kind: .neutral, title: "此源无可导入项",
                      detail: "可能未安装、未登录，或凭证格式不支持。空结果与扫描失败不同。")
        case .scanned:
            previewTable
        }
        sourceBox
    }

    private var previewTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("").frame(width: 22)
                Text("名称").frame(maxWidth: .infinity, alignment: .leading)
                Text("授权方式").frame(width: 88, alignment: .leading)
                Text("额度适配").frame(width: 78, alignment: .leading)
                Text("状态").frame(width: 78, alignment: .leading)
            }
            .font(Typo.small).foregroundStyle(Palette.muted)
            .padding(.vertical, 6)
            .overlay(alignment: .bottom) { Rectangle().fill(Palette.border).frame(height: 1) }

            ForEach(im.rows) { row in
                HStack(alignment: .top, spacing: 8) {
                    Button { im.toggle(row) } label: {
                        Image(systemName: row.imported ? "checkmark.square.fill"
                              : (im.picked.contains(row.id) ? "checkmark.square" : "square"))
                            .font(.system(size: 13))
                            .foregroundStyle(row.imported ? Palette.ok
                                             : (row.state.pickable ? Palette.accent : Palette.muted.opacity(0.4)))
                    }
                    .buttonStyle(.plain)
                    .disabled(!row.state.pickable || row.imported)
                    .frame(width: 22)
                    .accessibilityLabel("选择 \(row.candidate.name)")

                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.candidate.name).font(Typo.small)
                            .foregroundStyle(row.imported ? Palette.muted : Palette.ink)
                            .strikethrough(row.imported)
                        Text(row.note).font(Typo.small)
                            .foregroundStyle(row.failure != nil ? Palette.danger : Palette.muted)
                        if let f = row.failure {
                            Text("失败：\(f)").font(Typo.small).foregroundStyle(Palette.danger)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Text(row.candidate.template == nil ? "API Key" : "API Key")
                        .font(Typo.small).foregroundStyle(Palette.muted)
                        .frame(width: 88, alignment: .leading)
                    Text(row.candidate.template != nil ? "已适配" : "未适配")
                        .font(Typo.small)
                        .foregroundStyle(row.candidate.template != nil ? Palette.ok : Palette.warn)
                        .frame(width: 78, alignment: .leading)
                    Text(row.imported ? "已导入" : row.state.text)
                        .font(Typo.small)
                        .foregroundStyle(stateColor(row))
                        .frame(width: 78, alignment: .leading)
                }
                .padding(.vertical, 7)
                .overlay(alignment: .bottom) { Rectangle().fill(Palette.border).frame(height: 1) }
            }
        }
    }

    private func stateColor(_ row: ImportModelRow) -> Color {
        if row.imported { return Palette.ok }
        if row.failure != nil { return Palette.danger }
        switch row.state {
        case .addable: return Palette.ok
        case .exists: return Palette.muted
        case .unsupported: return Palette.danger
        case .unadapted: return Palette.warn
        }
    }

    private var sourceBox: some View {
        HStack(spacing: 12) {
            Text("源路径").font(Typo.small).foregroundStyle(Palette.muted)
            Text(im.source.path).font(Typo.mono).foregroundStyle(Palette.ink)
            BadgeText(text: "只读 · 不修改", locked: true)
            Spacer()
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Palette.readonlyField))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.border, lineWidth: 1))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if !im.lastMessage.isEmpty {
                Text(im.lastMessage).font(Typo.small)
                    .foregroundStyle(im.failedRows.isEmpty ? Palette.muted : Palette.danger)
                    .lineLimit(2)
            } else {
                Text(scanStatusText).font(Typo.small).foregroundStyle(Palette.muted)
            }
            Spacer()
            Button("扫描") { im.scan() }
                .barButton()
                .disabled(im.scanState == .scanning)
            if im.scanState == .scanned || !im.rows.isEmpty {
                Button("全选可导入") { im.toggleAll() }.barButton()
            }
            Button("关闭") { dismiss() }.barButton()
                .keyboardShortcut(.cancelAction)
            Button(importTitle) { im.importSelected() }
                .barButton(.primary)
                .disabled(im.selectedCount == 0 || im.importing)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Palette.badgeBg)
    }

    private var importTitle: String {
        if im.importing { return "导入中…" }
        if !im.failedRows.isEmpty { return "重试失败项" }
        return im.selectedCount > 0 ? "导入所选（\(im.selectedCount)）" : "导入所选"
    }

    private var scanStatusText: String {
        switch im.scanState {
        case .idle: return "尚未扫描"
        case .scanning: return "扫描中…"
        case .scanned: return "\(im.rows.count) 项 · \(im.selectedCount) 项已勾选"
        case .empty: return "无结果"
        case .timedOut: return "扫描超时"
        case .failed: return "扫描失败"
        }
    }
}

private typealias ImportModelRow = ImportCenterModel.Row
