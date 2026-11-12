import AppKit
import MacCleanerCore
import QuickLook
import SwiftUI

/// set by the snapshot tool: lists render without scroll views so they can be imaged.
struct SnapshotMode: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var snapshotMode: Bool {
        get { self[SnapshotMode.self] }
        set { self[SnapshotMode.self] = newValue }
    }
}

public struct RootView: View {
    @Environment(AppModel.self) private var app

    public init() {}

    public var body: some View {
        @Bindable var app = app
        GeometryReader { proxy in
            let heroHeight = min(max(proxy.size.height * 0.36, 210), 320)
            ZStack(alignment: .top) {
                Theme.mist.ignoresSafeArea()
                VStack(spacing: 0) {
                    Hero()
                        .frame(height: heroHeight)
                        .padding(.horizontal, 14)
                        .padding(.top, 34)
                    Dock()
                        .padding(.top, -30)
                        .zIndex(1)
                    if app.missingTools.isEmpty {
                        ContentCard()
                            .padding(.horizontal, 14)
                            .padding(.top, 10)
                    } else {
                        SetupCard()
                            .padding(.horizontal, 14)
                            .padding(.top, 10)
                    }
                    BottomBar()
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                }
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .preferredColorScheme(.light)
        .tint(Theme.aqua)
        .sheet(item: $app.pendingRemoval) { _ in RemovalSheet() }
        .sheet(isPresented: $app.showingFailures) { FailuresSheet() }
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
        .quickLookPreview($app.preview)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            app.recheckTools()
            app.refreshStorage()
        }
    }

    private var emptyTrashMessage: String {
        let tail = "Everything in it is deleted for good. This cannot be undone."
        if let bytes = app.trashBytes { return "This frees at least \(Format.bytes(bytes)). " + tail }
        if app.movedThisSession > 0 {
            return "It holds the \(Format.bytes(app.movedThisSession)) MacCleaner moved there, plus anything else you put in it. " + tail
        }
        return tail
    }
}

// MARK: hero

struct Hero: View {
    @Environment(AppModel.self) private var app
    @Environment(\.snapshotMode) private var snapshot

    var body: some View {
        let headline = self.headline
        ZStack(alignment: .topLeading) {
            SceneView(kind: app.pane.scene, wind: app.isScanning ? 3.2 : 1, still: snapshot ? 3.2 : nil, burstToken: app.celebration)
            VStack(alignment: .leading, spacing: 6) {
                PixelText(headline.number, size: 44)
                PixelText(headline.caption, size: 11)
            }
            .padding(.top, 22)
            .padding(.leading, 26)
            HStack {
                Spacer()
                ScanBubble()
            }
            .padding(.top, 20)
            .padding(.trailing, 24)
        }
    }

    private var headline: (number: String, caption: String) {
        let index = app.index
        if index.index == nil, app.pane != .junk {
            if let progress = index.progress {
                return (Format.bytes(progress.bytes), "scanning · \(Format.count(Int(progress.files))) files")
            }
            return ("· · ·", "reading your disk")
        }
        switch app.pane {
        case .junk:
            if let total = app.junk.totalBytes { return (Format.bytes(total), "junk that is safe to clear") }
            if app.junk.state.isScanning { return ("· · ·", app.junk.step.map { "mole is checking \($0.lowercased())" } ?? "mole is looking") }
            return ("Junk", "caches and leftovers. press scan")
        case .large:
            let rows = app.large.rows(index)
            return (Format.bytes(rows.reduce(0) { $0 + $1.bytes }), "in \(Format.count(rows.count)) files over \(Format.bytes(app.large.minimumBytes))")
        case .copies:
            if let total = app.duplicates.totalRedundantBytes { return (Format.bytes(total), "in extra copies") }
            if app.duplicates.state.isScanning { return ("· · ·", "comparing files") }
            return ("Copies", "files with the same contents. press scan")
        case .space:
            let node = app.space.current(index)
            return (Format.bytes(node.map(index.total) ?? 0), node == index.homeNode ? "in your home folder" : "in \(index.index?.names[Int(node ?? 0)] ?? "")")
        case .system:
            let total = app.system.sections(index).reduce(0) { $0 + $1.total }
            return (Format.bytes(total), "in the places macos calls system data")
        }
    }
}

/// white pixel type with a hard drop shadow, legible over any sky.
struct PixelText: View {
    let text: String
    let size: CGFloat

    init(_ text: String, size: CGFloat) {
        self.text = text
        self.size = size
    }

    var body: some View {
        // one font pixel of outline on every side, like a game title: readable over cloud or sky.
        let step = max(size / 11, 1)
        let outline = Color(hex: 0x173D63, opacity: 0.82)
        ZStack(alignment: .topLeading) {
            ForEach(Array(Self.offsets.enumerated()), id: \.offset) { _, offset in
                Text(text).font(Theme.pixel(size)).foregroundStyle(outline)
                    .offset(x: offset.0 * step, y: offset.1 * step)
            }
            Text(text).font(Theme.pixel(size)).foregroundStyle(.white)
        }
        .padding(step)
        .fixedSize()
    }

    private static let offsets: [(CGFloat, CGFloat)] = [(-1, 0), (1, 0), (0, -1), (0, 1), (1, 1)]
}

/// rescans what the current pane shows. labelled, and says when it last ran on hover.
struct ScanBubble: View {
    @Environment(AppModel.self) private var app
    @State private var hovering = false

