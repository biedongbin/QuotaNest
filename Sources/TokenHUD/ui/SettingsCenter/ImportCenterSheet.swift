import SwiftUI
import AppKit

// MARK: - 导入 sheet (源 → 扫描 → 预览 → 导入所选 → 逐项结果/重试)

@MainActor
final class ImportCenterModel: ObservableObject {
    enum Source: String, CaseIterable, Identifiable {
        case nineRouter, ccSwitch, cpamp, magpie
        var id: String { rawValue }
        var label: String {
            switch self {
            case .nineRouter: return "9router"
            case .ccSwitch: return "cc-switch"
            case .cpamp: return "CPAMP"
            case .magpie: return "Magpie"
            }
        }
        var path: String {
            switch self {
            case .nineRouter: return "~/.9router/db/data.sqlite"
            case .ccSwitch: return "~/.cc-switch/cc-switch.db"
            case .cpamp: return "~/.cli-proxy-api/*.json"
            case .magpie: return ProviderImporter.magpieRoot(home: NSHomeDirectory())
            }
        }
    }

    enum RowState: Equatable {
        case addable        // 可新增
        case convertible    // 旧导入账号可转换为只读来源引用
        case exists         // 已存在
        case duplicate      // 同一授权主体和 workspace 已存在
        case unsupported    // 不支持
        case unadapted      // 额度未适配

