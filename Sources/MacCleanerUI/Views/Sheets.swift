import AppKit
import MacCleanerCore
import SwiftUI

struct RemovalSheet: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let pending = app.pendingRemoval { content(pending) }
    }

    private func content(_ pending: PendingRemoval) -> some View {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 14) {
                Bubble(size: 44, lit: true) { PixelGlyph(glyph: .trash, cell: 2, color: .white) }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Move \(Format.items(pending.items.count)) to the Trash")
                        .font(Theme.pixel(11))
                        .foregroundStyle(Theme.ink)
                    Text("\(Format.bytes(pending.totalBytes)). You can put anything back until you empty the Trash.")
                        .font(Theme.detail)
                        .foregroundStyle(Theme.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(pending.items.sorted { $0.bytes > $1.bytes }) { item in
                        HStack(spacing: 8) {
                            Image(nsImage: Icons.file(item.url.path)).resizable().frame(width: 18, height: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.url.lastPathComponent).font(Theme.body).foregroundStyle(Theme.ink)
                                    .lineLimit(1).truncationMode(.middle)
                                Text(Format.location(item.url.deletingLastPathComponent(), home: home))
                                    .font(Theme.detail).foregroundStyle(Theme.inkFaint)
                                    .lineLimit(1).truncationMode(.head)
                            }
                            Spacer(minLength: 8)
                            Text(Format.bytes(item.bytes)).font(Theme.pixel(11)).foregroundStyle(Theme.inkSoft)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 38)
                    }
                }
            }
            .frame(height: min(CGFloat(pending.items.count) * 38 + 4, 260))
            .background(PixelCorners(radius: 9).fill(Theme.mist))
            .clipShape(PixelCorners(radius: 9))
            if let git = pending.foldersWithGit, git > 0 {
                Text(git == 1
                    ? "One of these folders holds a git repository. Its history goes to the Trash with it."
                    : "\(git) of these folders hold git repositories. Their history goes to the Trash with them.")
                    .font(Theme.detail)
                    .foregroundStyle(Theme.warn)
            }
            HStack(spacing: 10) {
                if let progress = app.removalProgress {
                    PixelBar(fraction: Double(progress.done) / Double(max(progress.total, 1)), cells: 16, cell: 4)
                    Text("\(Format.count(progress.done)) / \(Format.count(progress.total))")
                        .font(Theme.pixel(11)).foregroundStyle(Theme.inkSoft)
                }
                Spacer()
                Button("Cancel") { app.pendingRemoval = nil }
                    .keyboardShortcut(.cancelAction)
                    .disabled(app.isRemoving)
                AquaButton(title: "Move to Trash", glyph: .trash, enabled: !app.isRemoving) { app.confirmRemoval() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 540)
        .background(Theme.card)
        .interactiveDismissDisabled(app.isRemoving)
    }
}

struct FailuresSheet: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let outcome = app.lastOutcome ?? TrashOutcome()
        VStack(alignment: .leading, spacing: 14) {
            Text(outcome.moved.isEmpty ? "Nothing moved to the Trash" : "\(Format.items(outcome.moved.count)) moved, some left in place")
                .font(Theme.pixel(11))
                .foregroundStyle(Theme.ink)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(outcome.failed, id: \.url) { failure in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(failure.url.lastPathComponent).font(Theme.body).lineLimit(1).truncationMode(.middle)
                            Text(failure.reason).font(Theme.detail).foregroundStyle(Theme.inkSoft)
                        }
                        .help(failure.url.path)
                    }
                }
                .padding(12)
            }
            .frame(height: min(CGFloat(outcome.failed.count) * 40 + 24, 260))
            .background(PixelCorners(radius: 9).fill(Theme.mist))
            HStack {
                Spacer()
                AquaButton(title: "OK") { app.showingFailures = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 480)
        .background(Theme.card)
    }
}

struct SetupCard: View {
    @Environment(AppModel.self) private var app
    private var command: String { "brew install " + app.missingTools.map(\.formula).joined(separator: " ") }

    var body: some View {
        VStack(spacing: 14) {
            Text("two open-source helpers are missing").font(Theme.pixel(11)).foregroundStyle(Theme.ink)
            Text("Mole finds junk that is safe to remove. fclones compares files. Install them, then come back.")
                .font(Theme.detail).foregroundStyle(Theme.inkSoft)
            HStack(spacing: 8) {
                Text(command)
                    .font(Theme.pixel(11))
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(PixelCorners(radius: 6, step: 2).fill(Theme.mist))
                Chip(title: "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                }
                Chip(title: "Check again", lit: true) { app.recheckTools() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PixelCorners(radius: 12).fill(Theme.card))
        .overlay(PixelCorners(radius: 12).stroke(Theme.hairline, lineWidth: 1))
    }
}
