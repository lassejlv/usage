import AppKit
import Combine
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var eventMonitor: Any?
    private var keyMonitor: Any?
    private let registry = ProviderRegistry.makeDefault()
    private let paceNotifier = PaceNotifier()
    private var refreshTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar (tray) only — no Dock icon, no main window.
        NSApp.setActivationPolicy(.accessory)

        // The popover content: a SwiftUI panel bound to the provider registry.
        popover.contentSize = NSSize(width: 360, height: 460)
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(rootView: PanelView(registry: registry))

        // The status bar item (tray icon).
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            updateStatusItemIcon()
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        // Close the popover when clicking outside of it.
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [
            .leftMouseDown, .rightMouseDown,
        ]) { [weak self] _ in
            guard let self, self.popover.isShown else { return }
            self.closePopover()
        }

        // Keyboard shortcuts active only while the popover is the key surface (the app is a menu-bar
        // accessory with no menu, so we handle them ourselves). ⌘Q quits, ⌘R refreshes everything.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            self?.handleKeyDown(event) ?? event
        }

        // Initial fetch (forced past the throttle), then refresh on a timer so the bars stay current.
        Task { await registry.refreshAll(force: true) }
        scheduleRefreshTimer()
        registry.settings.$refreshIntervalPreset
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleRefreshTimer() }
            .store(in: &cancellables)
        registry.settings.$customRefreshMinutes
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleRefreshTimer() }
            .store(in: &cancellables)
        syncLaunchAtLoginStatus()
        registry.settings.$launchAtLogin
            .dropFirst()
            .sink { [weak self] isEnabled in self?.applyLaunchAtLogin(isEnabled) }
            .store(in: &cancellables)
        registry.settings.$iconStyle
            .dropFirst()
            .sink { [weak self] _ in self?.updateStatusItemIcon() }
            .store(in: &cancellables)
        registry.$snapshots
            .dropFirst()
            .sink { [weak self] snapshots in
                guard let self else { return }
                self.updateStatusItemIcon(snapshots: snapshots)
                self.paceNotifier.evaluate(snapshots: snapshots, settings: self.registry.settings)
            }
            .store(in: &cancellables)
        paceNotifier.configure(enabled: registry.settings.notificationsEnabled)
        registry.settings.$notificationsEnabled
            .dropFirst()
            .sink { [weak self] enabled in self?.paceNotifier.setEnabled(enabled) }
            .store(in: &cancellables)
        registry.$selectedProviderID
            .dropFirst()
            .sink { [weak self] id in self?.updateStatusItemIcon(selectedID: id) }
            .store(in: &cancellables)
    }

    /// `selectedID` is a double optional so the publisher can hand us the just-committed value:
    /// `.some(value)` uses `value` (a `nil` inside means Overview), while `.none` falls back to the
    /// live property. @Published fires during `willSet`, so re-reading the property in the
    /// `$selectedProviderID` sink would see the *old* selection — hence we pass the new value through.
    private func updateStatusItemIcon(snapshots: [ProviderSnapshot]? = nil, selectedID: String?? = .none) {
        guard let button = statusItem.button else { return }
        switch registry.settings.iconStyle {
        case .bars:
            let resolvedSelection = selectedID ?? registry.selectedProviderID
            button.image = makeBarsStatusImage(
                snapshots: snapshots ?? registry.snapshots, selectedID: resolvedSelection)
            button.image?.isTemplate = true
        case .gauge, .percent:
            button.image = NSImage(
                systemSymbolName: registry.settings.iconStyle.systemImageName,
                accessibilityDescription: "Usage"
            )
            button.image?.isTemplate = true
        }
        button.needsDisplay = true
    }

    private func makeBarsStatusImage(snapshots: [ProviderSnapshot], selectedID: String?) -> NSImage {
        let metrics = statusBarMetrics(snapshots: snapshots, selectedID: selectedID)
        let size = NSSize(width: 22, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()

        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()

        let count = max(metrics.count, 1)
        // Thinner bars/gaps once we go past two so four still fit within the icon height.
        let barHeight: CGFloat = count > 2 ? 2 : 3
        let barGap: CGFloat = count > 2 ? 2 : 3
        let cornerRadius: CGFloat = count > 2 ? 1 : 1.5
        let maxBarWidth: CGFloat = 16
        let x: CGFloat = 3
        let totalHeight = barHeight * CGFloat(count) + barGap * CGFloat(count - 1)
        let yStart = (size.height - totalHeight) / 2

        for (index, fraction) in metrics.enumerated() {
            // Draw top-to-bottom so the first provider's metrics sit at the top of the icon.
            let y = yStart + CGFloat(count - 1 - index) * (barHeight + barGap)
            let backgroundRect = NSRect(x: x, y: y, width: maxBarWidth, height: barHeight)
            NSColor.black.withAlphaComponent(0.28).setFill()
            NSBezierPath(roundedRect: backgroundRect, xRadius: cornerRadius, yRadius: cornerRadius).fill()

            let fillWidth = max(2, maxBarWidth * CGFloat(min(max(fraction, 0), 1)))
            let fillRect = NSRect(x: x, y: y, width: fillWidth, height: barHeight)
            NSColor.black.setFill()
            NSBezierPath(roundedRect: fillRect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
        }

        image.unlockFocus()
        return image
    }

    private func statusBarMetrics(snapshots: [ProviderSnapshot], selectedID: String?) -> [Double] {
        // A selected provider tab drives the icon directly (two bars for its headline metrics).
        // The Overview tab always shows four bars — the first two providers' headline pairs.
        if let id = selectedID,
           let snapshot = snapshots.first(where: { $0.provider.id == id }) {
            return headlineFractions(snapshot)
        }

        let fractions = snapshots.prefix(2).flatMap(headlineFractions)
        // Pad with placeholders when fewer than two providers are present so Overview stays four bars.
        return Array((fractions + [0.18, 0.18, 0.18, 0.18]).prefix(4))
    }

    /// A provider's two headline bars for the tray icon, mirroring its card: the "Session"/"Weekly"
    /// meters in their natural card order (else the first two metrics), as REMAINING fractions so a
    /// fuller bar means more left — matching the card and tab visuals (drawn top-to-bottom, index 0 on
    /// top, so Session sits above Weekly just like the card rows). Padded to two for a consistent pair.
    private func headlineFractions(_ snapshot: ProviderSnapshot) -> [Double] {
        let headlineLabels = ["Session", "Weekly"]
        let headline = snapshot.metrics.filter { metric in
            headlineLabels.contains { metric.label.localizedCaseInsensitiveContains($0) }
        }
        let metrics = headline.isEmpty ? Array(snapshot.metrics.prefix(2)) : headline
        var pair = Array(metrics.prefix(2)).map(\.remainingFraction)
        if pair.isEmpty {
            pair = [0.18, 0.18]
        } else if pair.count == 1 {
            pair = [pair[0], pair[0]]
        }
        return pair
    }

    /// Handle ⌘Q / ⌘R, but only while the popover is shown — otherwise pass the event through so we
    /// never swallow shortcuts meant for whatever app is frontmost.
    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        guard popover.isShown, event.modifierFlags.contains(.command) else { return event }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "q":
            NSApp.terminate(nil)
            return nil
        case "r":
            Task { await registry.refreshAll(force: true) }
            return nil
        default:
            return event
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        // Refresh on open only when the numbers are stale; recent data is shown as-is so reopening the
        // popover can't spam the endpoint.
        if registry.isStale() {
            Task { await registry.refreshAll() }
        }
    }

    private func closePopover() {
        popover.performClose(nil)
    }

    private func scheduleRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(
            withTimeInterval: registry.settings.refreshIntervalSeconds, repeats: true
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.registry.refreshAll() }
        }
    }

    private func syncLaunchAtLoginStatus() {
        registry.settings.launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func applyLaunchAtLogin(_ isEnabled: Bool) {
        do {
            if isEnabled, SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            } else if !isEnabled, SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            registry.settings.launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
