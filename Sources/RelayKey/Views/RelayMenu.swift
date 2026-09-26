import AppKit
import RelayKeyCore
import SwiftUI

struct RelayMenu: View {
    var store: RelayStore

    var body: some View {
        Text(store.statusLine)
            .disabled(true)

        if store.showsStart {
            Button("Start") {
                store.perform(.start)
            }
            .disabled(!store.canStart)
        }

        if store.showsStopAndRestart {
            Button("Stop") {
                store.perform(.stop)
            }
            .disabled(!store.canStopOrRestart)

            Button("Restart") {
                store.perform(.restart)
            }
            .disabled(!store.canStopOrRestart)
        }

        Button("Refresh") {
            store.userRefresh()
        }
        .disabled(!store.canRefresh)

        Button("Copy Base URL") {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(store.paths.baseURL.absoluteString, forType: .string)
        }

        Button("Open Log") {
            NSWorkspace.shared.open(store.paths.logURL)
        }
        .disabled(!store.canOpenLog)

        Divider()

        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
