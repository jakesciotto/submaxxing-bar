import AppKit
import LimitsCore
import SwiftUI

@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()
    private var window: NSWindow?

    func show(store: UsageStore) {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(store: store, settings: store.settings)))
            window.title = AppInfo.name
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    static let column: CGFloat = 64

    let store: UsageStore
    @Bindable var settings: AppSettings
    var fixedNow: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Form {
                Section("Subscriptions") {
                    HStack(spacing: 0) {
                        Spacer()
                        Text("Popover").frame(width: Self.column)
                        Text("Menu bar").frame(width: Self.column)
                    }
                    .face(10, .medium)
                    .foregroundStyle(.secondary)
                    ForEach(ProviderID.allCases) { id in
                        ProviderRow(id: id, store: store, settings: settings, now: fixedNow ?? context.date)
                    }
                }
                Section("Menu bar") {
                    Picker("Style", selection: $settings.menuBarStyle) {
                        ForEach(MenuBarStyle.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Picker("Labels", selection: $settings.menuBarLabels) {
                        ForEach(MenuBarLabels.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .disabled(settings.menuBarStyle == .compact)
                    Toggle("Show percent", isOn: $settings.showPercent)
                }
                Section("Popover") {
                    Toggle(isOn: $settings.showSpend) {
                        Text("Show spend rows")
                        Text("Extra usage, credits, on-demand")
                    }
                }
                Section("Refresh") {
                    Picker("Check every", selection: $settings.refreshMinutes) {
                        ForEach(AppSettings.refreshChoices, id: \.self) { Text("\($0) min").tag($0) }
                    }
                    Toggle("Launch at login", isOn: $settings.launchAtLogin)
                    if let error = settings.launchAtLoginError {
                        Text(error).face(11).foregroundStyle(.red)
                    }
                }
                Section {
                    LabeledContent {
                        Button("Copy") { Task { await store.copyDiagnostics() } }
                    } label: {
                        Text("Diagnostics")
                        Text(store.diagnosticsMessage ?? "No tokens included.")
                    }
                } footer: {
                    Text("\(AppInfo.name) \(AppInfo.version)").face(10).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .formStyle(.grouped)
            .face(13)
            .scrollDisabled(true)
            .frame(width: 480)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct ProviderRow: View {
    let id: ProviderID
    let store: UsageStore
    let settings: AppSettings
    let now: Date

    var body: some View {
        let status = self.status
        HStack(spacing: 10) {
            Circle().fill(status.color).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(id.displayName).face(13, .medium)
                    if let plan = store.entries[id]?.snapshot?.plan { PlanBadge(text: plan) }
                }
                Text(status.text)
                    .face(11)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("Show \(id.displayName) in popover", isOn: popoverBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .frame(width: SettingsView.column)
            Toggle("Show \(id.displayName) in menu bar", isOn: menuBarBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .frame(width: SettingsView.column)
                .disabled(!settings.enabled.contains(id))
        }
        .padding(.vertical, 2)
        .help(id.sourceDescription)
    }

    private var popoverBinding: Binding<Bool> {
        Binding(
            get: { settings.enabled.contains(id) },
            set: { isOn in
                if isOn {
                    settings.enabled.insert(id)
                    Task { await store.refresh(force: true) }
                } else {
                    settings.enabled.remove(id)
                }
            }
        )
    }

    private var menuBarBinding: Binding<Bool> {
        Binding(
            get: { settings.enabled.contains(id) && settings.menuBarProviders.contains(id) },
            set: { isOn in
                if isOn { settings.menuBarProviders.insert(id) } else { settings.menuBarProviders.remove(id) }
            }
        )
    }

    private var status: (color: Color, text: String) {
        guard settings.enabled.contains(id) else { return (.gray, "Hidden") }
        guard let entry = store.entries[id] else { return (.gray, "Checking…") }
        switch (entry.snapshot, entry.error) {
        case (let snapshot?, nil):
            let minutes = Int(now.timeIntervalSince(snapshot.fetchedAt) / 60)
            return (.green, minutes < 1 ? "Updated now" : "Updated \(minutes)m ago")
        case (_, .notConfigured?):
            return (.gray, "Not found")
        case (_, .needsSignIn(let hint)?):
            return (.orange, hint)
        case (_?, let error?):
            return (.orange, "Stale. \(error.message)")
        case (nil, let error?):
            return (.red, error.message)
        case (nil, nil):
            return (.gray, "Checking…")
        }
    }
}
