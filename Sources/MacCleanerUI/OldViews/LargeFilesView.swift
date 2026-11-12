import MacCleanerCore
import QuickLook
import SwiftUI

struct LargeFilesView: View {
    @Environment(AppModel.self) private var app
    @State private var selection = Set<String>()
    @State private var preview: URL?

    var body: some View {
        @Bindable var model = app.largeFiles
        let rows = model.rows
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Picker("Files over", selection: $model.minimumBytes) {
                    ForEach(LargeFilesModel.thresholds, id: \.self) { Text(Format.bytes($0)).tag($0) }
                }
                .pickerStyle(.menu)
                .fixedSize()
                Toggle("Include app data in ~/Library", isOn: $model.includeLibrary)
                    .toggleStyle(.checkbox)
                    .help("Library files belong to apps. Only remove one when you know which app made it.")
                Spacer()
                ScanStatusLabel(state: model.state)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            if model.files.isEmpty {
                emptyState(model)
            } else {
                table(rows, model)
            }
            Divider()
            ActionBar(
                checkedCount: model.checked.count,
                checkedBytes: model.checkedBytes,
                removalItems: { model.checkedItems }
            )
        }
        .navigationTitle("Large Files")
        .navigationSubtitle(model.totalBytes.map { "\(Format.items(model.files.count)) · \(Format.bytes($0))" } ?? "")
        .searchable(text: $model.search, placement: .toolbar, prompt: "Filter by name or folder")
        .toolbar {
            ToolbarItem {
                ScanButton(state: model.state, hasResults: !model.files.isEmpty, scan: model.scan, stop: model.stop)
            }
        }
        .onChange(of: model.minimumBytes) { if model.state != .idle { model.scan() } }
        .onChange(of: model.includeLibrary) { if model.state != .idle { model.scan() } }
        .quickLookPreview($preview, in: rows.map(\.file.url))
    }

    @ViewBuilder
    private func emptyState(_ model: LargeFilesModel) -> some View {
        switch model.state {
        case .scanning:
            ContentUnavailableView {
                ProgressView()
            } description: {
                Text("Looking through your home folder for files over \(Format.bytes(model.minimumBytes))…")
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
            ContentUnavailableView("No files over \(Format.bytes(model.minimumBytes))", systemImage: "checkmark.circle")
                .frame(maxHeight: .infinity)
        case .idle:
            ContentUnavailableView {
                Label("Find large files", systemImage: "scalemass")
            } description: {
                Text("Lists every file in your home folder over the size you pick, with when you last opened it. fd does the search.")
            } actions: {
                Button("Find Large Files", action: model.scan)
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func table(_ rows: [LargeFileRow], _ model: LargeFilesModel) -> some View {
        @Bindable var model = model
        return Table(rows, selection: $selection, sortOrder: $model.sortOrder) {
            TableColumn("Name", value: \.name) { row in
                HStack(spacing: 6) {
                    CheckCell(isOn: Binding(
                        get: { model.checked.contains(row.id) },
                        set: { on in if on { model.checked.insert(row.id) } else { model.checked.remove(row.id) } }
                    ))
                    Icons.file(row.file.url)
                    Text(row.name).lineLimit(1).truncationMode(.middle)
                }
                .help(row.file.url.path)
            }
            .width(min: 180, ideal: 280)

            TableColumn("Kind", value: \.kind) { row in
                Text(row.kind).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 60, ideal: 90)

            TableColumn("Folder", value: \.location) { row in
                Text(row.location)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(row.file.isHidden ? "\(row.location)\nInside a hidden folder: usually data a tool keeps for itself." : row.location)
            }
            .width(min: 140, ideal: 260)

            TableColumn("Last Opened", value: \.lastOpenedSort) { row in
                Text(row.file.lastOpened == nil ? "Never" : Format.relative(row.file.lastOpened))
                    .foregroundStyle(.secondary)
                    .help(row.file.modified.map { "Modified \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "")
            }
            .width(min: 80, ideal: 110)

            TableColumn("Size", value: \.bytes) { row in
                Text(Format.bytes(row.bytes))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 86)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            FileMenu(urls: ids.map { URL(fileURLWithPath: $0) }) { preview = $0 }
            Divider()
            Button("Check") { model.checked.formUnion(ids) }
            Button("Uncheck") { model.checked.subtract(ids) }
        } primaryAction: { ids in
            Finder.reveal(ids.map { URL(fileURLWithPath: $0) })
        }
        .onKeyPress(.space) {
            guard let first = selection.first else { return .ignored }
            preview = preview == nil ? URL(fileURLWithPath: first) : nil
            return .handled
        }
    }
}
