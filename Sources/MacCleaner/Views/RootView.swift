import AppKit
import MacCleanerCore
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            List(selection: Binding(get: { app.pane }, set: { if let pane = $0 { app.pane = pane } })) {
                Section("Find") {
                    ForEach(Pane.allCases) { pane in
                        Label(pane.title, systemImage: pane.symbol)
                            .badge(app.badge(for: pane).map { Text(Format.bytes($0)).monospacedDigit() })
                            .tag(pane)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 300)
            .safeAreaInset(edge: .bottom, spacing: 0) { StorageFooter() }
        } detail: {
            if app.missingTools.isEmpty {
                switch app.pane {
                case .junk: JunkView()
                case .largeFiles: LargeFilesView()
                case .duplicates: DuplicatesView()
                case .space: SpaceView()
                }
            } else {
                SetupView()
            }
        }
        .sheet(item: $app.pendingRemoval) { pending in
            RemovalSheet(pending: pending)
        }
        .sheet(isPresented: $app.showingFailures) {
            FailuresSheet()
        }
        .alert("Empty the Trash?", isPresented: $app.confirmingEmptyTrash) {
            Button("Empty Trash", role: .destructive) { Task { await app.emptyTrash() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(emptyTrashMessage)
        }
        .alert("The Trash was not emptied", isPresented: Binding(
            get: { app.emptyTrashError != nil },
            set: { if !$0 { app.emptyTrashError = nil } }
        )) {
            Button("OK") { app.emptyTrashError = nil }
        } message: {
            Text(app.emptyTrashError ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            app.recheckTools()
            app.refreshStorage()
        }
    }

    private var emptyTrashMessage: String {
        let tail = "Everything in it is deleted for good. This cannot be undone."
        if let bytes = app.trashBytes { return "This frees \(Format.bytes(bytes)). " + tail }
        if app.movedThisSession > 0 {
            return "It holds the \(Format.bytes(app.movedThisSession)) MacCleaner moved there, plus anything else you put in it. " + tail
        }
        return tail
    }
}

/// disk and trash, pinned to the bottom of the sidebar.
struct StorageFooter: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Storage")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if let disk = app.disk {
                    UsageBar(fraction: disk.usedFraction, tint: disk.usedFraction > 0.9 ? .orange : .accentColor)
                    Text("\(Format.bytes(disk.availableBytes)) available of \(Format.bytes(disk.totalBytes))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(12)
            Divider()
            HStack(spacing: 8) {
                Image(systemName: app.trashBytes == 0 ? "trash" : "trash.fill")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Trash").font(.callout)
                    Text(trashDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(2)
                }
                Spacer(minLength: 4)
                if app.isEmptyingTrash {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Empty…") { app.confirmingEmptyTrash = true }
                        .controlSize(.small)
                        .disabled(app.trashBytes == 0)
                }
            }
            .padding(12)
            if app.trashBytes == nil {
                Button("Show Trash size…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
                .help("macOS hides the Trash from apps without Full Disk Access. Turn it on for MacCleaner in System Settings, then reopen the app.")
            }
        }
    }

    private var trashDetail: String {
        if let bytes = app.trashBytes { return bytes == 0 ? "Empty" : Format.bytes(bytes) }
        if app.movedThisSession > 0 { return "\(Format.bytes(app.movedThisSession)) moved by MacCleaner" }
        return "Size hidden by macOS"
    }
}

struct RemovalSheet: View {
    @Environment(AppModel.self) private var app
    let pending: PendingRemoval

    var body: some View {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "trash")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(.secondary)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Move \(Format.items(pending.items.count)) to the Trash?")
                        .font(.headline)
                    Text("They take up \(Format.bytes(pending.totalBytes)). Until you empty the Trash, you can put any of them back from the Finder.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            List(pending.items.sorted { $0.bytes > $1.bytes }) { item in
                HStack(spacing: 8) {
                    Icons.file(item.url)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Text(Format.location(item.url.deletingLastPathComponent(), home: home))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    Spacer(minLength: 8)
                    Text(Format.bytes(item.bytes))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.bordered)
            .frame(height: min(CGFloat(pending.items.count) * 38 + 8, 280))
            HStack {
                if app.isRemoving {
                    ProgressView().controlSize(.small)
                    Text("Moving to the Trash…").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { app.pendingRemoval = nil }
                    .keyboardShortcut(.cancelAction)
                    .disabled(app.isRemoving)
                Button("Move to Trash") { Task { await app.confirmRemoval() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(app.isRemoving)
            }
        }
        .padding(20)
        .frame(width: 540)
        .interactiveDismissDisabled(app.isRemoving)
    }
}

struct FailuresSheet: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let outcome = app.lastOutcome ?? TrashOutcome()
        VStack(alignment: .leading, spacing: 14) {
            Text(outcome.moved.isEmpty
                ? "Nothing was moved to the Trash"
                : "\(Format.items(outcome.moved.count)) moved to the Trash, \(outcome.failed.count) left in place")
                .font(.headline)
            List(outcome.failed, id: \.url) { failure in
                VStack(alignment: .leading, spacing: 2) {
                    Text(failure.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Text(failure.reason).font(.caption).foregroundStyle(.secondary)
                }
                .help(failure.url.path)
            }
            .listStyle(.bordered)
            .frame(height: min(CGFloat(outcome.failed.count) * 40 + 8, 260))
            HStack {
                Spacer()
                Button("OK") { app.showingFailures = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

struct SetupView: View {
    @Environment(AppModel.self) private var app
    private let command = "brew install mole fd fclones"

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("MacCleaner needs three open-source tools")
                    .font(.title2.weight(.semibold))
                Text("They do the scanning. MacCleaner shows what they find and moves what you pick to the Trash.")
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 10) {
                toolRow(.mole, "Mole", "Finds caches, logs and leftovers that are safe to remove, and measures folders.", "https://github.com/tw93/Mole")
                toolRow(.fd, "fd", "Searches your home folder for large files.", "https://github.com/sharkdp/fd")
                toolRow(.fclones, "fclones", "Finds files with identical contents.", "https://github.com/pkolaczk/fclones")
            }
            HStack(spacing: 8) {
                Text(command)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .overlay(Rectangle().stroke(Color.secondary.opacity(0.35), lineWidth: 0.5))
                Button("Copy") { Finder.copyString(command) }
            }
            Text("Run it in Terminal, then come back.")
                .foregroundStyle(.secondary)
            Button("Check Again") { app.recheckTools() }
                .buttonStyle(.borderedProminent)
        }
        .padding(32)
        .frame(maxWidth: 560, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .navigationTitle("Setup")
    }

    private func toolRow(_ tool: Tool, _ name: String, _ purpose: String, _ link: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: tool.location == nil ? "circle" : "checkmark.circle.fill")
                .foregroundStyle(tool.location == nil ? Color.secondary : Color.green)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name).fontWeight(.medium)
                    if let url = URL(string: link) {
                        Link(link.replacingOccurrences(of: "https://", with: ""), destination: url).font(.caption)
                    }
                }
                Text(purpose).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

extension Finder {
    static func copyString(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}
