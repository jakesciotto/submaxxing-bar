import AppKit
import LimitsCore
import Observation
import SwiftUI

@MainActor
final class StatusItemController: NSObject {
    private(set) static var shared: StatusItemController?

    private let store: UsageStore
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()

    init(store: UsageStore) {
        self.store = store
        super.init()
        item.autosaveName = "submaxxing-bar"
        item.button?.target = self
        item.button?.action = #selector(toggle)
        item.button?.toolTip = AppInfo.name
        let hosting = NSHostingController(rootView: MenuContent(store: store, refreshOnAppear: false))
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        popover.behavior = .transient
        Self.shared = self
        observeLabel()
    }

    func closePopover() {
        popover.performClose(nil)
    }

    private func observeLabel() {
        withObservationTracking {
            renderLabel()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeLabel() }
        }
    }

    private func renderLabel() {
        let segments = store.menuBarSegments
        let settings = store.settings
        if segments.isEmpty {
            let image = NSImage(systemSymbolName: "gauge.with.dots.needle.33percent", accessibilityDescription: AppInfo.name)
            image?.isTemplate = true
            item.button?.image = image
        } else {
            item.button?.image = MenuBarImage.make(
                segments,
                showPercent: settings.showPercent,
                percentSign: settings.menuBarStyle == .compact
            )
        }
    }

    @objc private func toggle() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = item.button else { return }
        Task { await store.refresh() }
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
}
