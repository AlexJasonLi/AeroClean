import AppKit
import AeroCleanCore
import SwiftUI

/// the white card under the scene: a few controls and the list for the current pane.
struct ContentCard: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch app.pane {
                case .junk: JunkList()
                case .large: LargeList()
                case .copies: CopiesList()
                case .space: SpaceList()
                case .system: SystemList()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(PixelCorners(radius: 12).fill(Theme.card))
        .clipShape(PixelCorners(radius: 12))
        .overlay(PixelCorners(radius: 12).stroke(Theme.hairline, lineWidth: 1))
        .shadow(color: Color(hex: 0x3D6A8F, opacity: 0.08), radius: 10, y: 4)
    }
}

/// the strip of controls at the top of a list.
struct ListHeader<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            leading
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
}

/// scrolls normally; lays out flat for snapshots, which cannot image a scroll view.
struct RowStack<Content: View>: View {
    @Environment(\.snapshotMode) private var snapshot
    @ViewBuilder var content: Content

    var body: some View {
        if snapshot {
            // an overlay does not size its parent, so a long list cannot push the bottom bar away.
            Color.clear
                .overlay(alignment: .top) { VStack(spacing: 0) { content } }
                .clipped()
        } else {
            ScrollView {
                LazyVStack(spacing: 0) { content }
            }
            .scrollIndicators(.automatic)
        }
    }
}

/// a centred pixel message for empty and busy lists.
struct ListMessage: View {
    let title: String
    var detail: String? = nil
    var busy = false
    var action: (title: String, run: () -> Void)? = nil

