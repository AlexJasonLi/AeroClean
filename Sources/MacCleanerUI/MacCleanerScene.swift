import AppKit
import MacCleanerCore
import SwiftUI

/// the app's window and menus. the executable only adds the app delegate.
public struct MacCleanerScene: Scene {
    @State private var model = AppModel()

    public init() {}

    public var body: some Scene {
        Window("MacCleaner", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 960, minHeight: 640)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Scan") {
                Button("Scan for Junk") { model.pane = .junk; model.junk.scan() }
                    .keyboardShortcut("1", modifiers: [.command, .shift])
                Button("Rescan Disk") { model.index.scan(); model.system.refreshVolumes() }
                    .keyboardShortcut("2", modifiers: [.command, .shift])
                Button("Find Copies") { model.pane = .copies; model.duplicates.scan(index: model.index) }
                    .keyboardShortcut("3", modifiers: [.command, .shift])
            }
        }
    }
}
