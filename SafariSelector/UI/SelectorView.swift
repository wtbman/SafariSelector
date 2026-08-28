import SwiftUI
import Combine

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

    @State private var filter = ""
    @State private var selection = 0
    @State private var remaining: Int = 0
    @State private var countdownCancelled = false
    @FocusState private var focused: Bool

    // Type scale. Sized for a 4K display, where the defaults are unreadably small.
    private let urlSize: CGFloat = 22       // 200% of the original 11
    private let titleSize: CGFloat = 17.5   // 135% of the original 13
    private let subtitleSize: CGFloat = 15  // 135% of the original 11
    private let digitSize: CGFloat = 25     // 250% of the original 10

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if filtered.isEmpty { empty } else { list }
            Divider()
            footer
        }
        .frame(width: 680)
        .background(.regularMaterial)
        .onKeyPress(action: onKey)
        .onAppear {
            focused = true
            remaining = autoTarget == nil ? 0 : autoSelectSeconds
        }
        .onReceive(tick) { _ in
            guard !countdownCancelled, remaining > 0, let autoTarget else { return }
            remaining -= 1
            if remaining == 0 { onChoose(autoTarget) }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let source {
                HStack(spacing: 6) {
                    if let icon = source.icon {
                        Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                    }
                    Text("from \(source.name)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            Text(url.absoluteString)
                .font(.system(size: urlSize, design: .monospaced))
                .lineLimit(2)
                .truncationMode(.middle)
                .foregroundStyle(.primary)
            TextField("Filter windows…", text: $filter)
                .textFieldStyle(.plain)
                .font(.system(size: 18))
                .focused($focused)
                .onChange(of: filter) { selection = 0; countdownCancelled = true }
                .onSubmit { choose() }
        }
        .padding(12)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(targets.isEmpty ? "No Safari windows connected" : "No matches")
                .font(.system(size: 13, weight: .medium))
            if targets.isEmpty {
                Text("Enable the SafariSelector extension in Safari Settings → Extensions.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Button("Open in Safari normally", action: onFallback)
                .font(.system(size: 11))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
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
                            .padding(.top, 8)
                            .padding(.bottom, 2)
                        ForEach(group.items) { target in
                            row(target)
                                .id(target.id)
                        }
                    }
                }
            }
            .frame(maxHeight: 440)
            .onChange(of: selection) {
                if let t = flat.indices.contains(selection) ? flat[selection] : nil {
                    proxy.scrollTo(t.id)
                }
            }
        }
    }

    /// Flattened in the same order the grouped list renders, so index-based
    /// selection and the visible order never disagree.
    private var flat: [SafariTarget] { grouped.flatMap(\.items) }

    private func row(_ target: SafariTarget) -> some View {
        let index = flat.firstIndex(of: target) ?? 0
        let isSelected = index == selection
        return HStack(spacing: 8) {
            Image(systemName: target.tabGroupLabel == nil ? "square.on.square.dashed" : "square.stack")
                .foregroundStyle(isSelected ? Color.white : .secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(target.displayLabel)
                    .font(.system(size: titleSize, weight: .medium))
                Text(target.activeTabTitle.isEmpty ? target.activeTabURL : target.activeTabTitle)
                    .font(.system(size: subtitleSize))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.8) : .secondary)
                    .lineLimit(1)
            }
            Spacer()
            if index < 9 {
                Text("\(index + 1)")
                    .font(.system(size: digitSize, weight: .semibold, design: .rounded))
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color.white) : AnyShapeStyle(.secondary))
                    .frame(minWidth: digitSize)
            }
            Text("\(target.tabCount)")
                .font(.system(size: subtitleSize - 3, design: .monospaced))
                .foregroundStyle(isSelected ? AnyShapeStyle(Color.white.opacity(0.7)) : AnyShapeStyle(.tertiary))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(isSelected ? Color.accentColor : .clear)
        .foregroundStyle(isSelected ? Color.white : .primary)
        .contentShape(Rectangle())
        .onTapGesture { countdownCancelled = true; selection = index; choose() }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            if let autoTarget, remaining > 0, !countdownCancelled {
                HStack(spacing: 5) {
                    Image(systemName: "timer")
                    Text("\(autoTarget.displayLabel) in \(remaining)s")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(.orange)
                Divider().frame(height: 12)
            }
            hint("↑↓", "move")
            hint("⌘1–9", "jump")
            hint("⏎", "open")
            hint("⌘⏎", "new window")
            hint("esc", "cancel")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 3) {
            Text(key).font(.system(size: 12, weight: .semibold, design: .monospaced))
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    // MARK: - Key handling

    /// One handler for everything. Arrow keys and Escape never reach the text field
    /// as text, and jumps are bound to Command-digit so plain digits stay typable
    /// into the filter.
    private func onKey(_ press: KeyPress) -> KeyPress.Result {
        // Any deliberate keystroke means the user is choosing; stop the clock.
        countdownCancelled = true
        if press.modifiers.contains(.command) {
            if press.key == .return {
                if flat.indices.contains(selection) { onNewWindow(flat[selection]) }
                return .handled
            }
            if let n = Int(press.characters), (1...9).contains(n) {
                guard flat.indices.contains(n - 1) else { return .handled }
                selection = n - 1
                choose()
                return .handled
            }
            return .ignored
        }
        switch press.key {
        case .downArrow:
            selection = min(selection + 1, max(flat.count - 1, 0)); return .handled
        case .upArrow:
            selection = max(selection - 1, 0); return .handled
        case .escape:
            onCancel(); return .handled
        case .return:
            choose(); return .handled
        default:
            return .ignored
        }
    }

    private func choose() {
        guard flat.indices.contains(selection) else { return }
        onChoose(flat[selection])
    }
}