    var body: some View {
        VStack(spacing: 10) {
            if busy { PixelSpinner().colorMultiply(Theme.aqua) }
            Text(title).font(Theme.pixel(11)).foregroundStyle(Theme.inkSoft)
            if let detail {
                Text(detail).font(Theme.detail).foregroundStyle(Theme.inkFaint).multilineTextAlignment(.center)
            }
            if let action { Chip(title: action.title, lit: true, action: action.run).padding(.top, 4) }
        }
        .frame(maxWidth: 360)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// one line of a list: check, icon, name over location, a size bar and the size.
struct ItemRow: View {
    var icon: NSImage?
    var glyph: Glyph? = nil
    let title: String
    var subtitle: String? = nil
    let bytes: Int64
    var share: Double = 0
    /// nil is mixed.
    var check: Bool?
    var refusal: String? = nil
    var showsCheck = true
    var indent: CGFloat = 0
    /// nil when the row does not expand.
    var expanded: Bool? = nil
    var selected = false
    var badge: String? = nil
    var onCheck: () -> Void = {}
    var onSelect: () -> Void = {}
    var onOpen: () -> Void = {}
    var onExpand: () -> Void = {}
    var menuPaths: [String] = []
    var preview: (URL) -> Void = { _ in }

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let expanded {
                    Button(action: onExpand) {
                        PixelGlyph(glyph: expanded ? .chevronDown : .chevronRight, cell: 1.5, color: Theme.inkSoft)
                            .frame(width: 12, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear.frame(width: 12, height: 16)
                }
            }
            .padding(.leading, indent)
            if showsCheck {
                Button(action: onCheck) {
                    PixelCheck(state: check, locked: refusal != nil)
                }
                .buttonStyle(.plain)
                .disabled(refusal != nil)
                .help(refusal ?? "")
            }
            if let icon {
                Image(nsImage: icon).resizable().interpolation(.high).frame(width: 22, height: 22)
            } else if let glyph {
                PixelGlyph(glyph: glyph, cell: 2, color: Theme.inkSoft).frame(width: 22, height: 22)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(Theme.body)
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let badge {
                        Text(badge)
                            .font(Theme.pixel(11))
                            .foregroundStyle(Theme.leaf)
                    }
                }
                if let subtitle {
                    Text(subtitle)
                        .font(Theme.detail)
                        .foregroundStyle(Theme.inkFaint)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 12)
            if share > 0 {
                PixelBar(fraction: share, cells: 8, cell: 4, gap: 2, fill: Theme.aqua, empty: Color(hex: 0xE6EEF4))
            }
            Text(bytes > 0 ? Format.bytes(bytes) : "")
                .font(Theme.pixel(11))
                .foregroundStyle(Theme.ink)
                .frame(width: 70, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
        .background(selected ? Theme.rowSelected : (hovering ? Theme.rowHover : Color.clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: onOpen)
        .onTapGesture(perform: onSelect)
        .contextMenu {
            if !menuPaths.isEmpty {
                Button("Quick Look") { preview(URL(fileURLWithPath: menuPaths[0])) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(menuPaths.map { URL(fileURLWithPath: $0) }) }
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(menuPaths.joined(separator: "\n"), forType: .string)
                }
            }
        }
    }
}

/// keeps the row the user clicked, for quick look and the space bar.
@MainActor @Observable
final class ListSelection {
    var id: String?
    var path: String?

    func select(_ id: String, path: String?) {
        self.id = id
        self.path = path
    }
}

/// space bar previews the selected row, as in the Finder.
struct PreviewOnSpace: ViewModifier {
    @Environment(AppModel.self) private var app
    let path: String?

    func body(content: Content) -> some View {
        content
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(.space) {
                guard let path else { return .ignored }
                app.preview = app.preview == nil ? URL(fileURLWithPath: path) : nil
                return .handled
            }
    }
}

// MARK: junk

struct JunkList: View {
    @Environment(AppModel.self) private var app
    @State private var expanded: Set<String> = []
    @State private var showLeftOut = false
    @State private var selection = ListSelection()

    var body: some View {
        let model = app.junk
        VStack(spacing: 0) {
            ListHeader {
                Text(model.scannedAt.map { "found by mole, checked by aeroclean · \(Format.relative($0))" } ?? "found by mole, checked by aeroclean")
                    .font(Theme.pixel(11))
                    .foregroundStyle(Theme.inkFaint)
            } trailing: {
                if model.leftOutBytes > 0 {
                    Chip(title: "left out \(Format.bytes(model.leftOutBytes))", lit: showLeftOut) { showLeftOut.toggle() }
                        .help("What Mole listed that AeroClean will not call junk, and why")
                }
                if !model.items.isEmpty {
                    Chip(title: model.checked.isEmpty ? "Check all" : "Uncheck all") { model.checkAll(model.checked.isEmpty) }
                }
            }
            if model.items.isEmpty {
                switch model.state {
                case .scanning(let step):
                    ListMessage(title: step.map { "mole is checking \($0.lowercased())" } ?? "mole is starting",
                                detail: "A full check takes a few minutes. Nothing is removed while it looks.", busy: true)
                case .failed(let message):
                    ListMessage(title: "the scan stopped", detail: message, action: ("Try again", model.scan))
                case .done:
                    ListMessage(title: "no junk found")
                case .idle:
                    ListMessage(title: "caches, logs and leftovers", detail: "Only things that are rebuilt, downloaded again or never read.",
                                action: ("Scan for junk", model.scan))
                }
            } else {
                let largest = max(model.rows.first?.bytes ?? 1, 1)
                RowStack {
                    if showLeftOut {
                        LeftOutSection(rows: model.leftOut)
                    }
                    ForEach(model.rows) { kind in
                        let open = expanded.contains(kind.id)
                        ItemRow(
                            icon: nil, glyph: glyph(for: kind.id),
                            title: kind.name, subtitle: kind.detail,
                            bytes: kind.bytes, share: Double(kind.bytes) / Double(largest),
                            check: model.state(of: kind.paths),
                            expanded: open, selected: selection.id == kind.id,
                            onCheck: { model.toggle(kind.paths) },
                            onSelect: { selection.select(kind.id, path: kind.paths.first) },
                            onOpen: { toggle(kind.id) },
                            onExpand: { toggle(kind.id) },
                            menuPaths: kind.paths,
                            preview: { app.preview = $0 }
                        )
                        if open {
                            ForEach(kind.children ?? []) { owner in
                                ItemRow(
                                    icon: Icons.owner(owner.owner ?? owner.name, fallback: owner.paths.first.map { ($0 as NSString).deletingLastPathComponent }),
                                    title: owner.name, subtitle: owner.detail,
                                    bytes: owner.bytes, check: model.state(of: owner.paths),
                                    indent: 22, selected: selection.id == owner.id,
                                    onCheck: { model.toggle(owner.paths) },
                                    onSelect: { selection.select(owner.id, path: owner.paths.first) },
                                    onOpen: { NSWorkspace.shared.activateFileViewerSelecting(owner.paths.prefix(20).map { URL(fileURLWithPath: $0) }) },
                                    menuPaths: owner.paths,
                                    preview: { app.preview = $0 }
                                )
                            }
                        }
                    }
                }
                .modifier(PreviewOnSpace(path: selection.path))
            }
        }
    }

    private func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    private func glyph(for id: String) -> Glyph {
        switch id {
        case "kind:logs": .page
        case "kind:temporary": .clock
        case "kind:buildCache": .box
        case "kind:downloadCache": .download
        case "kind:leftover": .leaf
        case "kind:oldExtension": .copies
        default: .sparkle
        }
    }
}

/// what mole listed but AeroClean left out, with the reason. read only.
struct LeftOutSection: View {
    let rows: [JunkRow]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("left out of junk, not removable here")
                    .font(Theme.pixel(11))
                    .foregroundStyle(Theme.inkSoft)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 4)
            ForEach(rows) { row in
                ItemRow(icon: nil, glyph: .lock, title: row.name, subtitle: row.detail, bytes: row.bytes,
                        check: false, refusal: row.doubt, menuPaths: row.paths)
            }
            Rectangle().fill(Theme.hairline).frame(height: 1).padding(.top, 8)
        }
        .background(Theme.mist.opacity(0.6))
    }
}

