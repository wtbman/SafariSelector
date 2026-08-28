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