    var body: some View {
        let last = app.lastScanned
        VStack(spacing: 4) {
            Button { app.scan() } label: {
                Bubble(size: 50, lit: true) {
                    if app.isScanning {
                        PixelSpinner()
                    } else {
                        PixelGlyph(glyph: .scan, cell: 2, color: .white)
                    }
                }
            }
            .buttonStyle(.plain)
            .help(app.scanHelp)
            .keyboardShortcut("r", modifiers: .command)
            PixelText(app.isScanning ? "stop" : (last == nil ? "scan" : "rescan"), size: 11)
            PixelText(last.map { Format.relative($0) } ?? " ", size: 11)
                .opacity(hovering && !app.isScanning && last != nil ? 1 : 0)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

/// eight pixels chasing each other round a circle.
struct PixelSpinner: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.09)) { timeline in
            let tick = Int(timeline.date.timeIntervalSinceReferenceDate / 0.09) % 8
            Canvas { context, size in
                let spots: [(CGFloat, CGFloat)] = [(4, 0), (7, 1), (8, 4), (7, 7), (4, 8), (1, 7), (0, 4), (1, 1)]
                for (index, spot) in spots.enumerated() {
                    let age = (tick - index + 8) % 8
                    let opacity = age == 0 ? 1 : (age < 3 ? 0.6 : 0.22)
                    context.fill(Path(CGRect(x: spot.0 * 2.5, y: spot.1 * 2.5, width: 3, height: 3)), with: .color(.white.opacity(opacity)))
                }
            }
            .frame(width: 23, height: 23)
        }
    }
}

// MARK: dock

struct Dock: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 18) {
            ForEach(Array(Pane.allCases.enumerated()), id: \.element) { position, pane in
                Button { withAnimation(.easeOut(duration: 0.2)) { app.pane = pane } } label: {
                    VStack(spacing: 5) {
                        Bubble(size: 40, lit: app.pane == pane) {
                            PixelGlyph(glyph: pane.glyph, cell: 2, color: app.pane == pane ? .white : Theme.inkSoft)
                        }
                        Text(pane.title)
                            .font(Theme.pixel(11))
                            .foregroundStyle(app.pane == pane ? Theme.ink : Theme.inkSoft)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(KeyEquivalent(Character("\(position + 1)")), modifiers: .command)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .glass(radius: 15, opacity: 0.82)
    }
}

// MARK: bottom bar

struct BottomBar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 10) {
            if let disk = app.disk {
                HStack(spacing: 10) {
                    PixelBar(fraction: disk.usedFraction, cells: 14, cell: 4, fill: disk.usedFraction > 0.92 ? Theme.warn : Theme.leaf)
                    Text("\(Format.bytes(disk.availableBytes)) free")
                        .font(Theme.pixel(11))
                        .foregroundStyle(Theme.inkSoft)
                }
                .padding(.horizontal, 12)
                .frame(height: 34)
                .glass(radius: 9)
                .help("\(Format.bytes(disk.availableBytes)) available of \(Format.bytes(disk.totalBytes))")
            }
            HStack(spacing: 8) {
                PixelGlyph(glyph: .trash, cell: 1.5, color: Theme.inkSoft)
                Text(trashLabel)
                    .font(Theme.pixel(11))
                    .foregroundStyle(Theme.inkSoft)
                if app.isEmptyingTrash {
                    ProgressView().controlSize(.mini)
                } else if app.trashBytes != 0 {
                    Chip(title: "Empty") { app.confirmingEmptyTrash = true }
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .frame(height: 34)
            .glass(radius: 9)
            .help(app.trashBytes == nil ? "macOS hides the Trash from apps without Full Disk Access" : "The Trash")
            Spacer(minLength: 12)
            if let outcome = app.lastOutcome {
                Text("moved \(Format.bytes(outcome.bytesMoved)) to the trash")
                    .font(Theme.pixel(11))
                    .foregroundStyle(Theme.leaf)
                    .transition(.opacity)
            }
            let checked = checkedSummary
            AquaButton(title: checked.count == 0 ? "Move to Trash" : "Move \(Format.items(checked.count)) · \(Format.bytes(checked.bytes))",
                       glyph: .trash, enabled: checked.count > 0) {
                app.requestRemoval(checkedItems)
            }
            .keyboardShortcut(.delete, modifiers: .command)
        }
    }

    private var trashLabel: String {
        if let bytes = app.trashBytes { return bytes == 0 ? "empty" : Format.bytes(bytes) }
        if app.movedThisSession > 0 { return "+\(Format.bytes(app.movedThisSession))" }
        return "trash"
    }

    private var checkedItems: [RemovalItem] {
        switch app.pane {
        case .junk: app.junk.checkedItems
        case .large: app.large.checkedItems(app.large.rows(app.index))
        case .copies: app.duplicates.checkedItems
        case .space: app.space.checkedItems(app.space.rows(app.index))
        case .system: app.system.checkedItems(app.system.sections(app.index))
        }
    }

    private var checkedSummary: (count: Int, bytes: Int64) {
        let items = checkedItems
        return (items.count, items.reduce(0) { $0 + $1.bytes })
    }
}
