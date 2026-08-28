//
//  SafariSelector — open links in a chosen Safari window's active tab group.
//  Copyright (C) 2026 SafariSelector contributors
//
//  This program is free software: you can redistribute it and/or modify it under
//  the terms of the GNU General Public License as published by the Free Software
//  Foundation, either version 3 of the License, or (at your option) any later
//  version. See <https://www.gnu.org/licenses/>.
//

import AppKit
import os.log

/// Reading and setting the system default browser.
///
/// System Settings' "Default web browser" popup applies its own filter and will not
/// list this app, even though LaunchServices registers it correctly as an http/https
/// handler — `NSWorkspace.urlsForApplications(toOpen:)` returns it alongside Safari
/// and Firefox. Other registered handlers are hidden from that popup too. So the
/// supported path is to ask for it directly, which raises the system's own
/// confirmation prompt.
enum DefaultBrowser {

    private static let log = Logger(subsystem: "cc.wtb.SafariSelector", category: "default")
    private static let probe = URL(string: "https://example.com")!

    static var current: URL? {
        NSWorkspace.shared.urlForApplication(toOpen: probe)
    }

    static var isSafariSelector: Bool {
        current?.bundleIdentifierIsSafariSelector ?? false
    }

    static func makeDefault() async -> Bool {
        await set(to: Bundle.main.bundleURL)
    }

    static func restoreSafari() async -> Bool {
        guard let safari = NSWorkspace.shared
            .urlForApplication(withBundleIdentifier: "com.apple.Safari") else { return false }
        return await set(to: safari)
    }

    private static func set(to app: URL) async -> Bool {
        for scheme in ["http", "https"] {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: scheme) { error in
                    if let error {
                        // macOS prompts once and applies the choice to both schemes, so
                        // the second call routinely reports a failure that isn't one.
                        self.log.info("set default \(scheme): \(error.localizedDescription, privacy: .public)")
                    }
                    c.resume()
                }
            }
        }
        return current?.path == app.path
    }
}

private extension URL {
    var bundleIdentifierIsSafariSelector: Bool {
        Bundle(url: self)?.bundleIdentifier == Bundle.main.bundleIdentifier
    }
}
