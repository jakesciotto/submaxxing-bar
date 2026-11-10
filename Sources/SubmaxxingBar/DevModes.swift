import AppKit
import LimitsCore
import SwiftUI

enum Demo {
    static func snapshots(now: Date) -> [UsageSnapshot] {
        [
            UsageSnapshot(provider: .claude, plan: "Team", meters: [
                Meter(label: "Session", usedPercent: 68, resetsAt: now.addingTimeInterval(72 * 60)),
                Meter(label: "Weekly", usedPercent: 41, resetsAt: now.addingTimeInterval(3 * 86_400 + 5 * 3600)),
                Meter(label: "Fable weekly", usedPercent: 18, resetsAt: now.addingTimeInterval(3 * 86_400 + 5 * 3600)),
                Meter(label: "Extra usage", usedPercent: 62, detail: "$312 / $500", kind: .spend),
            ], fetchedAt: now),
            UsageSnapshot(provider: .codex, plan: "Team", meters: [
                Meter(label: "Session", usedPercent: 100, resetsAt: now.addingTimeInterval(220 * 60)),
                Meter(label: "Weekly", usedPercent: 16, resetsAt: now.addingTimeInterval(5 * 86_400)),
                Meter(label: "Credits", usedPercent: 6, resetsAt: now.addingTimeInterval(20 * 86_400), detail: "1,240 / 20,000", kind: .spend),
            ], fetchedAt: now),
            UsageSnapshot(provider: .cursor, plan: "Ultra", meters: [
                Meter(label: "Included", usedPercent: 12, resetsAt: now.addingTimeInterval(11 * 86_400), detail: "$48 / $400"),
            ], fetchedAt: now),
        ]
    }

    struct FixedProvider: UsageProvider {
        let id: ProviderID

        func fetch() async throws -> FetchResult {
            let snapshot = Demo.snapshots(now: Date()).first { $0.provider == id }!
            return FetchResult(raw: Data(), snapshot: snapshot)
        }
    }

    static var providers: [any UsageProvider] {
        ProviderID.allCases.map { FixedProvider(id: $0) }
    }
}

enum Diagnostics {
    static func report(providers: [any UsageProvider]) async -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        var lines = ["\(AppInfo.name) \(AppInfo.version) diagnostics, \(ProcessInfo.processInfo.operatingSystemVersionString)"]
        for provider in providers {
            lines.append("\n== \(provider.id.displayName)")
            do {
                let result = try await provider.fetch()
                lines.append(String(decoding: (try? encoder.encode(result.snapshot)) ?? Data(), as: UTF8.self))
                if !result.context.isEmpty {
                    lines.append("-- plan source: " + result.context.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
                }
                lines.append("-- raw response\n" + String(decoding: result.raw, as: UTF8.self))
            } catch let failure as ParseFailure {
                lines.append("error: \(failure.error.message)")
                lines.append("-- raw response\n" + String(decoding: failure.raw, as: UTF8.self))
            } catch {
                lines.append("error: \(FetchError.wrap(error).message)")
            }
        }
        return lines.joined(separator: "\n")
    }
}

@MainActor
enum Preview {
    static func render(to path: String, dark: Bool, settingsPage: Bool, typeface: Typeface) {
        let now = Date()
        let settings = AppSettings(defaults: UserDefaults(suiteName: "submaxxing-preview")!)
        if settingsPage {
            let store = UsageStore.preview(now: now, settings: settings, codexExpired: true)
            write(SettingsView(store: store, settings: settings, fixedNow: now).environment(\.typeface, typeface), to: path, dark: dark)
        } else {
            let store = UsageStore.preview(now: now, settings: settings)
            write(
                MenuContent(store: store, fixedNow: now, refreshOnAppear: false)
                    .environment(\.typeface, typeface)
                    .background(Color(nsColor: .windowBackgroundColor)),
                to: path, dark: dark
            )
        }
    }

    static func renderFonts(to path: String, dark: Bool) {
        let now = Date()
        let store = UsageStore.preview(now: now, settings: AppSettings(defaults: UserDefaults(suiteName: "submaxxing-preview")!))
        let view = HStack(alignment: .top, spacing: 1) {
            ForEach(Typeface.allCases, id: \.self) { typeface in
                VStack(spacing: 0) {
                    Text(typeface.title).font(.system(size: 12, weight: .bold)).foregroundStyle(.secondary).padding(.top, 12)
                    MenuContent(store: store, fixedNow: now, refreshOnAppear: false).environment(\.typeface, typeface)
                }
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .background(Color(nsColor: .separatorColor))
        write(view, to: path, dark: dark)
    }

    static func renderMenuBar(to path: String) {
        let values: [(ProviderID, Double)] = [(.claude, 15), (.codex, 100), (.cursor, 12)]
        let short = values.map { MenuBarImage.Segment(label: $0.0.shortName, percent: $0.1) }
        let full = values.map { MenuBarImage.Segment(label: $0.0.displayName, percent: $0.1) }
        let rows: [(String, [MenuBarImage.Segment], Bool, Bool)] = [
            ("Compact", [MenuBarImage.Segment(label: nil, percent: 100)], true, true),
            ("Per sub, short", short, true, false),
            ("Per sub, full", full, true, false),
            ("Per sub, no percent", short, false, false),
        ]
        let view = VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 16) {
                    Text(row.0).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
                    Image(nsImage: MenuBarImage.make(row.1, showPercent: row.2, percentSign: row.3))
                }
            }
        }
        .padding(16)
        .background(Color(white: 0.12))
        write(view, to: path, dark: true)
    }

    private static func write(_ view: some View, to path: String, dark: Bool) {
        _ = NSApplication.shared
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = appearance
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.bounds.size
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else {
            print("render failed")
            return
        }
        rep.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        do {
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            print(path)
        } catch {
            print("write failed: \(error.localizedDescription)")
        }
    }
}

extension Typeface {
    var title: String {
        switch self {
        case .system: "SF Pro"
        case .mono: "SF Mono"
        case .rounded: "SF Pro Rounded"
        case .avenir: "Avenir Next"
        }
    }
}