        var text: String {
            switch self {
            case .addable: return L10n.tr("可新增")
            case .convertible: return L10n.tr("可转换")
            case .exists: return L10n.tr("已存在")
            case .duplicate: return L10n.tr("同账号已存在")
            case .unsupported: return L10n.tr("不支持")
            case .unadapted: return L10n.tr("额度未适配")
            }
        }
        var pickable: Bool {
            self == .addable || self == .convertible
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
    private var existingAccountIdentities: [String: String] = [:]
    @Published var magpieDirectory = ""
    var sourcePath: String { source == .magpie && !magpieDirectory.isEmpty ? magpieDirectory : source.path }

    func chooseMagpieDirectory() {
        guard !importing else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = L10n.tr("选择 Magpie 配置目录（包含 providers.json 或 plugin-auth.json），支持 portable data 目录")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        magpieDirectory = url.path
        scanGeneration = UUID()
        scanState = .idle
        scan()
    }

    func resetMagpieDirectory() {
        guard !importing else { return }
        magpieDirectory = ""
        scanGeneration = UUID()
        scanState = .idle
        scan()
    }
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

    /// This model survives sheet dismissal; previous imported/existing flags must not survive reopening.
    func prepareForPresentation() {
        guard !importing else { return }
        engine.reloadRegistry()
        scanState = .idle
        lastMessage = ""
        scan() // Starts a new generation, discarding any previous scan's late result.
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
        case .nineRouter: list = ProviderImporter.from9Router(home: home, templates: engine.templates)
        case .ccSwitch: list = ProviderImporter.fromCCSwitch(home: home, templates: engine.templates)
        case .cpamp: list = ProviderImporter.fromCPAMP(home: home, templates: engine.templates)
        case .magpie: list = ProviderImporter.fromMagpie(home: home,
            sourceDirectory: magpieDirectory.isEmpty ? nil : magpieDirectory, templates: engine.templates)
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
        let directory = magpieDirectory.isEmpty ? nil : magpieDirectory
        let templates = engine.templates
        // 可取消 + 超时: 错误/超时不得等同于"空结果"
        Task { [weak self] in
            let result = await Self.scanWithTimeout(src: src, home: home, directory: directory,
                                                     templates: templates, seconds: 8)
            guard let self else { return }
            guard self.source == src, self.scanGeneration == generation else { return }
            switch result {
            case .success(let list):
                self.apply(list)
            case .failure(.timeout):
                self.scanState = .timedOut
                self.lastMessage = L10n.tr("扫描超时（8 秒）。源可能被占用，可稍后重试。")
            case .failure(.error(let msg)):
                self.scanState = .failed(msg)
                self.lastMessage = L10n.tr("扫描失败：%@", String(describing: msg))
            }
        }
    }

    private enum ScanError: Error {
        case timeout
        case error(String)
    }

    private nonisolated static func scanWithTimeout(src: Source, home: String, directory: String?,
                                                    templates: [PluginProvider], seconds: Double) async -> Result<[ImportCandidate], ScanError> {
        await withTaskGroup(of: Result<[ImportCandidate], ScanError>?.self) { group in
            group.addTask {
                await withCheckedContinuation { cont in
                    DispatchQueue.global(qos: .userInitiated).async {
                        let list: [ImportCandidate]
                        switch src {
                        case .nineRouter: list = ProviderImporter.from9Router(home: home, templates: templates)
                        case .ccSwitch: list = ProviderImporter.fromCCSwitch(home: home, templates: templates)
                        case .cpamp: list = ProviderImporter.fromCPAMP(home: home, templates: templates)
                        case .magpie: list = ProviderImporter.fromMagpie(home: home,
                            sourceDirectory: directory, templates: templates)
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
        existingAccountIdentities = ProviderAccountIdentity.index(providers: existing, templates: engine.templates)
        var seen = Set<String>()
        rows = list
            .map { c in
                var state = stateOf(c, existing: existing)
                if state.pickable, let identity = c.accountIdentity, !seen.insert(identity).inserted { state = .duplicate }
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
        lastMessage = rows.isEmpty ? L10n.tr("该源没有可导入的账号（未安装、未登录，或凭证格式不支持）。") : ""
    }

    /// 排序档: 可导入且启用 → 可导入但源端停用 → 已存在 → 不支持
    private func rank(_ row: Row) -> Int {
        switch row.state {
        case .unsupported: return 3
        case .exists, .duplicate: return 2
        case .addable, .unadapted, .convertible: return row.candidate.enabled ? 0 : 1
        }
    }

    private func stateOf(_ c: ImportCandidate, existing: [PluginProvider]) -> RowState {
        Self.stateOf(c, existing: existing, accountIdentities: existingAccountIdentities, templateLookup: { [engine] s in engine.template(bySlug: s)?.manifest })
    }

    /// Pure preview decision: exact source records or verified cross-source account identity; never display names.
    nonisolated static func stateOf(_ c: ImportCandidate, existing: [PluginProvider],
                        accountIdentities: [String: String] = [:], templateLookup: (String) -> ProviderManifest?) -> RowState {
        if c.unsupportedReason != nil { return .unsupported }
        guard let reference = c.sourceReference else { return .unsupported }
        if existing.contains(where: { ProviderImporter.sameSourceAccount(c, manifest: $0.manifest, templateLookup: templateLookup) }) { return .exists }
        if let identity = c.accountIdentity, accountIdentities.values.contains(identity) { return .duplicate }
        let legacy = existing.filter { $0.manifest.sourceReference == nil && ProviderImporter.matchesExisting(c, manifest: $0.manifest) }
        if legacy.count > 1 { return .unsupported }
        guard quotaAdapted(c, templateLookup: templateLookup) else { return .unadapted }
        if legacy.count == 1 { return .convertible }
        return .addable
    }

    /// Adapter capability and this source record's importability are separate facts.
    nonisolated static func quotaAdapted(_ candidate: ImportCandidate,
                                        templateLookup: (String) -> ProviderManifest?) -> Bool {
        guard let slug = candidate.template, let manifest = templateLookup(slug), manifest.supportsQuota else { return false }
        if let modes = manifest.quotaAuthModes, !modes.contains(candidate.sourceAuthMode) { return false }
        if candidate.sourceAuthMode == "auth" && manifest.credentialSource == nil { return false }
        return !(["jwt", "cookie"].contains(manifest.queryAuth ?? "") && manifest.inheritQueryUrl == nil)
    }

    func quotaAdapted(_ candidate: ImportCandidate) -> Bool {
        Self.quotaAdapted(candidate, templateLookup: { [engine] in engine.template(bySlug: $0)?.manifest })
    }

    private func noteOf(_ a: ImportCandidate, state: RowState) -> String {
        var note: String
        switch state {
        case .exists: note = L10n.tr("已存在（同源同账号），默认跳过，不覆盖现有配置")
        case .duplicate: note = L10n.tr("同一账号和 workspace 已存在，默认跳过，不覆盖名称、计划或来源绑定")
        case .convertible: note = L10n.tr("转换为源引用：保留原账号，清除本地旧凭据与缓存，今后随源更新")
        case .unsupported:
            if let reason = a.unsupportedReason { note = L10n.tr(reason) }
            else if a.sourceReference == nil { note = L10n.tr("缺少有效来源引用，无法导入") }
            else { note = L10n.tr("来源记录存在冲突或无法唯一关联，无法导入") }
        case .unadapted:
            note = L10n.tr("该类型未提供适用于当前认证方式的额度查询适配，不能选择导入")
        case .addable:
            note = a.enabled ? a.note : L10n.tr("在源工具中已停用，可手动勾选导入 · %@", String(describing: a.note))
        }
        if !a.note.isEmpty && !note.contains(a.note) { note += " · " + a.note }
        if !a.sourceAccount.isEmpty { note += L10n.tr(" · 源账号 %@", String(describing: a.sourceAccount)) }
        return note
    }

    func noteForDisplay(_ row: Row) -> String {
        row.imported ? L10n.tr("已导入") : noteOf(row.candidate, state: row.state)
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
            lastMessage = L10n.tr("请先勾选要导入的账号")
            return
        }
        importing = true
        lastMessage = L10n.tr("导入中…可取消尚未开始的项目。")
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
                engine.markHUDExportNeeded()
                rows[index].imported = true
                rows[index].failure = nil
                rows[index].note = L10n.tr("已导入")
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
            lastMessage = L10n.tr("已取消：%@ 个成功项保留，%@ 个未开始，可重新勾选重试。", String(describing: ok), String(describing: skipped))
            picked.formUnion(rows.filter { $0.failure == "已取消" }.map(\.id))
        } else if fail == 0 {
            lastMessage = L10n.tr("导入完成：%@ 个账号已加入列表。", String(describing: ok))
        } else {
            lastMessage = L10n.tr("成功 %@ 个，失败 %@ 个；失败项可重试。", String(describing: ok), String(describing: fail))
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
                LazyVStack(alignment: .leading, spacing: 12, pinnedViews: [.sectionHeaders]) {
                    SourceSyncControls(engine: engine).disabled(im.importing)
                    sourcePicker.disabled(im.importing)
                    if im.scanState == .scanned {
                        Section {
                            previewTable
                        } header: {
                            previewHeader
                        }
                    } else {
                        bodyContent
                    }
                    sourceBox
                }
                .padding(20)
            }
            Rectangle().fill(Palette.border).frame(height: 1)
            footer
        }
        .frame(minWidth: 560, idealWidth: 720, minHeight: 380, idealHeight: 520)
        .background(Palette.surface)
        .onAppear { im.prepareForPresentation() }
        .onDisappear { im.cancelImport() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.tr("导入账号")).font(Typo.section).foregroundStyle(Palette.ink)
                Text(L10n.tr("只读引用本机来源，不复制 Key 或 Token；旧导入可转换为源引用，无需手动删除配置。"))
                    .font(Typo.small).foregroundStyle(Palette.muted)
            }
            Spacer()
            Button { openFeedback() } label: {
                Label(L10n.tr("反馈导入问题"), systemImage: "bubble.left")
            }.barButton().accessibilityIdentifier("feedback.import-entry")
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.muted)
            .accessibilityLabel(L10n.tr("关闭导入"))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private func openFeedback() {
        let source = FeedbackSource(rawValue: im.source.rawValue)
        let failures = im.rows.filter { $0.failure != nil }.count
        let stage: FeedbackStage = im.importing || im.rows.contains(where: { $0.imported || $0.failure != nil }) ? .importApply : .scan
        let error: SafeDiagnosticEvent.ErrorCode
        switch im.scanState {
        case .timedOut: error = .network
        case .failed: error = .other
        default: error = failures > 0 ? .other : .none
        }
        let counts = FeedbackCounts(candidates: im.rows.count, imported: im.rows.filter(\.imported).count,
                                    skipped: im.rows.filter { !$0.state.pickable && !$0.imported }.count, failed: failures)
        FeedbackWindowManager.shared.show(context: .init(area: .accountImport, source: source, stage: stage),
            counts: counts, events: [.init(stage: stage, source: source, errorCode: error, count: failures)])
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
            ResultBox(kind: .info, title: L10n.tr("正在扫描…"), detail: L10n.tr("正在只读扫描 %@ 中的账号引用。", String(describing: im.sourcePath)))
        case .timedOut:
            ResultBox(kind: .error, title: L10n.tr("扫描超时"), detail: L10n.tr("8 秒内未返回。源可能被其他进程占用，可重试。"))
        case .failed(let msg):
            ResultBox(kind: .error, title: L10n.tr("扫描失败"), detail: msg)
        case .empty:
            ResultBox(kind: .neutral, title: L10n.tr("此源无可导入项"),
                      detail: L10n.tr("可能未安装、未登录，或凭证格式不支持。空结果与扫描失败不同。"))
        case .scanned:
            EmptyView()
        }
    }

    private var previewHeader: some View {
        HStack(spacing: 8) {
            Text("").frame(width: 22)
            Text(L10n.tr("名称")).frame(maxWidth: .infinity, alignment: .leading)
            Text(L10n.tr("授权方式")).frame(width: 88, alignment: .leading)
            Text(L10n.tr("额度适配")).frame(width: 78, alignment: .leading)
                .help(L10n.tr("该供应商类型是否已提供适用于此认证方式的额度查询适配；不代表这条来源记录可导入或已经在线验证"))
            Text(L10n.tr("导入状态")).frame(width: 78, alignment: .leading)
                .help(L10n.tr("综合检查来源引用、认证格式、重复或冲突后，决定这条记录是否可导入；具体原因见名称下方"))
        }
        .font(Typo.small).foregroundStyle(Palette.muted)
        .padding(.vertical, 9)
        .background(Palette.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.border).frame(height: 1) }
        .accessibilityIdentifier("import.column-header")
    }

    private var previewTable: some View {
        VStack(spacing: 0) {
            ForEach(im.rows) { row in
                let unavailable = !row.state.pickable && !row.imported
                let adapted = im.quotaAdapted(row.candidate)
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
                    .accessibilityLabel(L10n.tr("选择 %@", String(describing: row.candidate.name)))

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            ProviderLogo(template: row.candidate.template, size: 15)
                            Text(row.candidate.name).font(Typo.small)
                                .foregroundStyle(row.imported || unavailable ? Palette.muted : Palette.ink)
                                .strikethrough(row.imported)
                        }
                        Text("\(row.candidate.source) · provider: \(row.candidate.sourceReference?.providerId ?? "—") · record: \(row.candidate.sourceRecordId)")
                            .font(Typo.mono).foregroundStyle(Palette.muted).textSelection(.enabled)
                        Text(im.noteForDisplay(row)).font(Typo.small)
                            .foregroundStyle(row.failure != nil ? Palette.danger : Palette.muted)
                        if let f = row.failure {
                            Text(L10n.tr("失败：%@", String(describing: f == "已取消" ? L10n.tr("已取消") : f))).font(Typo.small).foregroundStyle(Palette.danger)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Text(row.candidate.authLabel)
                        .font(Typo.small).foregroundStyle(Palette.muted)
                        .frame(width: 88, alignment: .leading)
                    Text(adapted ? L10n.tr("已适配") : L10n.tr("未适配"))
                        .font(Typo.small)
                        .foregroundStyle(unavailable ? Palette.muted : (adapted ? Palette.ok : Palette.warn))
                        .frame(width: 78, alignment: .leading)
                    Text(row.imported ? L10n.tr("已导入") : row.state.text)
                        .font(Typo.small)
                        .foregroundStyle(stateColor(row))
                        .frame(width: 78, alignment: .leading)
                }
                .padding(.vertical, 7)
                .opacity(unavailable ? 0.65 : 1)
                .help(unavailable ? im.noteForDisplay(row) : "")
                .overlay(alignment: .bottom) { Rectangle().fill(Palette.border).frame(height: 1) }
            }
        }
    }

