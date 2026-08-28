import AppKit
import Foundation

/// Which application a URL arrived from.
///
/// `application(_:open:)` does not say. The authoritative answer is on the Apple
/// Event that carried the URL: LaunchServices tags it with the sender's pid. That is
/// exact when present — including for links opened programmatically by an app that
/// never came to the front, which is the case worth catching.
enum LinkSource {

    struct Info {
        let name: String
        let bundleIdentifier: String?
        let icon: NSImage?
    }

    /// `keySenderPIDAttr` — not exposed in Swift's Carbon overlay.
    private static let senderPIDAttribute = AEKeyword(0x73706964)  // 'spid'

    /// The last application to be frontmost that wasn't us. LaunchServices may have
    /// already activated this app by the time a URL is delivered, so the frontmost
    /// app is often no help on its own.
    private(set) static var lastForegroundApp: NSRunningApplication?

    /// Starts tracking foreground apps. Call once at launch.
    static func beginTracking() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                           object: nil, queue: .main) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                  app.bundleIdentifier != Bundle.main.bundleIdentifier
            else { return }
            lastForegroundApp = app
        }
        lastForegroundApp = NSWorkspace.shared.frontmostApplication
    }

    /// Must be read while handling the open, before the Apple Event goes away.
    ///
    /// The Apple Event's sender pid is authoritative and catches an app that opened a
    /// link without ever coming to the front — the case that matters for links fired
    /// by an AI assistant. The tracked foreground app is the fallback.
    static func current() -> Info? {
        let candidate = fromCurrentAppleEvent()
            ?? nonSelf(NSWorkspace.shared.frontmostApplication)
            ?? lastForegroundApp
        guard let app = nonSelf(candidate) else { return nil }
        return Info(name: app.localizedName ?? "Unknown",
                    bundleIdentifier: app.bundleIdentifier,
                    icon: app.icon)
    }

    private static func nonSelf(_ app: NSRunningApplication?) -> NSRunningApplication? {
        guard let app, app.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
        return app
    }

    private static func fromCurrentAppleEvent() -> NSRunningApplication? {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              let descriptor = event.attributeDescriptor(forKeyword: senderPIDAttribute)
        else { return nil }
        let pid = descriptor.int32Value
        guard pid > 0 else { return nil }
        return NSRunningApplication(processIdentifier: pid)
    }
}