// MARK: large files

struct LargeList: View {
    @Environment(AppModel.self) private var app
    @Environment(\.snapshotMode) private var snapshot
    @State private var selection = ListSelection()

    var body: some View {
        @Bindable var model = app.large
        let rows = model.rows(app.index)
        let largest = max(rows.first?.bytes ?? 1, 1)
        VStack(spacing: 0) {
            ListHeader {
                ForEach(LargeFilesModel.thresholds, id: \.self) { value in
                    Chip(title: Format.bytes(value), lit: model.minimumBytes == value) { model.minimumBytes = value }
                }
                Chip(title: "App data", lit: model.includeLibrary) { model.includeLibrary.toggle() }
                    .help("Include files apps keep in ~/Library")
            } trailing: {
                SearchBox(text: $model.search, snapshot: snapshot)
            }
            if app.index.index == nil {
                ListMessage(title: "reading your disk", busy: true)
            } else if rows.isEmpty {
                ListMessage(title: model.search.isEmpty ? "no files that big" : "nothing matches")
            } else {
                RowStack {
                    ForEach(rows) { row in
                        ItemRow(
                            icon: Icons.file(row.path), title: row.name, subtitle: row.location,
                            bytes: row.bytes, share: Double(row.bytes) / Double(largest),
                            check: model.checked.contains(row.id), selected: selection.id == row.id,
                            onCheck: { model.checked.formSymmetricDifference([row.id]) },
                            onSelect: { selection.select(row.id, path: row.path) },
                            onOpen: { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: row.path)]) },
                            menuPaths: [row.path],
                            preview: { app.preview = $0 }
                        )
                    }
                }
                .modifier(PreviewOnSpace(path: selection.path))
            }
        }
    }
}

struct SearchBox: View {
    @Binding var text: String
    var snapshot = false

