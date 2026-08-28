import SwiftUI
import Combine
import AppKit

/// The picker. Keyboard-first: type to filter, arrows to move, digits to jump,
/// Return to open, Escape to cancel.
struct SelectorView: View {
    let url: URL
    let targets: [SafariTarget]
    /// Which app the link came from, when it could be determined.
    let source: LinkSource.Info?
    /// Seconds before auto-selecting `autoTarget`; zero disables the countdown.
    let autoSelectSeconds: Int
    let autoTarget: SafariTarget?
    let onChoose: (SafariTarget) -> Void
    let onNewWindow: (SafariTarget) -> Void
    let onFallback: () -> Void
    let onCancel: () -> Void
    /// Called when the countdown is cancelled by the user touching anything, so the
    /// panel can stop treating this as an unattended pick.
    let onInteraction: () -> Void

    @State private var filter = ""
    @State private var selection = 0
    @State private var remaining = 0
    @State private var countdownCancelled = false
    /// Command-A selects the whole filter, so the next keystroke replaces it and
    /// backspace clears it — the text-field behaviour people expect, without a
    /// text field (which would swallow the number keys).
    @State private var filterSelected = false
    @State private var monitor: Any?
    /// The view must be focusable *and* focused for onKeyPress to fire at all;
    /// without it every keystroke goes unhandled and macOS beeps.
    @FocusState private var isFocused: Bool

    // Type scale, sized for a 4K display where the defaults are unreadably small.
    private let urlSize: CGFloat = 18      // +15%
    private let sourceIconSize: CGFloat = 31   // -15%
    private let sourceTextSize: CGFloat = 22   // -15%
    private let titleSize: CGFloat = 17.5
    private let subtitleSize: CGFloat = 15
    private let digitSize: CGFloat = 25

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    // Layout metrics. The list is sized from the *unfiltered* target count so the
    // panel's height never changes while typing: the window is sized once when it
    // opens, and a list that shrank while filtering would not grow back.
    //
    // Rows and headers are pinned to these heights rather than measured, so the
    // arithmetic below is exact by construction. Estimating them was off by ~8pt a
    // row, which quietly clipped the last window off the bottom of a short list.
    private let rowHeight: CGFloat = 60
    private let groupHeaderHeight: CGFloat = 30
    private let maxListHeight: CGFloat = 792

    private var listHeight: CGFloat {
        let groups = Set(targets.map(\.profileLabel)).count
        let natural = CGFloat(targets.count) * rowHeight
            + CGFloat(groups) * groupHeaderHeight
            + 8   // breathing room at the bottom of the list
        return min(max(natural, rowHeight), maxListHeight)
    }

    private var filtered: [SafariTarget] {
        guard !filter.isEmpty else { return targets }
        let needle = filter.lowercased()
        return targets.filter { $0.searchHaystack.contains(needle) }
    }

    private var grouped: [(profile: String, items: [SafariTarget])] {
        Dictionary(grouping: filtered, by: \.profileLabel)
            .map { (profile: $0.key, items: $0.value) }
            .sorted { $0.profile < $1.profile }
    }

    /// Flattened in the same order the grouped list renders, so index-based
    /// selection and the visible order never disagree.
    private var flat: [SafariTarget] { grouped.flatMap(\.items) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            Group {
                if filtered.isEmpty { empty } else { list }
            }
            .frame(height: listHeight, alignment: .top)
            Divider()
            footer
        }
        .frame(width: 867)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(phases: .down) { press in handle(press) }
        .onAppear {
            // Focus has to be claimed after the panel has actually become key.
            DispatchQueue.main.async { isFocused = true }
            remaining = autoTarget == nil ? 0 : autoSelectSeconds
            // Scrolling and clicking are interaction too, and neither reaches
            // onKeyPress. A local monitor is the only thing that sees all of them.
            monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.scrollWheel, .leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { event in
                cancelCountdown()
                return event
            }
        }
        .onDisappear {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
        .onReceive(tick) { _ in
            guard !countdownCancelled, remaining > 0, let autoTarget else { return }
            remaining -= 1
            if remaining == 0 { onChoose(autoTarget) }
        }
    }

