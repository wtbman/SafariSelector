import AppKit
import SwiftUI
import os.log


final class AppDelegate: NSObject, NSApplicationDelegate {

    private let log = Logger(subsystem: "cc.wtb.SafariSelector", category: "app")
    private let config = Config()
    private var bridge: BridgeServer!
    private var store: TargetStore!
    private var opener: Opener!
    private var panel: SelectorPanel?
    private var statusItem: NSStatusItem?

    /// This app is the system's default browser. It must never route to itself.
    private static let ownBundleID = Bundle.main.bundleIdentifier ?? "cc.wtb.SafariSelector"

    func applicationDidFinishLaunching(_ notification: Notification) {
        FileHandle.standardError.write(Data("SafariSelector launched\n".utf8))
        store = TargetStore(config: config)
        do {
            bridge = try BridgeServer()
        } catch {
            log.fault("bridge failed to start: \(String(describing: error), privacy: .public)")
            FileHandle.standardError.write(Data("bridge init failed: \(error)\n".utf8))
            return
        }
        bridge.onSnapshot = { [weak self] profile, windows in
            self?.store.update(profileUUID: profile, windows: windows)
        }
        bridge.start()
        opener = Opener(bridge: bridge)
        setUpStatusItem()
    }

    // MARK: - URL entry point

    func application(_ application: NSApplication, open urls: [URL]) {
        let webURLs = urls.filter { ($0.scheme == "http" || $0.scheme == "https") }
        // Anything else LaunchServices hands us is not ours to mediate.
        for other in urls where !webURLs.contains(other) {
            opener.openInSafariDirectly(other)
        }
        guard let url = webURLs.first else { return }
        route(url, batch: webURLs)
    }

    private func route(_ url: URL, batch: [URL]) {
        let modifiers = NSEvent.modifierFlags

        // Shift bypasses the picker and reuses the last target; Option forces it.
        if !modifiers.contains(.option) {
            if let rule = config.rule(for: url), let target = resolve(rule) {
                open(batch, in: target, remember: false)
                return
            }
            if modifiers.contains(.shift),
               let id = config.preferredTargetID(for: url),
               let target = store.targets.first(where: { $0.id == id }) {
                open(batch, in: target, remember: false)
                return
            }
        }
        showPicker(for: url, batch: batch)
    }

    /// A rule names a tab group, not a window id, so that it survives window churn.
    private func resolve(_ rule: Config.Rule) -> SafariTarget? {
        store.targets.first {
            $0.profileUUID == rule.profileUUID
                && (rule.tabGroupLabel == nil || $0.tabGroupLabel == rule.tabGroupLabel)
        }
    }

    private func open(_ urls: [URL], in target: SafariTarget, remember: Bool) {
        Task {
            for url in urls {
                await opener.open(url, in: target)
                if remember { config.rememberChoice(target, for: url) }
            }
        }
    }

    // MARK: - Picker

    private func showPicker(for url: URL, batch: [URL]) {
        // Labels come from AppleScript, which changes independently of the bridge.
        store.rebuild()

        panel?.dismiss()
        let targets = store.targets
        var created: SelectorPanel?

        let view = SelectorView(
            url: url,
            targets: targets,
            onChoose: { [weak self] target in
                created?.dismiss(); self?.panel = nil
                self?.open(batch, in: target, remember: true)
            },
            onNewWindow: { [weak self] target in
                created?.dismiss(); self?.panel = nil
                Task { await self?.opener.openInNewWindow(url, profileUUID: target.profileUUID) }
            },
            onFallback: { [weak self] in
                created?.dismiss(); self?.panel = nil
                batch.forEach { self?.opener.openInSafariDirectly($0) }
            },
            onCancel: { [weak self] in
                created?.dismiss(); self?.panel = nil
            }
        )

        let p = SelectorPanel(content: view) { [weak self] in
            self?.panel?.dismiss()
            self?.panel = nil
        }
        created = p
        panel = p
        p.showCentredOnPointerScreen()
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "arrow.triangle.branch",
                                     accessibilityDescription: "SafariSelector")
        let menu = NSMenu()
        menu.addItem(withTitle: "SafariSelector", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        let status = NSMenuItem(title: "Connected profiles: —", action: nil, keyEquivalent: "")
        menu.addItem(status)
        menu.addItem(NSMenuItem(title: "Refresh Windows",
                                action: #selector(refresh), keyEquivalent: "r"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit SafariSelector",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.items.forEach { $0.target = $0.action == #selector(refresh) ? self : $0.target }
        item.menu = menu
        statusItem = item

        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            let n = self.bridge.connectedProfiles.count
            status.title = "Connected profiles: \(n)"
        }
    }

    @objc private func refresh() {
        store.rebuild()
    }
}
