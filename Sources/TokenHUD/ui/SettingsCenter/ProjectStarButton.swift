import SwiftUI
import AppKit

@MainActor struct ProjectStarButton: View {
    @State private var working = false
    @State private var starred = false
    @State private var errorMessage: String?
    @State private var task: Task<Void, Never>?
    private let service = FeedbackSubmissionService()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: star) {
                HStack(spacing: 10) {
                    if working { ProgressView().controlSize(.small).frame(width: 17) }
                    else {
                        Image(systemName: starred ? "star.fill" : "star")
                            .font(.system(size: 14)).frame(width: 17).foregroundStyle(Palette.controlText)
                    }
                    Text(starred ? L10n.tr("已 Star") : L10n.tr("一键 Star"))
                        .font(.system(size: 13)).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Palette.ink).padding(.horizontal, 10).frame(height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(working || starred)
            .accessibilityIdentifier("sidebar.project-star")
            .help(L10n.tr("使用本机 gh 为 QuotaNest 添加 GitHub Star"))
            .contextMenu { Button(L10n.tr("打开 GitHub 项目页"), action: openProject) }
            if let errorMessage {
                Text(errorMessage).font(.system(size: 10)).foregroundStyle(Palette.warn).lineLimit(3)
                    .padding(.horizontal, 10)
                Button(L10n.tr("打开 GitHub 项目页"), action: openProject)
                    .font(.system(size: 11)).buttonStyle(.plain).padding(.horizontal, 10)
            }
        }
        .onDisappear { task?.cancel() }
    }

    private func star() {
        guard !working && !starred else { return }
        errorMessage = nil
        guard let path = FeedbackToolAvailability.discover().ghPath else {
            errorMessage = L10n.tr("未找到 gh，可在项目页手动 Star。")
            return
        }
        working = true
        task = Task {
            defer { working = false; task = nil }
            do {
                try await service.starProject(ghPath: path)
                guard !Task.isCancelled else { return }
                starred = true
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error as? FeedbackSubmissionError == .authRequired
                    ? L10n.tr("gh 尚未登录，可在项目页手动 Star。")
                    : L10n.tr("未能确认 Star，请重试或打开项目页。")
            }
        }
    }

    private func openProject() {
        if let url = URL(string: "https://github.com/biedongbin/QuotaNest") { NSWorkspace.shared.open(url) }
    }
}
