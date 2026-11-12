import AppKit
import SwiftUI

enum Format {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    /// "~/Downloads/Clips" instead of the full path.
    static func location(_ url: URL, home: String) -> String {
        let path = url.standardizedFileURL.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    static func relative(_ date: Date?) -> String {
        guard let date, date > .distantPast else { return "—" }
        return date.formatted(.relative(presentation: .named))
    }

    static func count(_ value: Int) -> String {
        value.formatted(.number)
    }

    static func items(_ value: Int) -> String {
        value == 1 ? "1 item" : "\(count(value)) items"
    }
}

/// finder icons, cached by path.
@MainActor
enum Icons {
    private static var cache: [String: NSImage] = [:]

    static func file(_ url: URL) -> Image {
        image(for: url.path) { NSWorkspace.shared.icon(forFile: url.path) }
    }

    /// the app's icon when `owner` is the bundle id of an installed app.
    static func owner(_ owner: String, fallback: URL?) -> Image {
        image(for: "owner:" + owner) {
            if owner.split(separator: ".").count >= 3, !owner.contains(" "),
               let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: owner)
            {
                return NSWorkspace.shared.icon(forFile: app.path)
            }
            if let fallback { return NSWorkspace.shared.icon(forFile: fallback.path) }
            return NSWorkspace.shared.icon(for: .folder)
        }
    }

    private static func image(for key: String, make: () -> NSImage) -> Image {
        if let cached = cache[key] { return Image(nsImage: cached) }
        let made = make()
        made.size = NSSize(width: 16, height: 16)
        cache[key] = made
        return Image(nsImage: made)
    }
}

/// a checkbox, or a lock with the reason when the safety policy refuses the item.
struct CheckCell: View {
    @Binding var isOn: Bool
    var refusal: String?

    var body: some View {
        if let refusal {
            Image(systemName: "lock")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 16)
                .help(refusal)
        } else {
            Toggle("", isOn: $isOn)
                .toggleStyle(.checkbox)
                .labelsHidden()
        }
    }
}

/// one line of context above a table: what the list is and where it came from.
struct InfoStrip<Trailing: View>: View {
    let text: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

extension InfoStrip where Trailing == EmptyView {
    init(text: String) {
        self.text = text
        trailing = EmptyView()
    }
}

/// scan status for the info strip: progress while scanning, age of the result after.
struct ScanStatusLabel: View {
    let state: ScanState
    var waitingNote: String? = nil

    var body: some View {
        switch state {
        case .scanning(let step):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(step.map { "Checking \($0)…" } ?? (waitingNote ?? "Scanning…"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        case .done(let date):
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                Text("Scanned \(Format.relative(date))")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        case .failed:
            Label("Scan failed", systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.orange)
        case .idle:
            EmptyView()
        }
    }
}

struct ScanButton: View {
    let state: ScanState
    let hasResults: Bool
    let scan: () -> Void
    let stop: () -> Void

    var body: some View {
        if state.isScanning {
            Button(action: stop) { Label("Stop", systemImage: "stop.fill") }
                .help("Stop scanning")
        } else {
            Button(action: scan) { Label(hasResults ? "Scan Again" : "Scan", systemImage: "arrow.clockwise") }
                .help(hasResults ? "Scan again" : "Scan")
        }
    }
}

/// rectangular usage bar, used for disk usage and folder shares.
struct UsageBar: View {
    let fraction: Double
    var height: CGFloat = 6
    var tint: Color = .accentColor

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.primary.opacity(0.08))
                Rectangle()
                    .fill(tint)
                    .frame(width: max(1, proxy.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: height)
    }
}

/// bottom bar of every pane: what is checked, the result of the last removal, and the trash button.
struct ActionBar<Extra: View>: View {
    @Environment(AppModel.self) private var app
    let checkedCount: Int
    let checkedBytes: Int64
    let removalItems: () -> [RemovalItem]
    let onTrashed: @MainActor (Set<String>) -> Void
    @ViewBuilder var extra: Extra

    var body: some View {
        HStack(spacing: 12) {
            if let outcome = app.lastOutcome, !outcome.moved.isEmpty {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Moved \(Format.items(outcome.moved.count)) (\(Format.bytes(outcome.bytesMoved))) to the Trash. Empty it to free the space.")
                    .font(.callout)
                    .lineLimit(2)
                Button("Empty Trash…") { app.confirmingEmptyTrash = true }
                    .controlSize(.small)
                Button {
                    app.lastOutcome = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Dismiss")
            } else {
                Text(checkedCount == 0
                    ? "Check items to move them to the Trash"
                    : "\(Format.items(checkedCount)) checked · \(Format.bytes(checkedBytes))")
                    .font(.callout)
                    .foregroundStyle(checkedCount == 0 ? .secondary : .primary)
                    .monospacedDigit()
            }
            Spacer(minLength: 12)
            extra
            Button("Move to Trash…") {
                app.requestRemoval(removalItems(), onDone: onTrashed)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(checkedCount == 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

extension ActionBar where Extra == EmptyView {
    init(checkedCount: Int, checkedBytes: Int64, removalItems: @escaping () -> [RemovalItem], onTrashed: @escaping @MainActor (Set<String>) -> Void) {
        self.checkedCount = checkedCount
        self.checkedBytes = checkedBytes
        self.removalItems = removalItems
        self.onTrashed = onTrashed
        extra = EmptyView()
    }
}

enum Finder {
    static func reveal(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    static func copyPaths(_ urls: [URL]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
    }
}

/// finder-style context menu for rows that map to files.
struct FileMenu: View {
    let urls: [URL]
    let preview: (URL) -> Void

    var body: some View {
        Button("Quick Look") { if let first = urls.first { preview(first) } }
            .disabled(urls.isEmpty)
        Button("Show in Finder") { Finder.reveal(urls) }
            .disabled(urls.isEmpty)
        Button(urls.count > 1 ? "Copy Paths" : "Copy Path") { Finder.copyPaths(urls) }
            .disabled(urls.isEmpty)
    }
}
