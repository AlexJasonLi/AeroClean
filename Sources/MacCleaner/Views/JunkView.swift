import MacCleanerCore
import QuickLook
import SwiftUI

struct JunkView: View {
    @Environment(AppModel.self) private var app
    @State private var selection = Set<String>()
    @State private var preview: URL?

    var body: some View {
        @Bindable var model = app.junk
        VStack(spacing: 0) {
            InfoStrip(text: "Caches, logs and leftovers that Mole marks as safe to remove. Apps rebuild caches when they need them; quit an app before removing its caches.") {
                ScanStatusLabel(state: model.state, waitingNote: "Mole takes a few minutes…")
            }
            Divider()
            content(model)
            Divider()
            ActionBar(
                checkedCount: model.checked.count,
                checkedBytes: model.checkedBytes,
                removalItems: { model.checkedItems },
                onTrashed: { model.didTrash($0) }
            ) {
                if !model.items.isEmpty {
                    Button(model.checked.isEmpty ? "Check All" : "Uncheck All") {
                        model.checkAll(model.checked.isEmpty)
                    }
                }
            }
        }
        .navigationTitle("Junk")
        .navigationSubtitle(model.totalBytes.map { "\(Format.bytes($0)) found" } ?? "")
        .toolbar {
            ToolbarItem {
                ScanButton(state: model.state, hasResults: model.scannedAt != nil, scan: model.scan, stop: model.stop)
            }
        }
        .quickLookPreview($preview)
    }

    @ViewBuilder
    private func content(_ model: JunkModel) -> some View {
        if model.items.isEmpty {
            switch model.state {
            case .scanning(let step):
                ContentUnavailableView {
                    ProgressView()
                } description: {
                    Text(step.map { "Mole is checking \($0)…" } ?? "Mole is starting…")
                    Text("A full check takes a few minutes. Nothing is removed while it looks.")
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
                ContentUnavailableView("No junk found", systemImage: "checkmark.circle", description: Text("Mole found nothing it considers safe to remove."))
                    .frame(maxHeight: .infinity)
            case .idle:
                ContentUnavailableView {
                    Label("Find junk", systemImage: "sparkles")
                } description: {
                    Text("Mole checks app caches, logs, developer leftovers and files from apps you have removed. Nothing is removed while it looks.")
                } actions: {
                    Button("Scan for Junk", action: model.scan)
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxHeight: .infinity)
            }
        } else {
            table(model)
        }
    }

    private func table(_ model: JunkModel) -> some View {
        @Bindable var model = model
        return Table(model.rows, children: \.children, selection: $selection, sortOrder: $model.sortOrder) {
            TableColumn("") { row in
                check(row, model)
            }
            .width(20)

            TableColumn("Name", value: \.name) { row in
                HStack(spacing: 6) {
                    if row.isGroup {
                        Icons.owner(row.name, fallback: row.children?.first?.url?.deletingLastPathComponent())
                    } else if let url = row.url {
                        Icons.file(url)
                    }
                    Text(row.name).lineLimit(1)
                    Text(row.detail)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .help(row.url?.path ?? row.name)
            }
            .width(min: 260, ideal: 420)

            TableColumn("Category", value: \.section) { row in
                Text(row.section).foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 130)

            TableColumn("Items", value: \.itemCount) { row in
                Text(Format.count(row.itemCount))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 50, ideal: 64)

            TableColumn("Size", value: \.bytes) { row in
                Text(row.bytes > 0 ? Format.bytes(row.bytes) : "—")
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 86)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            FileMenu(urls: urls(for: ids, in: model)) { preview = $0 }
            Divider()
            Button("Check") { setChecked(ids, true, model) }
            Button("Uncheck") { setChecked(ids, false, model) }
        } primaryAction: { ids in
            Finder.reveal(urls(for: ids, in: model))
        }
        .onKeyPress(.space) {
            guard let first = urls(for: selection, in: model).first else { return .ignored }
            preview = preview == nil ? first : nil
            return .handled
        }
    }

    @ViewBuilder
    private func check(_ row: JunkRow, _ model: JunkModel) -> some View {
        if let children = row.children {
            let sources = children.filter { $0.refusal == nil }.map { binding($0.id, model) }
            if sources.isEmpty {
                CheckCell(isOn: .constant(false), refusal: "Nothing here can be removed")
            } else {
                Toggle(sources: sources, isOn: \.self) { EmptyView() }
                    .toggleStyle(.checkbox)
                    .labelsHidden()
            }
        } else {
            CheckCell(isOn: binding(row.id, model), refusal: row.refusal)
        }
    }

    private func binding(_ id: String, _ model: JunkModel) -> Binding<Bool> {
        Binding(
            get: { model.checked.contains(id) },
            set: { on in
                if on { model.checked.insert(id) } else { model.checked.remove(id) }
            }
        )
    }

    private func leafRows(for ids: Set<String>, in model: JunkModel) -> [JunkRow] {
        model.rows.flatMap { group -> [JunkRow] in
            let children = group.children ?? []
            if ids.contains(group.id) { return children }
            return children.filter { ids.contains($0.id) }
        }
    }

    private func urls(for ids: Set<String>, in model: JunkModel) -> [URL] {
        leafRows(for: ids, in: model).compactMap(\.url)
    }

    private func setChecked(_ ids: Set<String>, _ on: Bool, _ model: JunkModel) {
        for row in leafRows(for: ids, in: model) where row.refusal == nil {
            if on { model.checked.insert(row.id) } else { model.checked.remove(row.id) }
        }
    }
}
