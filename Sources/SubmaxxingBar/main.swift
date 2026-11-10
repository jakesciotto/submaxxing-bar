import AppKit
import LimitsCore

let arguments = CommandLine.arguments

if arguments.contains("--dump") {
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
    NSApplication.shared.setActivationPolicy(.accessory)
    SubmaxxingApp.main()
}
