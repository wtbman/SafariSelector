import AppKit

// Explicit entry point rather than @main on the delegate.
//
// NSApplicationMain installs the app delegate from the main storyboard, and this app
// is a background agent with no storyboard — so under @main the delegate is never
// set and applicationDidFinishLaunching never runs.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
