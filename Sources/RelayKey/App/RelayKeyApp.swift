import AppKit
import RelayKeyCore
import SwiftUI

@main
struct RelayKeyApp: App {
    @State private var store: RelayStore

    init() {
        let paths = Paths()
        let controller = RelayController(
            paths: paths,
            health: URLSessionHealthTransport(),
            commands: ProcessCommandRunner()
        )
        let store = RelayStore(controller: controller, paths: paths)
        _store = State(initialValue: store)
        store.startPolling()
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            RelayMenu(store: store)
        } label: {
            Image(systemName: store.iconName)
        }
        .menuBarExtraStyle(.menu)
    }
}