    private func cancelCountdown() {
        guard !countdownCancelled else { return }
        countdownCancelled = true
        onInteraction()
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let source {
                HStack(spacing: 10) {
                    if let icon = source.icon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: sourceIconSize, height: sourceIconSize)
                    }
                    Text("from \(source.name)")
                        .font(.system(size: sourceTextSize, weight: .semibold))
                }
            }
            Text(url.absoluteString)
                .font(.system(size: urlSize, design: .monospaced))
                .lineLimit(2)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
            Text(filter.isEmpty ? "Type to filter windows…" : filter)
                .font(.system(size: 18))
                .foregroundStyle(filter.isEmpty
                                 ? AnyShapeStyle(.tertiary)
                                 : AnyShapeStyle(filterSelected ? Color.white : Color.primary))
                .padding(.horizontal, filterSelected ? 4 : 0)
                .background(filterSelected ? Color.accentColor : .clear)
        }
        .padding(14)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(targets.isEmpty ? "No Safari windows connected" : "No matches")
                .font(.system(size: titleSize, weight: .medium))
            if targets.isEmpty {
                Text("Enable the SafariSelector extension in Safari Settings → Extensions.")
                    .font(.system(size: subtitleSize))
                    .foregroundStyle(.secondary)
            }
            Button("Open in Safari normally", action: onFallback)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(grouped, id: \.profile) { group in
                        Text(group.profile.uppercased())
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 14)
                            .frame(height: groupHeaderHeight, alignment: .bottomLeading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        ForEach(group.items, id: \.rowKey) { target in
                            row(target).id(target.rowKey)
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)
            .onChange(of: selection) {
                // Never scroll for the first row: doing so lifts its group header out
                // of the viewport, which reads as the profile name having vanished.
                guard selection > 0, flat.indices.contains(selection) else { return }
                proxy.scrollTo(flat[selection].rowKey)
            }
        }
    }

    private func row(_ target: SafariTarget) -> some View {
        let index = flat.firstIndex(of: target) ?? 0
        let isSelected = index == selection
        return HStack(spacing: 10) {
            Image(systemName: target.tabGroupLabel == nil ? "square.on.square.dashed" : "square.stack")
                .foregroundStyle(isSelected ? AnyShapeStyle(Color.white) : AnyShapeStyle(.secondary))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(target.displayLabel)
                    .font(.system(size: titleSize, weight: .medium))
                Text(target.activeTabTitle.isEmpty ? target.activeTabURL : target.activeTabTitle)
                    .font(.system(size: subtitleSize))
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
            Spacer()
            Text("\(target.tabCount)")
                .font(.system(size: subtitleSize - 3, design: .monospaced))
                .foregroundStyle(isSelected ? AnyShapeStyle(Color.white.opacity(0.7)) : AnyShapeStyle(.tertiary))
            if index < 9 {
                Text("\(index + 1)")
                    .font(.system(size: digitSize, weight: .semibold, design: .rounded))
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color.white) : AnyShapeStyle(.secondary))
                    .frame(minWidth: digitSize + 6, alignment: .trailing)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: rowHeight)
        .background(isSelected ? Color.accentColor : .clear)
        .foregroundStyle(isSelected ? Color.white : .primary)
        .contentShape(Rectangle())
        .onTapGesture {
            cancelCountdown()
            selection = index
            choose()
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            if let autoTarget, remaining > 0, !countdownCancelled {
                HStack(spacing: 5) {
                    Image(systemName: "timer")
                    Text("\(autoTarget.displayLabel) in \(remaining)s")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(.orange)
                Divider().frame(height: 14)
            }
            hint("↑↓", "move")
            hint("1–9", "jump")
            hint("⏎", "open")
            hint("⌘⏎", "new window")
            hint("⌫", "delete")
            hint("esc", "clear / cancel")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 3) {
            Text(key).font(.system(size: 12, weight: .semibold, design: .monospaced))
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    // MARK: - Key handling

    /// One handler for every key.
    ///
    /// The filter is driven from here rather than by a focused `TextField`, because a
    /// focused text field swallows digits — so pressing "3" typed a 3 instead of
    /// jumping to the third window, which is the whole point of numbering the rows.
    private func handle(_ press: KeyPress) -> KeyPress.Result {
        cancelCountdown()

        if press.modifiers.contains(.command) {
            if press.key == .return {
                if flat.indices.contains(selection) { onNewWindow(flat[selection]) }
                return .handled
            }
            if press.characters.lowercased() == "a" {
                filterSelected = !filter.isEmpty
                return .handled
            }
            return .ignored
        }

        // Backspace does not reliably arrive as KeyEquivalent.delete, so match the
        // control characters too rather than trusting one representation.
        let isDelete = press.key == .delete || press.key == .deleteForward
            || press.characters == "\u{7F}" || press.characters == "\u{8}"
        if isDelete {
            if filterSelected || press.modifiers.contains(.command) {
                filter = ""
            } else if press.modifiers.contains(.option) {
                // Delete the last word.
                var parts = filter.split(separator: " ", omittingEmptySubsequences: false)
                if !parts.isEmpty { parts.removeLast() }
                filter = parts.joined(separator: " ")
            } else if !filter.isEmpty {
                filter.removeLast()
            }
            filterSelected = false
            selection = 0
            return .handled   // always handled, so an empty filter does not beep
        }

        switch press.key {
        case .downArrow:
            selection = min(selection + 1, max(flat.count - 1, 0)); return .handled
        case .upArrow:
            selection = max(selection - 1, 0); return .handled
        case .escape:
            if !filter.isEmpty {
                filter = ""; filterSelected = false; selection = 0
                return .handled
            }
            onCancel(); return .handled
        case .return:
            choose(); return .handled
        case .delete:
            if !filter.isEmpty { filter.removeLast(); selection = 0 }
            return .handled
        default:
            break
        }

        guard let ch = press.characters.first else { return .ignored }

        // Digits jump. Filtering by a bare number is the rarer need by far.
        if let n = ch.wholeNumberValue, (1...9).contains(n), press.characters.count == 1,
           !filterSelected {
            guard flat.indices.contains(n - 1) else { return .handled }
            selection = n - 1
            choose()
            return .handled
        }

        if ch.isLetter || ch.isNumber || ch.isPunctuation || ch.isSymbol || ch == " " {
            if filterSelected { filter = ""; filterSelected = false }
            filter.append(press.characters)
            selection = 0
            return .handled
        }
        return .ignored
    }

    private func choose() {
        guard flat.indices.contains(selection) else { return }
        onChoose(flat[selection])
    }
}
