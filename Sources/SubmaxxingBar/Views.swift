import AppKit
import LimitsCore
import SwiftUI

enum Typeface: String, CaseIterable {
    case system, mono, rounded, avenir

    func font(_ size: CGFloat, _ weight: Font.Weight) -> Font {
        switch self {
        case .system: .system(size: size, weight: weight)
        case .mono: .system(size: size - 1, weight: weight, design: .monospaced)
        case .rounded: .system(size: size, weight: weight, design: .rounded)
        case .avenir: .custom("Avenir Next", size: size + 0.5).weight(weight)
        }
    }
}

private struct TypefaceKey: EnvironmentKey {
    static let defaultValue = Typeface.mono
}

extension EnvironmentValues {
    var typeface: Typeface {
        get { self[TypefaceKey.self] }
        set { self[TypefaceKey.self] = newValue }
    }
}

private struct Face: ViewModifier {
    @Environment(\.typeface) private var typeface
    let size: CGFloat
    let weight: Font.Weight

    func body(content: Content) -> some View {
        content.font(typeface.font(size, weight))
    }
}

extension View {
    func face(_ size: CGFloat, _ weight: Font.Weight = .regular) -> some View {
        modifier(Face(size: size, weight: weight))
    }
}

enum Level {
    static func color(_ percent: Double) -> Color {
        percent >= 90 ? .red : percent >= 70 ? .orange : .green
    }

    static func nsColor(_ percent: Double) -> NSColor {
        percent >= 90 ? .systemRed : percent >= 70 ? .systemOrange : .systemGreen
    }
}

enum MenuBarImage {
    struct Segment: Sendable, Equatable {
        let label: String?
        let percent: Double
    }

    static let height: CGFloat = 16
    static let meterSize = NSSize(width: 7, height: 14)

    static func make(_ segments: [Segment], showPercent: Bool, percentSign: Bool) -> NSImage {
        let width = layout(segments, showPercent: showPercent, percentSign: percentSign, draw: false)
        let image = NSImage(size: NSSize(width: ceil(width), height: height), flipped: false) { _ in
            _ = layout(segments, showPercent: showPercent, percentSign: percentSign, draw: true)
            return true
        }
        image.isTemplate = false
        return image
    }

    @discardableResult
    private static func layout(_ segments: [Segment], showPercent: Bool, percentSign: Bool, draw: Bool) -> CGFloat {
        let valueAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ]
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        var x: CGFloat = 0
        for (index, segment) in segments.enumerated() {
            if index > 0 { x += 9 }
            if let label = segment.label {
                x += text(label, attributes: labelAttributes, at: x, draw: draw) + 4
            }
            if draw { meter(in: NSRect(x: x, y: (height - meterSize.height) / 2, width: meterSize.width, height: meterSize.height), percent: segment.percent) }
            x += meterSize.width
            if showPercent {
                let value = "\(Int(segment.percent.rounded()))" + (percentSign ? "%" : "")
                x += 3 + text(value, attributes: valueAttributes, at: x + 3, draw: draw)
            }
        }
        return x
    }

    private static func text(_ string: String, attributes: [NSAttributedString.Key: Any], at x: CGFloat, draw: Bool) -> CGFloat {
        let size = (string as NSString).size(withAttributes: attributes)
        if draw { (string as NSString).draw(at: NSPoint(x: x, y: (height - size.height) / 2), withAttributes: attributes) }
        return size.width
    }

    private static func meter(in rect: NSRect, percent: Double) {
        let track = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2)
        track.lineWidth = 1
        NSColor.labelColor.withAlphaComponent(0.4).setStroke()
        track.stroke()
        let fill = max(1.5, (rect.height - 3) * min(max(percent, 0), 100) / 100)
        Level.nsColor(percent).setFill()
        NSBezierPath(roundedRect: NSRect(x: rect.minX + 1.5, y: rect.minY + 1.5, width: rect.width - 3, height: fill), xRadius: 1, yRadius: 1).fill()
    }
}

struct MenuContent: View {
    let store: UsageStore
    var fixedNow: Date?
    var refreshOnAppear = true

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let now = fixedNow ?? context.date
            VStack(alignment: .leading, spacing: 14) {
                if store.visible.isEmpty {
                    Text(store.isRefreshing ? "Checking…" : "Nothing to show.")
                        .face(12)
                        .foregroundStyle(.secondary)
                }
                ForEach(store.visible) { id in
                    if let entry = store.entries[id] {
                        ProviderSection(id: id, entry: entry, store: store, now: now)
                    }
                }
                Divider()
                Footer(store: store, now: now)
            }
            .padding(14)
            .frame(width: 290)
            .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear {
            guard refreshOnAppear else { return }
            Task { await store.refresh() }
        }
    }
}

