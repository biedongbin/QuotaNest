import AppKit
import Combine

@MainActor final class FeedbackCoordinator: ObservableObject {
    @Published var title = ""
    @Published var problem = ""
    @Published var steps = ""
    @Published var acknowledged = false
    @Published private(set) var body: String?
    @Published private(set) var reviewedTitle = ""
    @Published private(set) var isBusy = false
    @Published private(set) var uncertain = false
    @Published private(set) var issueURL: URL?
    @Published private(set) var message: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var tools: FeedbackToolAvailability
    let context: FeedbackContext
    private let counts: FeedbackCounts
    private let events: [SafeDiagnosticEvent]
    private let requestID = UUID()
    private let submission: FeedbackSubmissionService
    private var diagnostics: FeedbackDiagnostics?
    private var task: Task<Void, Never>?
    private var operation: UUID?

    init(context: FeedbackContext, counts: FeedbackCounts = .init(), events: [SafeDiagnosticEvent] = [],
         tools: FeedbackToolAvailability = .discover(), submission: FeedbackSubmissionService = .init()) {
        self.context = context
        self.counts = counts
        self.events = events
        self.tools = tools
        self.submission = submission
    }

    var canSend: Bool { body != nil && acknowledged && !isBusy && !uncertain && issueURL == nil && tools.ghAvailable }
    var canEdit: Bool { !isBusy && !uncertain && issueURL == nil }

    func prepare() {
        guard canEdit else { return }
        message = nil
        errorMessage = nil
        do {
            guard !problem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  title.utf8.count + problem.utf8.count + steps.utf8.count <= 7_800 else { throw FeedbackSubmissionError.invalidDraft }
            let snapshot = FeedbackDiagnostics.snapshot(context: context, counts: counts, tools: tools, safeEvents: events)
            let draft = FeedbackDraft(title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                                      description: problem, steps: steps, diagnostics: snapshot, requestID: requestID)
            let text = try draft.markdown(isEnglish: AppLanguageSettings.shared.selection == .english)
            reviewedTitle = draft.title
            diagnostics = snapshot
            body = text
            acknowledged = false
        } catch { show(error) }
    }

    func edit() {
        guard canEdit else { return }
        body = nil
        acknowledged = false
        message = nil
        errorMessage = nil
    }

    func refreshTools() {
        guard !isBusy && issueURL == nil && !uncertain else { return }
        tools = .discover()
        edit()
    }

    func send() {
        guard canSend, let text = body, let executable = tools.ghPath else { return }
        do { try FeedbackPrivacyGuard.validate(title: reviewedTitle, body: text) }
        catch { show(error); return }
        let identifier = begin()
        let titleSnapshot = reviewedTitle
        task = Task {
            do {
                let url = try await submission.submit(title: titleSnapshot, body: text, requestID: requestID, ghPath: executable)
                guard operation == identifier else { return }
                issueURL = url
                message = L10n.tr("反馈已提交，可打开 GitHub 查看。")
            } catch {
                guard operation == identifier else { return }
                if let failure = error as? FeedbackSubmissionError,
                   [.timedOut, .cancelled, .submissionUnknown].contains(failure) { uncertain = true }
                show(error)
            }
            finish(identifier)
        }
    }

    func reconcile() {
        guard uncertain, !isBusy, let executable = tools.ghPath else { return }
        let identifier = begin()
        task = Task {
            do {
                let url = try await submission.reconcile(requestID: requestID, ghPath: executable)
                guard operation == identifier else { return }
                if let url {
                    issueURL = url
                    uncertain = false
                    message = L10n.tr("反馈已提交，可打开 GitHub 查看。")
                } else { message = L10n.tr("尚未确认提交结果。请检查 GitHub，避免重复提交。") }
            } catch {
                guard operation == identifier else { return }
                show(error)
            }
            finish(identifier)
        }
    }

    @discardableResult func copyDraft() -> Bool {
        guard let text = body else { return false }
        do {
            try FeedbackPrivacyGuard.validate(title: reviewedTitle, body: text)
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.setString("# " + reviewedTitle + "\n\n" + text, forType: .string) else {
                errorMessage = L10n.tr("无法复制草稿，请重试。")
                return false
            }
            errorMessage = nil
            message = L10n.tr("已复制反馈草稿。")
            return true
        } catch { show(error); return false }
    }

    func openBrowser() {
        guard acknowledged, !isBusy, let text = body else { return }
        if uncertain {
            if let url = URL(string: "https://github.com/biedongbin/QuotaNest/issues") { NSWorkspace.shared.open(url) }
            message = L10n.tr("尚未确认提交结果。请检查 GitHub，避免重复提交。")
            return
        }
        do {
            let plan = try FeedbackBrowserFallback.make(title: reviewedTitle, body: text, requestID: requestID)
            if plan.requiresCopy && !copyDraft() { return }
            guard NSWorkspace.shared.open(plan.url) else { throw FeedbackSubmissionError.submissionFailed }
            message = plan.requiresCopy ? L10n.tr("草稿较长，已复制。请在 GitHub 页面粘贴并提交。")
                : L10n.tr("已打开 GitHub 草稿页面，请自行确认提交。")
        } catch { show(error) }
    }

    func cancel() {
        guard isBusy else { return }
        uncertain = true
        operation = nil
        task?.cancel()
        task = nil
        isBusy = false
        message = L10n.tr("操作已取消，草稿已保留。")
    }

    private func begin() -> UUID {
        let identifier = UUID()
        operation = identifier
        isBusy = true
        message = nil
        errorMessage = nil
        return identifier
    }

    private func finish(_ identifier: UUID) {
        guard operation == identifier else { return }
        operation = nil
        isBusy = false
        task = nil
    }

    private func show(_ error: Error) {
        switch error as? FeedbackSubmissionError {
        case .privacyViolation:
            errorMessage = L10n.tr("检测到可能的凭证、邮箱或私人路径，请删除敏感内容后重试。")
        case .invalidDraft:
            errorMessage = L10n.tr("请填写标题和问题描述，并控制草稿长度。")
        case .ghUnavailable:
            errorMessage = L10n.tr("未找到 gh，可复制草稿或使用浏览器反馈。")
        case .authRequired:
            errorMessage = L10n.tr("gh 尚未登录或当前认证不可用，可使用浏览器反馈。")
        case .submissionUnknown, .timedOut, .cancelled:
            errorMessage = L10n.tr("提交结果尚未确认，请先检查状态，不要重复提交。")
        default:
            errorMessage = L10n.tr("未能完成提交，草稿已保留。可复制或在浏览器中反馈。")
        }
    }
}