    private func stateColor(_ row: ImportModelRow) -> Color {
        if row.imported { return Palette.ok }
        if row.failure != nil { return Palette.danger }
        if !row.state.pickable { return Palette.muted }
        switch row.state {
        case .addable, .convertible: return Palette.ok
        case .exists, .duplicate: return Palette.muted
        case .unsupported: return Palette.danger
        case .unadapted: return Palette.warn
        }
    }

    private var sourceBox: some View {
        HStack(spacing: 12) {
            Text(L10n.tr("源路径")).font(Typo.small).foregroundStyle(Palette.muted)
            Text(im.sourcePath).font(Typo.mono).foregroundStyle(Palette.ink).textSelection(.enabled)
            if im.source == .magpie {
                Button(L10n.tr("选择目录…")) { im.chooseMagpieDirectory() }.disabled(im.importing)
                if !im.magpieDirectory.isEmpty {
                    Button(L10n.tr("默认路径")) { im.resetMagpieDirectory() }.disabled(im.importing)
                }
            }
            BadgeText(text: L10n.tr("只读引用"), locked: true)
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
            Button(L10n.tr("扫描")) { im.scan() }
                .barButton()
                .disabled(im.scanState == .scanning || im.importing)
            if im.scanState == .scanned || !im.rows.isEmpty {
                Button(L10n.tr("全选可导入")) { im.toggleAll() }.barButton().disabled(im.importing)
            }
            Button(L10n.tr("关闭")) { dismiss() }.barButton()
                .keyboardShortcut(.cancelAction)
            Button(importTitle) { im.importSelected() }
                .barButton(.primary)
                .disabled(im.selectedCount == 0 || im.importing)
                .keyboardShortcut(.defaultAction)
            if im.importing {
                Button(L10n.tr("取消导入")) { im.cancelImport() }.barButton()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Palette.badgeBg)
    }

    private var importTitle: String {
        if im.importing { return L10n.tr("导入中…") }
        if !im.failedRows.isEmpty { return L10n.tr("重试失败项") }
        return im.selectedCount > 0 ? L10n.tr("导入所选（%@）", String(describing: im.selectedCount)) : L10n.tr("导入所选")
    }

    private var scanStatusText: String {
        switch im.scanState {
        case .idle: return L10n.tr("尚未扫描")
        case .scanning: return L10n.tr("扫描中…")
        case .scanned:
            let ready = im.rows.filter { $0.state.pickable && $0.candidate.enabled && !$0.imported }.count
            return L10n.tr("%@ 项 · %@ 项可直接导入 · %@ 项已勾选", String(describing: im.rows.count), String(describing: ready), String(describing: im.selectedCount))
        case .empty: return L10n.tr("无结果")
        case .timedOut: return L10n.tr("扫描超时")
        case .failed: return L10n.tr("扫描失败")
        }
    }
}

private typealias ImportModelRow = ImportCenterModel.Row