struct ProviderSection: View {
    let id: ProviderID
    let entry: UsageStore.Entry
    let store: UsageStore
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(id.displayName).face(13, .semibold)
                if let plan = entry.snapshot?.plan { PlanBadge(text: plan) }
                Spacer()
                if entry.error != nil, entry.snapshot != nil {
                    Text("stale").face(10, .medium).foregroundStyle(.orange)
                }
            }
            if let snapshot = entry.snapshot {
                let meters = snapshot.meters.filter { store.settings.showSpend || $0.kind == .quota }
                if meters.isEmpty {
                    Text("No limits reported.").face(11).foregroundStyle(.secondary)
                }
                ForEach(meters) { MeterRow(meter: $0, now: now) }
                if id.hasLocalLogs { BreakdownSection(id: id, store: store) }
            }
            if let error = entry.error {
                Text(error.message)
                    .face(11)
                    .foregroundStyle(entry.snapshot == nil ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct BreakdownSection: View {
    static let column: CGFloat = 40

    let id: ProviderID
    let store: UsageStore

    var body: some View {
        let expanded = store.settings.expandedBreakdowns.contains(id)
        VStack(alignment: .leading, spacing: 5) {
            Button {
                if expanded {
                    store.settings.expandedBreakdowns.remove(id)
                } else {
                    store.settings.expandedBreakdowns.insert(id)
                    Task { await store.loadBreakdown(id) }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 8)
                    Text("By model")
                    Spacer()
                    if expanded {
                        Text("5h").frame(width: Self.column, alignment: .trailing)
                        Text("7d").frame(width: Self.column, alignment: .trailing)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .face(11)
            .foregroundStyle(.secondary)
            if expanded {
                if let breakdown = store.breakdowns[id] {
                    if breakdown.rows.isEmpty {
                        Text("No local usage in 7 days.").face(10).foregroundStyle(.tertiary).padding(.leading, 12)
                    }
                    ForEach(breakdown.rows) { row in
                        HStack(spacing: 4) {
                            Text(row.model)
                            Spacer()
                            Text(Self.percent(row.session)).frame(width: Self.column, alignment: .trailing)
                            Text(Self.percent(row.weekly)).frame(width: Self.column, alignment: .trailing)
                        }
                        .face(11)
                        .monospacedDigit()
                        .padding(.leading, 12)
                    }
                    Text(id.breakdownNote).face(9).foregroundStyle(.tertiary).padding(.leading, 12)
                } else {
                    Text("Reading logs…").face(10).foregroundStyle(.tertiary).padding(.leading, 12)
                }
            }
        }
    }

    static func percent(_ share: Double) -> String {
        if share <= 0 { return "0%" }
        if share < 0.01 { return "<1%" }
        return "\(Int((share * 100).rounded()))%"
    }
}

struct PlanBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .face(10, .medium)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
    }
}

struct MeterRow: View {
    let meter: Meter
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(meter.label).face(12)
                Spacer()
                Text("\(Int(meter.usedPercent.rounded()))%").face(12, .semibold).monospacedDigit()
            }
            Bar(fraction: meter.usedPercent / 100, color: Level.color(meter.usedPercent))
            if meter.resetsAt != nil || meter.detail != nil {
                HStack(spacing: 3) {
                    if let reset = meter.resetsAt {
                        Image(systemName: "arrow.clockwise").font(.system(size: 8, weight: .semibold))
                        Text(ResetText.describe(reset, now: now))
                    }
                    Spacer()
                    if let detail = meter.detail { Text(detail) }
                }
                .face(10)
                .foregroundStyle(.secondary)
            }
        }
    }
}

struct Bar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            let clamped = min(max(fraction, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                if clamped > 0 {
                    Capsule().fill(color).frame(width: max(5, geometry.size.width * clamped))
                }
            }
        }
        .frame(height: 5)
    }
}

struct Footer: View {
    let store: UsageStore
    let now: Date

    var body: some View {
        HStack(spacing: 14) {
            Text(status).face(11).foregroundStyle(.tertiary)
            Spacer()
            Button {
                StatusItemController.shared?.closePopover()
                SettingsWindow.shared.show(store: store)
            } label: { Image(systemName: "gearshape") }
                .keyboardShortcut(",")
                .help("Settings")
            Button { Task { await store.refresh(force: true) } } label: { Image(systemName: "arrow.clockwise") }
                .keyboardShortcut("r")
                .help("Refresh")
            Button { NSApplication.shared.terminate(nil) } label: { Image(systemName: "power") }
                .keyboardShortcut("q")
                .help("Quit")
        }
        .font(.system(size: 12))
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    private var status: String {
        if store.isRefreshing { return "Refreshing…" }
        guard let last = store.lastRefresh else { return "" }
        let minutes = Int(now.timeIntervalSince(last) / 60)
        return minutes < 1 ? "Just now" : "\(minutes)m ago"
    }
}

enum ResetText {
    static func describe(_ date: Date, now: Date) -> String {
        let seconds = date.timeIntervalSince(now)
        if seconds <= 0 { return "now" }
        if seconds < 86_400 {
            let hours = Int(seconds) / 3600
            let minutes = (Int(seconds) % 3600) / 60
            return hours > 0 ? "\(hours)h \(minutes)m" : "\(max(minutes, 1))m"
        }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate(seconds < 7 * 86_400 ? "EEE j:mm" : "MMM d")
        return formatter.string(from: date)
    }
}
