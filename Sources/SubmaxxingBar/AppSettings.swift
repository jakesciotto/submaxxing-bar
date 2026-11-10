import Foundation
import LimitsCore
import Observation
import ServiceManagement

enum MenuBarStyle: String, CaseIterable, Identifiable {
    case compact, perSub

    var id: String { rawValue }
    var title: String { self == .compact ? "Compact" : "Per sub" }
}

enum MenuBarLabels: String, CaseIterable, Identifiable {
    case short, full

    var id: String { rawValue }
    var title: String { self == .short ? "Short" : "Full" }
}

extension ProviderID {
    var sourceDescription: String {
        switch self {
        case .claude: "Keychain"
        case .codex: "~/.codex/auth.json"
        case .cursor: "Cursor app"
        }
    }

    var shortName: String {
        switch self {
        case .claude: "Cl"
        case .codex: "Cx"
        case .cursor: "Cu"
        }
    }
}

@MainActor
@Observable
final class AppSettings {
    static let refreshChoices = [5, 10, 15, 30]
    static let off = "off"
    static let highest = "highest"

    @ObservationIgnored private let defaults: UserDefaults

    var enabled: Set<ProviderID> {
        didSet { save(enabled, forKey: "enabled") }
    }
    var menuBarChoices: [ProviderID: String] {
        didSet {
            let stored = Dictionary(uniqueKeysWithValues: menuBarChoices.map { ($0.key.rawValue, $0.value) })
            defaults.set(stored, forKey: "menuBarChoices")
        }
    }
    var menuBarStyle: MenuBarStyle {
        didSet { defaults.set(menuBarStyle.rawValue, forKey: "menuBarStyle") }
    }
    var menuBarLabels: MenuBarLabels {
        didSet { defaults.set(menuBarLabels.rawValue, forKey: "menuBarLabels") }
    }
    var showPercent: Bool {
        didSet { defaults.set(showPercent, forKey: "showPercent") }
    }
    var showSpend: Bool {
        didSet { defaults.set(showSpend, forKey: "showSpend") }
    }
    var refreshMinutes: Int {
        didSet { defaults.set(refreshMinutes, forKey: "refreshMinutes") }
    }
    var launchAtLogin: Bool {
        didSet { applyLaunchAtLogin() }
    }
    var launchAtLoginError: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = Self.providers(defaults, forKey: "enabled")
        if let stored = defaults.dictionary(forKey: "menuBarChoices") as? [String: String] {
            menuBarChoices = Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in
                ProviderID(rawValue: key).map { ($0, value) }
            })
        } else {
            let legacy = defaults.stringArray(forKey: "menuBarProviders")
            menuBarChoices = Dictionary(uniqueKeysWithValues: ProviderID.allCases.map { id in
                (id, legacy.map { $0.contains(id.rawValue) ? Self.highest : Self.off } ?? Self.highest)
            })
        }
        menuBarStyle = MenuBarStyle(rawValue: defaults.string(forKey: "menuBarStyle") ?? "") ?? .compact
        menuBarLabels = MenuBarLabels(rawValue: defaults.string(forKey: "menuBarLabels") ?? "") ?? .short
        showPercent = defaults.object(forKey: "showPercent") as? Bool ?? true
        showSpend = defaults.object(forKey: "showSpend") as? Bool ?? true
        let storedMinutes = defaults.object(forKey: "refreshMinutes") as? Int ?? 5
        refreshMinutes = Self.refreshChoices.contains(storedMinutes) ? storedMinutes : 5
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func menuBarChoice(for id: ProviderID) -> String {
        menuBarChoices[id] ?? Self.highest
    }

    private static func providers(_ defaults: UserDefaults, forKey key: String) -> Set<ProviderID> {
        let stored = defaults.stringArray(forKey: key) ?? ProviderID.allCases.map(\.rawValue)
        return Set(stored.compactMap(ProviderID.init(rawValue:)))
    }

    private func save(_ providers: Set<ProviderID>, forKey key: String) {
        defaults.set(providers.map(\.rawValue).sorted(), forKey: key)
    }

    private func applyLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if launchAtLogin, service.status != .enabled { try service.register() }
            if !launchAtLogin, service.status == .enabled { try service.unregister() }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
        }
    }
}