    var body: some View {
        HStack(spacing: 6) {
            PixelGlyph(glyph: .scan, cell: 1, color: Theme.inkFaint)
            if snapshot {
                Text("filter").font(Theme.detail).foregroundStyle(Theme.inkFaint)
                Spacer()
            } else {
                TextField("filter", text: $text)
                    .textFieldStyle(.plain)
                    .font(Theme.detail)
            }
        }
        .padding(.horizontal, 8)
        .frame(width: 170, height: 26)
        .background(PixelCorners(radius: 6, step: 2).fill(Color(hex: 0xF0F5F9)))
        .overlay(PixelCorners(radius: 6, step: 2).stroke(Theme.hairline, lineWidth: 1))
    }
}

// MARK: copies

struct CopiesList: View {
    @Environment(AppModel.self) private var app
    @State private var selection = ListSelection()

    var body: some View {
        @Bindable var model = app.duplicates
        VStack(spacing: 0) {
            ListHeader {
                ForEach(DuplicatesModel.thresholds, id: \.self) { value in
                    Chip(title: Format.bytes(value), lit: model.minimumBytes == value) {
                        model.minimumBytes = value
                        if model.state != .idle { model.scan(index: app.index) }
                    }
                }
            } trailing: {
                if !model.groups.isEmpty {
                    Chip(title: "Keep oldest") { model.checkExtraCopies() }
                        .help("Checks every copy except the oldest one in each group")
                }
            }
            if model.groups.isEmpty {
                switch model.state {
                case .scanning: ListMessage(title: "comparing files", busy: true)
                case .failed(let message): ListMessage(title: "the scan stopped", detail: message, action: ("Try again", { model.scan(index: app.index) }))
                case .done: ListMessage(title: "no copies over \(Format.bytes(model.minimumBytes))")
                case .idle:
                    ListMessage(title: "files with the same contents", detail: "One copy of each always stays.",
                                action: app.index.index == nil ? nil : ("Find copies", { model.scan(index: app.index) }))
                }
            } else {
                let rows = model.rows
                let largest = max(rows.map(\.extraBytes).max() ?? 1, 1)
                RowStack {
                    ForEach(rows) { group in
                        ItemRow(
                            icon: group.children?.first?.url.map { Icons.file($0.path) }, title: group.name,
                            subtitle: "\(group.copyCount) copies · \(Format.bytes(group.bytes)) each",
                            bytes: group.extraBytes, share: Double(group.extraBytes) / Double(largest),
                            check: false, showsCheck: false, selected: selection.id == group.id,
                            onSelect: { selection.select(group.id, path: group.children?.first?.url?.path) },
                            menuPaths: group.children?.compactMap { $0.url?.path } ?? [],
                            preview: { app.preview = $0 }
                        )
                        ForEach(group.children ?? []) { copy in
                            let allowed = model.canCheck(copy.id, in: copy.groupID)
                            let kept = !model.checked.contains(copy.id)
                            ItemRow(
                                icon: copy.url.map { Icons.file($0.path) }, title: copy.location, subtitle: "modified \(Format.relative(copy.modified))",
                                bytes: 0, check: model.checked.contains(copy.id),
                                refusal: allowed ? nil : "Keep at least one copy",
                                indent: 22, selected: selection.id == copy.id,
                                badge: kept && !model.checked.isEmpty && !allowed ? "kept" : nil,
                                onCheck: { model.setChecked(copy.id, in: copy.groupID, !model.checked.contains(copy.id)) },
                                onSelect: { selection.select(copy.id, path: copy.url?.path) },
                                onOpen: { if let url = copy.url { NSWorkspace.shared.activateFileViewerSelecting([url]) } },
                                menuPaths: copy.url.map { [$0.path] } ?? [],
                                preview: { app.preview = $0 }
                            )
                        }
                    }
                }
                .modifier(PreviewOnSpace(path: selection.path))
            }
        }
    }
}

// MARK: space

struct SpaceList: View {
    @Environment(AppModel.self) private var app
    @State private var selection = ListSelection()

