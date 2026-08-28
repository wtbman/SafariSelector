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
    private var pendingSource: LinkSource.Info?
    /// Whether the user has interacted with the current picker. Clicking away after
    /// interacting is a dismissal, not an unattended timeout.
    private var pickerWasTouched = false
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
        bridge.statusProvider = { [weak self] connected in
            guard let self else { return Data("[]".utf8) }
            // Deliberately does not block on a rebuild: this runs on the bridge
            // queue, and the AppleScript pass belongs on its own queue.
            self.store.rebuild()
            let rows = self.store.targets.map {
                [
                    "profileUUID": $0.profileUUID,
                    "profileLabel": $0.profileLabel,
                    "windowId": $0.windowId,
                    "tabGroupLabel": $0.tabGroupLabel ?? "(loose tabs)",
                    "activeTabTitle": $0.activeTabTitle,
                    "tabCount": $0.tabCount,
                    "asBounds": $0.bounds.map { "\($0.left),\($0.top) \($0.width)x\($0.height)" } ?? "-",
                    "asID": $0.appleScriptWindowID ?? -1,
                    "focused": $0.isFocused,
                ] as [String: Any]
            }
            let payload: [String: Any] = [
                "connectedProfiles": connected,
                "rawWindowCounts": self.store.rawCounts,
                "rawWindows": self.store.rawWindows,
                "targets": rows,
            ]
            return (try? JSONSerialization.data(withJSONObject: payload,
                                                options: [.prettyPrinted, .sortedKeys])) ?? Data("[]".utf8)
        }
        LinkSource.beginTracking()
        bridge.start()
        opener = Opener(bridge: bridge, store: store)
        setUpStatusItem()
    }

    // MARK: - URL entry point

    func application(_ application: NSApplication, open urls: [URL]) {
        // Must be read now, while the Apple Event that carried the URL still exists.
        let source = LinkSource.current()
        DebugLog.write("open urls: \(urls.map(\.absoluteString)) from: \(source?.name ?? "unknown")")
        pendingSource = source
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
            if let rule = config.rule(for: url) {
                DebugLog.write("rule matched: pattern=\(rule.pattern) group=\(rule.tabGroupLabel ?? "-")")
            }
            if let rule = config.rule(for: url), let target = resolve(rule) {
                DebugLog.write("rule -> target \(target.displayLabel) warm=\(target.isWarm) asID=\(target.appleScriptWindowID ?? -1)")
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
        DebugLog.write("no rule/memory match; showing picker (targets=\(store.targets.count))")
        showPicker(for: url, batch: batch)
    }

    /// A rule names a tab group, not a window id, so that it survives window churn.
    ///
    /// Prefers a warm target, but will happily return a cold one: a cold target still
    /// carries the AppleScript window id, and the opener knows how to wake its profile.
    /// Requiring warmth here would make rules silently stop working for any profile
    /// Safari had let go dormant.
    private func resolve(_ rule: Config.Rule) -> SafariTarget? {
        func matches(_ t: SafariTarget) -> Bool {
            guard let group = rule.tabGroupLabel else { return t.profileUUID == rule.profileUUID }
            return t.tabGroupLabel == group
                && (t.profileUUID == nil || t.profileUUID == rule.profileUUID)
        }
        let candidates = store.targets.filter(matches)
        return candidates.first(where: \.isWarm) ?? candidates.first
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
        // Labels come from AppleScript, which changes independently of the bridge,
        // so refresh them before showing the list rather than after.
        store.rebuild { [weak self] in
            self?.presentPicker(for: url, batch: batch)
        }
    }

    private func presentPicker(for url: URL, batch: [URL]) {
        panel?.dismiss()
        let targets = store.targets
        let autoTarget = config.stored.autoSelectSeconds > 0
            ? config.autoSelectTarget(from: targets) : nil

        // A link must be acted on exactly once. The countdown, a click, a keypress
        // and clicking away can all race, so every route funnels through here.
        var settled = false
        var created: SelectorPanel?
        let settle: (@escaping () -> Void) -> Void = { action in
            guard !settled else { return }
            settled = true
            created?.dismiss()
            self.panel = nil
            action()
        }

        let view = SelectorView(
            url: url,
            targets: targets,
            source: pendingSource,
            autoSelectSeconds: config.stored.autoSelectSeconds,
            autoTarget: autoTarget,
            onChoose: { target in
                settle { self.open(batch, in: target, remember: true) }
            },
            onNewWindow: { target in
                settle {
                    Task { await self.opener.openInNewWindow(url, profileUUID: target.profileUUID) }
                }
            },
            onFallback: {
                settle { batch.forEach { self.opener.openInSafariDirectly($0) } }
            },
            onCancel: {
                // Escape is an explicit "not now"; the link is deliberately dropped.
                settle { DebugLog.write("cancelled by user") }
            },
            onInteraction: { [weak self] in
                // Once the user has touched the picker, clicking away is no longer an
                // unattended dismissal, so it must not auto-open anything.
                self?.pickerWasTouched = true
            }
        )

        let p = SelectorPanel(content: view) { [weak self] in
            guard let self else { return }
            // Clicked away without choosing. If an auto-select target is configured,
            // act on it immediately rather than making the user wait out a countdown
            // they can no longer see.
            if let autoTarget, !self.pickerWasTouched {
                DebugLog.write("clicked away; auto-selecting \(autoTarget.displayLabel)")
                settle { self.open(batch, in: autoTarget, remember: false) }
            } else {
                // No default configured: hand the link to Safari rather than drop it.
                DebugLog.write("clicked away with no auto-select target; opening in Safari")
                settle { batch.forEach { self.opener.openInSafariDirectly($0) } }
            }
        }
        created = p
        panel = p
        pickerWasTouched = false
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
        menu.addItem(NSMenuItem(title: "Settings…",
                                action: #selector(showPreferences), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit SafariSelector",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for item in menu.items where item.action == #selector(refresh) || item.action == #selector(showPreferences) {
            item.target = self
        }
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

    private var preferencesWindow: NSWindow?

    @objc private func showPreferences() {
        store.rebuild()
        if let existing = preferencesWindow {
            NSApp.activate(ignoringOtherApps: true)
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let view = PreferencesView(config: config, store: store) { [weak self] in
            self?.bridge.connectedProfiles ?? []
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 380),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "SafariSelector Settings"
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.isReleasedWhenClosed = false
        preferencesWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
