import AppKit
import SwiftUI

/// Floating panel that hosts the picker.
///
/// A borderless `NSPanel` that can still become key — the picker is keyboard-first,
/// so it must accept typing, which a `.nonactivatingPanel` would not.
final class SelectorPanel: NSPanel {

    /// Called when the panel loses key status — the user clicked away.
    private var onDismiss: (() -> Void)?

    init<Content: View>(content: Content, onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 400),
            // Borderless: a titled panel reserves a title bar strip even when it is
            // transparent, which showed as a band of empty space above the content.
            // canBecomeKey is overridden below so the picker still receives typing.
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isMovableByWindowBackground = true
        isOpaque = false
        hasShadow = true
        backgroundColor = .clear
        level = .floating
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let hosting = NSHostingView(rootView: content)
        // Let the hosting view drive the window's size, so the panel tracks its
        // content instead of being frozen at whatever it measured on the first pass.
        hosting.sizingOptions = [.standardBounds]
        contentView = hosting
        setContentSize(hosting.fittingSize)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Places the panel on whichever screen the pointer is on, slightly above centre.
    func showCentredOnPointerScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            let size = self.frame.size
            setFrameOrigin(NSPoint(
                x: frame.midX - size.width / 2,
                y: frame.midY - size.height / 2 + frame.height * 0.1
            ))
        }
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        makeFirstResponder(contentView)
    }

    override func resignKey() {
        super.resignKey()
        onDismiss?()
    }

    func dismiss() {
        onDismiss = nil
        orderOut(nil)
    }
}