    var body: some View {
        let model = app.space
        let index = app.index
        VStack(spacing: 0) {
            ListHeader {
                let trail = model.breadcrumbs(index)
                ForEach(Array(trail.enumerated()), id: \.offset) { position, node in
                    if position > 0 { PixelGlyph(glyph: .chevronRight, cell: 1, color: Theme.inkFaint) }
                    Chip(title: position == 0 ? "Home" : (index.index?.names[Int(node)] ?? ""), lit: position == trail.count - 1) {
                        model.open(node)
                    }
                }
            } trailing: {
                if model.breadcrumbs(index).count > 1, let parent = model.breadcrumbs(index).dropLast().last {
                    Chip(title: "Back") { model.open(parent) }
                }
            }
            if index.index == nil {
                ListMessage(title: "reading your disk", busy: true)
            } else {
                let rows = model.rows(index)
                let largest = max(rows.first?.bytes ?? 1, 1)
                RowStack {
                    ForEach(rows) { row in
                        ItemRow(
                            icon: row.kind == .smallFiles ? nil : Icons.file(row.path),
                            glyph: row.kind == .smallFiles ? .leaf : nil,
                            title: row.name, subtitle: row.detail,
                            bytes: row.bytes, share: Double(row.bytes) / Double(largest),
                            check: model.checked.contains(row.id), refusal: row.refusal,
                            selected: selection.id == row.id,
                            badge: row.rebuildable ? "rebuildable" : nil,
                            onCheck: { model.checked.formSymmetricDifference([row.id]) },
                            onSelect: { selection.select(row.id, path: row.kind == .smallFiles ? nil : row.path) },
                            onOpen: {
                                if case .folder(let node) = row.kind { model.open(node) } else {
                                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: row.path)])
                                }
                            },
                            menuPaths: [row.path],
                            preview: { app.preview = $0 }
                        )
                    }
                }
                .modifier(PreviewOnSpace(path: selection.path))
            }
        }
    }
}

// MARK: system data

struct SystemList: View {
    @Environment(AppModel.self) private var app
    @State private var selection = ListSelection()

    var body: some View {
        let model = app.system
        let sections = model.sections(app.index)
        VStack(spacing: 0) {
            ListHeader {
                Text("what macos counts as system data")
                    .font(Theme.pixel(11))
                    .foregroundStyle(Theme.inkFaint)
            } trailing: {
                EmptyView()
            }
            if app.index.index == nil {
                ListMessage(title: "reading your disk", busy: true)
            } else {
                let largest = max(sections.flatMap(\.rows).map(\.bytes).max() ?? 1, 1)
                RowStack {
                    ForEach(sections) { section in
                        HStack {
                            Text(section.title.lowercased())
                                .font(Theme.pixel(11))
                                .foregroundStyle(Theme.inkSoft)
                            Spacer()
                            Text(Format.bytes(section.total))
                                .font(Theme.pixel(11))
                                .foregroundStyle(Theme.inkFaint)
                        }
                        .padding(.horizontal, 14)
                        .padding(.top, 14)
                        .padding(.bottom, 4)
                        ForEach(section.rows) { row in
                            ItemRow(
                                icon: row.owner.map { Icons.owner($0, fallback: row.path) } ?? row.path.map(Icons.file),
                                glyph: row.path == nil && row.owner == nil ? .computer : nil,
                                title: row.title, subtitle: row.note,
                                bytes: row.bytes, share: Double(row.bytes) / Double(largest),
                                check: model.checked.contains(row.id),
                                refusal: row.removable ? nil : row.note,
                                selected: selection.id == row.id,
                                onCheck: { model.checked.formSymmetricDifference([row.id]) },
                                onSelect: { selection.select(row.id, path: row.path) },
                                onOpen: {
                                    if let path = row.path { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                                },
                                menuPaths: row.path.map { [$0] } ?? [],
                                preview: { app.preview = $0 }
                            )
                        }
                    }
                }
                .modifier(PreviewOnSpace(path: selection.path))
            }
        }
    }
}
