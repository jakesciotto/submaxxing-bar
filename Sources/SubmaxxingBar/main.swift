import AppKit
import LimitsCore

let arguments = CommandLine.arguments

if arguments.contains("--breakdown") {
    Task {
        for id in [ProviderID.claude, .codex] {
            let index = BreakdownIndex(provider: id)
            let start = Date()
            let first = await index.compute()
            let cold = Date().timeIntervalSince(start)
            _ = await index.compute()
            let warm = Date().timeIntervalSince(start) - cold
            print("== \(id.displayName): \(String(format: "%.2f", cold))s cold, \(String(format: "%.2f", warm))s warm")
            for row in first.rows {
                print(String(format: "  %-16@ 5h %5.1f%%   7d %5.1f%%", row.model as NSString, row.session * 100, row.weekly * 100))
            }
        }
        exit(0)
    }
    dispatchMain()
} else if arguments.contains("--dump") {
    Task {
        print(await Diagnostics.report(providers: Providers.all))
        exit(0)
    }
    dispatchMain()
} else if let index = arguments.firstIndex(of: "--render-menubar"), index + 1 < arguments.count {
    Preview.renderMenuBar(to: arguments[index + 1])
    exit(0)
} else if let index = arguments.firstIndex(of: "--render-fonts"), index + 1 < arguments.count {
    Preview.renderFonts(to: arguments[index + 1], dark: arguments.contains("--dark"))
    exit(0)
} else if let index = arguments.firstIndex(of: "--render-preview"), index + 1 < arguments.count {
    let typeface = arguments.firstIndex(of: "--font").flatMap { arguments.indices.contains($0 + 1) ? Typeface(rawValue: arguments[$0 + 1]) : nil } ?? .mono
    Preview.render(to: arguments[index + 1], dark: arguments.contains("--dark"), settingsPage: arguments.contains("--settings"), typeface: typeface)
    exit(0)
} else {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let store = UsageStore(providers: arguments.contains("--demo") ? Demo.providers : Providers.all, settings: AppSettings())
    let controller = StatusItemController(store: store)
    store.start()
    withExtendedLifetime(controller) { app.run() }
}
