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

// Explicit entry point rather than @main on the delegate.
//
// NSApplicationMain installs the app delegate from the main storyboard, and this app
// is a background agent with no storyboard — so under @main the delegate is never
// set and applicationDidFinishLaunching never runs.
// Note: LSUIElement is deliberately NOT set in Info.plist. macOS filters agent
// apps out of the Default web browser list, so the app must register as a regular
// app and drop its Dock presence at runtime instead.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
