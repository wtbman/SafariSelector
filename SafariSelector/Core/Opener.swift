import AppKit
import os.log

/// Opens URLs, via the extension when possible and via Safari directly when not.
///
/// The fallback is not a nicety. This app is the system's default browser: if any
/// part of the pipeline fails, the click must still reach Safari rather than
/// vanishing. Every failure path here ends in `openInSafariDirectly`.
final class Opener {

    private let bridge: BridgeServer
    private let log = Logger(subsystem: "cc.wtb.SafariSelector", category: "opener")

    init(bridge: BridgeServer) {
        self.bridge = bridge
    }

    /// Opens `url` in the given target's window, landing in whatever tab group that
    /// window is currently showing.
    func open(_ url: URL, in target: SafariTarget) async {
        let command = Bridge.Command.open(windowId: target.windowId, url: url.absoluteString)
        let result = await bridge.send(command, to: target.profileUUID)
        guard let result, result.ok else {
            log.error("open failed for \(url.absoluteString, privacy: .public): \(result?.error ?? "no response", privacy: .public)")
            openInSafariDirectly(url)
            return
        }
        activateSafari()
    }

    func openInNewWindow(_ url: URL, profileUUID: String) async {
        let result = await bridge.send(.openNewWindow(url: url.absoluteString), to: profileUUID)
        guard let result, result.ok else { openInSafariDirectly(url); return }
        activateSafari()
    }

    /// Last resort: hand the URL to Safari the way the system would have.
    func openInSafariDirectly(_ url: URL) {
        guard let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") else {
            log.fault("Safari not found; dropping \(url.absoluteString, privacy: .public)")
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: safari, configuration: config)
    }

    private func activateSafari() {
        NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.Safari")
            .first?
            .activate()
    }
}
