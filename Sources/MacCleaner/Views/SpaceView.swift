import MacCleanerCore
import QuickLook
import SwiftUI

struct SpaceView: View {
    @Environment(AppModel.self) private var app
    @State private var selection = Set<String>()
    @State private var preview: URL?

    var body: some View {
        @Bindable var model = app.space
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                breadcrumbs(model)
                Spacer(minLength: 12)
                if let listing = model.listing {
                    Text(listing.isPartial
                        ? "\(Format.bytes(listing.totalBytes)) or more, some folders could not be read"
                        : Format.bytes(listing.totalBytes))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else {
                    ScanStatusLabel(state: model.state)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            if model.listing == nil {
                emptyState(model)
            } else {
                table(model)
            }
            Divider()
            ActionBar(
                checkedCount: model.checked.count,
                checkedBytes: model.checkedBytes,
                removalItems: { model.checkedItems }
            )
        }
        .navigationTitle("Space")
        .navigationSubtitle("Measured by Mole")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    model.open(model.folder.deletingLastPathComponent())
                } label: {
                    Label("Enclosing Folder", systemImage: "chevron.left")
                }
                .help("Enclosing folder")
                .disabled(model.breadcrumbs.count < 2)
                Button(action: model.load) { Label("Measure Again", systemImage: "arrow.clockwise") }
                    .help("Measure again")
                    .disabled(model.state.isScanning)
            }
        }
        .quickLookPreview($preview)
    }

    private func breadcrumbs(_ model: SpaceModel) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(model.breadcrumbs.enumerated()), id: \.offset) { index, url in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Button(index == 0 ? "Home" : url.lastPathComponent) { model.open(url) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(index == model.breadcrumbs.count - 1 ? .primary : .secondary)
                    .disabled(model.state.isScanning)
            }
        }
        .font(.callout)
        .lineLimit(1)
    }

    @ViewBuilder
    private func emptyState(_ model: SpaceModel) -> some View {
        switch model.state {
        case .scanning:
            ContentUnavailableView {
                ProgressView()
            } description: {
                Text("Measuring \(Format.location(model.folder, home: model.home.path))…")
                Text("Your whole home folder takes about a minute; folders inside it are quicker.")
            }
            .frame(maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Could not measure this folder", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again", action: model.load)
            }
            .frame(maxHeight: .infinity)
        default:
            ContentUnavailableView {
                Label("See what takes up space", systemImage: "folder")
            } description: {
                Text("Mole measures every folder in your home folder. Double-click a folder to look inside it.")
            } actions: {
                Button("Measure Home Folder", action: model.load)
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func table(_ model: SpaceModel) -> some View {
        @Bindable var model = model
        let rows = model.rows
        return Table(rows, selection: $selection, sortOrder: $model.sortOrder) {
            TableColumn("Name", value: \.name) { row in
                HStack(spacing: 6) {
                    CheckCell(
                        isOn: Binding(
                            get: { model.checked.contains(row.id) },
                            set: { on in if on { model.checked.insert(row.id) } else { model.checked.remove(row.id) } }
                        ),
                        refusal: row.refusal
                    )
                    Icons.file(row.entry.url)
                    Text(row.name).lineLimit(1).truncationMode(.middle)
                    if row.entry.isCleanable {
                        Text("Rebuildable")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .overlay(Rectangle().stroke(Color.secondary.opacity(0.4), lineWidth: 0.5))
                            .help("Mole knows this folder holds caches or build output that gets rebuilt when needed")
                    }
                }
                .help(row.entry.url.path)
            }
            .width(min: 200, ideal: 320)

            TableColumn("Size", value: \.bytes) { row in
                HStack(spacing: 10) {
                    UsageBar(fraction: row.share, height: 5, tint: Color(red: 0x6A / 255, green: 0x89 / 255, blue: 0xA7 / 255))
                        .frame(minWidth: 60)
                    Text((row.entry.isPartial ? "≥ " : "") + Format.bytes(row.bytes))
                        .monospacedDigit()
                        .frame(width: 76, alignment: .trailing)
                }
            }
            .width(min: 160, ideal: 220)

            TableColumn("Last Used", value: \.lastAccessSort) { row in
                Text(row.entry.isDirectory ? "" : Format.relative(row.entry.lastAccess))
                    .foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 110)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            FileMenu(urls: ids.map { URL(fileURLWithPath: $0) }) { preview = $0 }
        } primaryAction: { ids in
            guard ids.count == 1, let id = ids.first, let row = rows.first(where: { $0.id == id }) else { return }
            if row.entry.isDirectory {
                model.open(row.entry.url)
            } else {
                Finder.reveal([row.entry.url])
            }
        }
        .onKeyPress(.space) {
            guard let first = selection.first else { return .ignored }
            preview = preview == nil ? URL(fileURLWithPath: first) : nil
            return .handled
        }
    }
}
