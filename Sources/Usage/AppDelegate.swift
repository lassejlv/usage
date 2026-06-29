import AppKit
import Combine
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var eventMonitor: Any?
    private let registry = ProviderRegistry.makeDefault()
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
            .sink { [weak self] snapshots in self?.updateStatusItemIcon(snapshots: snapshots) }
            .store(in: &cancellables)
    }

    private func updateStatusItemIcon(snapshots: [ProviderSnapshot]? = nil) {
        guard let button = statusItem.button else { return }
        switch registry.settings.iconStyle {
        case .bars:
            button.image = makeBarsStatusImage(snapshots: snapshots ?? registry.snapshots)
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

    private func makeBarsStatusImage(snapshots: [ProviderSnapshot]) -> NSImage {
        let metrics = statusBarMetrics(snapshots: snapshots)
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

    private func statusBarMetrics(snapshots: [ProviderSnapshot]) -> [Double] {
        let preferredLabels = ["Weekly", "Session"]
        // The first two providers, each contributing its two headline metrics — four bars when both
        // exist, two when only one provider is enabled.
        let chosen = Array(snapshots.prefix(2))
        guard !chosen.isEmpty else { return [0.18, 0.18, 0.18, 0.18] }

        var fractions: [Double] = []
        for snapshot in chosen {
            let preferredMetrics = preferredLabels.compactMap { label in
                snapshot.metrics.first { $0.label.localizedCaseInsensitiveContains(label) }
            }
            let metrics =
                preferredMetrics.isEmpty ? Array(snapshot.metrics.prefix(2)) : preferredMetrics
            var pair = metrics.map(\.fraction)
            if pair.isEmpty {
                pair = [0.18, 0.18]
            } else if pair.count == 1 {
                pair = [pair[0], pair[0]]
            }
            fractions.append(contentsOf: pair.prefix(2))
        }
        return fractions
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
