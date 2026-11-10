import LimitsCore
import SwiftUI

struct SubmaxxingApp: App {
    private let store: UsageStore

    init() {
        let demo = CommandLine.arguments.contains("--demo")
        store = UsageStore(providers: demo ? Demo.providers : Providers.all, settings: AppSettings())
        store.start()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(store: store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}
