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
    /// P1-7: 导入循环后台 Task 句柄 (可取消: 已成功项保留, 未开始项标 skipped)
    private var importTask: Task<Void, Never>?
    private var scanGeneration = UUID()

    let engine: DataEngine
    let hudDir: URL
    let userDir: URL

    init(engine: DataEngine, hudDir: URL, userDir: URL) {
        self.engine = engine
        self.hudDir = hudDir
        self.userDir = userDir
    }

    /// P1-7: 取消进行中的导入 (已成功项保留, 未开始项标 skipped)
    func cancelImport() {
        guard importing, let task = importTask, !task.isCancelled else { return }
        task.cancel()
    }

    /// 切换源: 清空结果并重新扫描
    func switchTo(_ s: Source) {
        guard !importing, s != source || scanState == .idle else { return }
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
        guard !importing, scanState != .scanning else { return }
        let generation = UUID()
        scanGeneration = generation
        scanState = .scanning
        rows = []; picked = []
        let src = source
        let home = NSHomeDirectory()
        // 可取消 + 超时: 错误/超时不得等同于"空结果"
        Task { [weak self] in
            let result = await Self.scanWithTimeout(src: src, home: home, seconds: 8)
            guard let self else { return }
            guard self.source == src, self.scanGeneration == generation else { return }
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
        rows = list
            .map { c in
                let state = stateOf(c, existing: existing)
                return Row(candidate: c, state: state, note: noteOf(c, state: state))
            }
            // 能导的排前面, 免得滑一屏找不到; 同档内保持源顺序
            .enumerated()
            .sorted { a, b in
                let ra = rank(a.element), rb = rank(b.element)
                return ra == rb ? a.offset < b.offset : ra < rb
            }
            .map(\.element)
        // 源里停用的账号仍可导入, 只是默认不勾, 免得不看预览就整批带进来
        picked = Set(rows.filter { $0.state.pickable && $0.candidate.enabled }.map(\.id))
        scanState = rows.isEmpty ? .empty : .scanned
        lastMessage = rows.isEmpty ? "该源没有可导入的账号（未安装、未登录，或凭证格式不支持）。" : ""
    }

    /// 排序档: 可导入且启用 → 可导入但源端停用 → 已存在 → 不支持
    private func rank(_ row: Row) -> Int {
        switch row.state {
        case .unsupported: return 3
        case .exists: return 2
        case .addable, .unadapted: return row.candidate.enabled ? 0 : 1
        }
    }

    private func stateOf(_ c: ImportCandidate, existing: [PluginProvider]) -> RowState {
        Self.stateOf(c, existing: existing, templateLookup: { [engine] s in engine.template(bySlug: s)?.manifest })
    }

    /// 去重判定 (纯函数, 可测): origin 匹配才算已存在, 显示名匹配不算 (FR-07.5)
    nonisolated static func stateOf(_ c: ImportCandidate, existing: [PluginProvider],
                        templateLookup: (String) -> ProviderManifest?) -> RowState {
        if c.unsupportedReason != nil { return .unsupported }
        // 去重按 origin (source+sourceRecordId): 同源同记录才算已存在; 显示名相同不算 (FR-07.5)
        if !c.sourceRecordId.isEmpty,
           existing.contains(where: { $0.manifest.origin == c.origin }) { return .exists }
        if c.apiKey.isEmpty && c.template == nil { return .unsupported }
        if c.template == nil { return .unadapted }
        // 与 AccountRow.canQuery 同口径: 脚本型模板只声明 cacheFile 也算能查额度
        if let t = c.template, let tmpl = templateLookup(t),
           tmpl.queryUrl == nil, tmpl.cacheFile == nil {
            return .unadapted
        }
        return .addable
    }

    private func noteOf(_ a: ImportCandidate, state: RowState) -> String {
        var note: String
        switch state {
        case .exists: note = "已存在（同源同账号），默认跳过，不覆盖 Key"
        case .unsupported: note = a.unsupportedReason ?? "缺少凭证且无通用调用协议，无法导入"
        case .unadapted:
            note = a.enabled ? "导入后可手动调用，额度查询需自行适配"
                             : "在源工具中已停用，可手动勾选导入；导入后可手动调用，额度查询需自行适配"
        case .addable:
            note = a.enabled ? a.note : "在源工具中已停用，可手动勾选导入 · \(a.note)"
        }
        if !a.sourceAccount.isEmpty { note += " · 源账号 \(a.sourceAccount)" }
        return note
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

    /// P1-7: 导入循环移后台 Task (不冻 UI); 中途取消 → 已成功项保留, 未开始项标 skipped
    func importSelected() {
        guard !importing else { return }
        let chosen = rows.filter { picked.contains($0.id) && !$0.imported && $0.state.pickable }
            .map { ($0.id, $0.candidate) }
        guard !chosen.isEmpty else {
            lastMessage = "请先勾选要导入的账号"
            return
        }
        importing = true
        lastMessage = "导入中…可取消尚未开始的项目。"
        importTask = Task { [weak self] in await self?.runImport(chosen) }
    }

    private func runImport(_ chosen: [(UUID, ImportCandidate)]) async {
        var ok = 0, fail = 0, skipped = 0
        for (id, candidate) in chosen {
            if Task.isCancelled {
                if let index = rows.firstIndex(where: { $0.id == id }) { rows[index].failure = "已取消" }
                skipped += 1
                continue
            }
            let templates = engine.templates
            let result = await Task.detached(priority: .userInitiated) { [templates, userDir, hudDir] in
                Result { try ProviderImporter.apply(candidate, templates: templates, userDir: userDir, hudDir: hudDir) }
            }.value
            // The result belongs to this immutable row ID, never a pre-await index.
            guard let index = rows.firstIndex(where: { $0.id == id }) else { continue }
            switch result {
            case .success:
                rows[index].imported = true
                rows[index].failure = nil
                rows[index].note = "已导入"
                picked.remove(id)
                ok += 1
            case .failure(let error):
                rows[index].failure = error.localizedDescription
                fail += 1
            }
        }
        engine.reloadRegistry()
        importing = false
        importTask = nil
        if skipped > 0 {
            lastMessage = "已取消：\(ok) 个成功项保留，\(skipped) 个未开始，可重新勾选重试。"
            picked.formUnion(rows.filter { $0.failure == "已取消" }.map(\.id))
        } else if fail == 0 {
            lastMessage = "导入完成：\(ok) 个账号已加入列表。"
        } else {
            lastMessage = "成功 \(ok) 个，失败 \(fail) 个；失败项可重试。"
            picked = Set(rows.filter { $0.failure != nil }.map(\.id))
        }
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
                    sourcePicker.disabled(im.importing)
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
        .onDisappear { im.cancelImport() }
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
                    .disabled(!row.state.pickable || row.imported || im.importing)
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

                    Text(row.candidate.authLabel)
                        .font(Typo.small).foregroundStyle(Palette.muted)
                        .frame(width: 88, alignment: .leading)
                    Text(row.candidate.unsupportedReason != nil ? "—"
                         : (row.candidate.template != nil ? "已适配" : "未适配"))
                        .font(Typo.small)
                        .foregroundStyle(row.candidate.unsupportedReason != nil ? Palette.muted
                                         : (row.candidate.template != nil ? Palette.ok : Palette.warn))
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
                .disabled(im.scanState == .scanning || im.importing)
            if im.scanState == .scanned || !im.rows.isEmpty {
                Button("全选可导入") { im.toggleAll() }.barButton().disabled(im.importing)
            }
            Button("关闭") { dismiss() }.barButton()
                .keyboardShortcut(.cancelAction)
            Button(importTitle) { im.importSelected() }
                .barButton(.primary)
                .disabled(im.selectedCount == 0 || im.importing)
                .keyboardShortcut(.defaultAction)
            if im.importing {
                Button("取消导入") { im.cancelImport() }.barButton()
            }
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
        case .scanned:
            let ready = im.rows.filter { $0.state.pickable && $0.candidate.enabled && !$0.imported }.count
            return "\(im.rows.count) 项 · \(ready) 项可直接导入 · \(im.selectedCount) 项已勾选"
        case .empty: return "无结果"
        case .timedOut: return "扫描超时"
        case .failed: return "扫描失败"
        }
    }
}

private typealias ImportModelRow = ImportCenterModel.Row
