import AppKit
import SwiftUI

/// renders every pane of the real app, with this mac's data, to png files. no window.
public enum ScreenSnapshot {
    @MainActor
    public static func render(to folder: URL, size: CGSize = CGSize(width: 1200, height: 800)) async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let model = AppModel()
        // wait for the disk index, then find copies so every pane has something to show.
        while model.index.index == nil || model.index.state.isScanning { try await Task.sleep(for: .milliseconds(200)) }
        model.duplicates.scan(index: model.index)
        while model.duplicates.state.isScanning { try await Task.sleep(for: .milliseconds(200)) }
        try await Task.sleep(for: .milliseconds(600))
        for pane in Pane.allCases {
            model.pane = pane
            prepare(model, for: pane)
            let view = RootView()
                .environment(model)
                .environment(\.snapshotMode, true)
                .frame(width: size.width, height: size.height)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
            else { continue }
            try png.write(to: folder.appendingPathComponent("pane-\(pane.rawValue).png"))
        }
    }

    /// a realistic moment in each pane: a group open, a few items checked.
    @MainActor
    private static func prepare(_ model: AppModel, for pane: Pane) {
        switch pane {
        case .large:
            let rows = model.large.rows(model.index)
            model.large.checked = Set(rows.prefix(2).map(\.id))
        case .copies:
            model.duplicates.checkExtraCopies()
        case .junk:
            if let first = model.junk.rows.first { model.junk.checked = Set(first.paths) }
        default:
            break
        }
    }
}
