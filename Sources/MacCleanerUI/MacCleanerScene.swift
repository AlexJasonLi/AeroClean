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
                .frame(minWidth: 940, minHeight: 580)
        }
        .defaultSize(width: 1180, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Scan") {
                Button("Scan for Junk") { model.pane = .junk; model.junk.scan() }
                    .keyboardShortcut("1", modifiers: [.command, .shift])
                Button("Find Large Files") { model.pane = .largeFiles; model.largeFiles.scan() }
                    .keyboardShortcut("2", modifiers: [.command, .shift])
                Button("Find Duplicates") { model.pane = .duplicates; model.duplicates.scan() }
                    .keyboardShortcut("3", modifiers: [.command, .shift])
                Button("Measure Home Folder") { model.pane = .space; model.space.open(model.space.home) }
                    .keyboardShortcut("4", modifiers: [.command, .shift])
            }
        }
    }
}
