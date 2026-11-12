import MacCleanerCore
import QuickLook
import SwiftUI

struct DuplicatesView: View {
    @Environment(AppModel.self) private var app
    @State private var selection = Set<String>()
    @State private var preview: URL?

    var body: some View {
        @Bindable var model = app.duplicates
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Picker("Files over", selection: $model.minimumBytes) {
                    ForEach(DuplicatesModel.thresholds, id: \.self) { Text(Format.bytes($0)).tag($0) }
                }
                .pickerStyle(.menu)
                .fixedSize()
                Text("Identical files found by fclones. ~/Library, hidden folders and dependency folders like node_modules are left out. One copy of each file always stays.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                ScanStatusLabel(state: model.state)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            if model.groups.isEmpty {
                emptyState(model)
            } else {
                table(model)
            }
            Divider()
            ActionBar(
                checkedCount: model.checked.count,
                checkedBytes: model.checkedBytes,
                removalItems: { model.checkedItems },
                onTrashed: { model.didTrash($0) }
            ) {
                if !model.groups.isEmpty {
                    Button("Check Extra Copies") { model.checkExtraCopies() }
                        .help("Checks every copy except the oldest one in each group")
                }
            }
        }
        .navigationTitle("Duplicates")
        .navigationSubtitle(model.totalRedundantBytes.map { "\(Format.bytes($0)) in extra copies" } ?? "")
        .toolbar {
            ToolbarItem {
                ScanButton(state: model.state, hasResults: !model.groups.isEmpty, scan: model.scan, stop: model.stop)
            }
        }
        .onChange(of: model.minimumBytes) { if model.state != .idle { model.scan() } }
        .quickLookPreview($preview)
    }

    @ViewBuilder
    private func emptyState(_ model: DuplicatesModel) -> some View {
        switch model.state {
        case .scanning:
            ContentUnavailableView {
                ProgressView()
            } description: {
                Text("Comparing files over \(Format.bytes(model.minimumBytes))…")
            }
            .frame(maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("The scan stopped", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again", action: model.scan)
            }
            .frame(maxHeight: .infinity)
        case .done:
            ContentUnavailableView("No duplicates over \(Format.bytes(model.minimumBytes))", systemImage: "checkmark.circle")
                .frame(maxHeight: .infinity)
        case .idle:
            ContentUnavailableView {
                Label("Find duplicates", systemImage: "square.on.square")
            } description: {
                Text("Finds files with exactly the same contents, wherever they are in your home folder.")
            } actions: {
                Button("Find Duplicates", action: model.scan)
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func table(_ model: DuplicatesModel) -> some View {
        @Bindable var model = model
        return Table(model.rows, children: \.children, selection: $selection, sortOrder: $model.sortOrder) {
            TableColumn("") { row in
                if !row.isGroup {
                    let allowed = model.canCheck(row.id, in: row.groupID)
                    Toggle("", isOn: Binding(
                        get: { model.checked.contains(row.id) },
                        set: { model.setChecked(row.id, in: row.groupID, $0) }
                    ))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .disabled(!allowed)
                    .help(allowed ? "" : "Keep at least one copy")
                }
            }
            .width(20)

            TableColumn("Name", value: \.name) { row in
                HStack(spacing: 6) {
                    if let url = row.url { Icons.file(url) }
                    Text(row.name)
                        .fontWeight(row.isGroup ? .medium : .regular)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .help(row.url?.path ?? row.name)
            }
            .width(min: 180, ideal: 280)

            TableColumn("Folder", value: \.location) { row in
                Text(row.location)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .width(min: 140, ideal: 280)

            TableColumn("Modified", value: \.modifiedSort) { row in
                Text(Format.relative(row.modified)).foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 110)

            TableColumn("Size", value: \.bytes) { row in
                Text(Format.bytes(row.bytes))
                    .monospacedDigit()
                    .foregroundStyle(row.isGroup ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 86)

            TableColumn("Extra", value: \.extraBytes) { row in
                Text(row.isGroup ? Format.bytes(row.extraBytes) : "")
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 86)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            FileMenu(urls: urls(for: ids, in: model)) { preview = $0 }
        } primaryAction: { ids in
            Finder.reveal(urls(for: ids, in: model))
        }
        .onKeyPress(.space) {
            guard let first = urls(for: selection, in: model).first else { return .ignored }
            preview = preview == nil ? first : nil
            return .handled
        }
    }

    private func urls(for ids: Set<String>, in model: DuplicatesModel) -> [URL] {
        model.rows.flatMap { group -> [URL] in
            let copies = group.children ?? []
            if ids.contains(group.id) { return copies.compactMap(\.url) }
            return copies.filter { ids.contains($0.id) }.compactMap(\.url)
        }
    }
}
