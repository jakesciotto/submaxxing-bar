import AppKit
import Foundation
import LimitsCore
import Observation

@MainActor
@Observable
final class UsageStore {
    struct Entry {
        var snapshot: UsageSnapshot?
        var error: FetchError?
    }

    private(set) var entries: [ProviderID: Entry] = [:]
    private(set) var isRefreshing = false
    private(set) var lastRefresh: Date?
    private(set) var diagnosticsMessage: String?
    @ObservationIgnored let settings: AppSettings
    @ObservationIgnored private let providers: [any UsageProvider]
    @ObservationIgnored private var loop: Task<Void, Never>?

    init(providers: [any UsageProvider], settings: AppSettings) {
        self.providers = providers
        self.settings = settings
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.refresh(force: true)
                try? await Task.sleep(for: .seconds(self.settings.refreshMinutes * 60))
            }
        }
    }

    func refresh(force: Bool = false) async {
        guard !isRefreshing else { return }
        if !force, let lastRefresh, Date().timeIntervalSince(lastRefresh) < 60 { return }
        isRefreshing = true
        let active = providers.filter { settings.enabled.contains($0.id) }
        let results = await withTaskGroup(of: (ProviderID, Result<UsageSnapshot, FetchError>).self) { group in
            for provider in active {
                group.addTask {
                    do {
                        return (provider.id, .success(try await provider.fetch().snapshot))
                    } catch {
                        return (provider.id, .failure(FetchError.wrap(error)))
                    }
                }
            }
            var collected: [(ProviderID, Result<UsageSnapshot, FetchError>)] = []
            for await item in group { collected.append(item) }
            return collected
        }
        for (id, result) in results {
            var entry = entries[id] ?? Entry()
            switch result {
            case .success(let snapshot):
                entry.snapshot = snapshot
                entry.error = nil
            case .failure(let error):
                entry.error = error
            }
            entries[id] = entry
        }
        lastRefresh = Date()
        isRefreshing = false
    }

    func copyDiagnostics() async {
        diagnosticsMessage = "Collecting…"
        let report = await Diagnostics.report(providers: providers)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        diagnosticsMessage = "Copied."
    }

    var visible: [ProviderID] {
        ProviderID.allCases.filter { id in
            guard settings.enabled.contains(id), let entry = entries[id] else { return false }
            return entry.snapshot != nil || entry.error != .notConfigured
        }
    }

    var menuBarSegments: [MenuBarImage.Segment] {
        let items = visible
            .filter { settings.menuBarProviders.contains($0) }
            .compactMap { id in entries[id]?.snapshot?.peakPercent.map { (id: id, percent: $0) } }
        switch settings.menuBarStyle {
        case .compact:
            guard let peak = items.map(\.percent).max() else { return [] }
            return [MenuBarImage.Segment(label: nil, percent: peak)]
        case .perSub:
            return items.map {
                MenuBarImage.Segment(label: settings.menuBarLabels == .short ? $0.id.shortName : $0.id.displayName, percent: $0.percent)
            }
        }
    }

    static func preview(now: Date, settings: AppSettings, codexExpired: Bool = false) -> UsageStore {
        let store = UsageStore(providers: [], settings: settings)
        for snapshot in Demo.snapshots(now: now) {
            store.entries[snapshot.provider] = Entry(snapshot: snapshot)
        }
        if codexExpired {
            store.entries[.codex] = Entry(error: .needsSignIn("Sign-in expired. Open Codex in ChatGPT."))
        }
        store.lastRefresh = now.addingTimeInterval(-120)
        return store
    }
}
