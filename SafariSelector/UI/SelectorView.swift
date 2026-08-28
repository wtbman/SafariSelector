import SwiftUI

/// The picker. Keyboard-first: type to filter, arrows to move, digits to jump,
/// Return to open, Escape to cancel.
struct SelectorView: View {
    let url: URL
    let targets: [SafariTarget]
    let onChoose: (SafariTarget) -> Void
    let onNewWindow: (SafariTarget) -> Void
    let onFallback: () -> Void
    let onCancel: () -> Void

    @State private var filter = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

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
        .frame(width: 520)
        .background(.regularMaterial)
        .onKeyPress(action: onKey)
        .onAppear { focused = true }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(url.absoluteString)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
            TextField("Filter windows…", text: $filter)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($focused)
                .onChange(of: filter) { selection = 0 }
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
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.top, 8)
                            .padding(.bottom, 2)
                        ForEach(group.items) { target in
                            row(target)
                                .id(target.id)
                        }
                    }
                }
            }
            .frame(maxHeight: 340)
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
                    .font(.system(size: 13, weight: .medium))
                Text(target.activeTabTitle.isEmpty ? target.activeTabURL : target.activeTabTitle)
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.8) : .secondary)
                    .lineLimit(1)
            }
            Spacer()
            if index < 9 {
                Text("\(index + 1)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color.white.opacity(0.7)) : AnyShapeStyle(.tertiary))
            }
            Text("\(target.tabCount)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(isSelected ? AnyShapeStyle(Color.white.opacity(0.7)) : AnyShapeStyle(.tertiary))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor : .clear)
        .foregroundStyle(isSelected ? Color.white : .primary)
        .contentShape(Rectangle())
        .onTapGesture { selection = index; choose() }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            hint("↑↓", "move")
            hint("⌘1–9", "jump")
            hint("⏎", "open")
            hint("⌘⏎", "new window")
            hint("esc", "cancel")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 3) {
            Text(key).font(.system(size: 10, weight: .semibold, design: .monospaced))
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    // MARK: - Key handling

    /// One handler for everything. Arrow keys and Escape never reach the text field
    /// as text, and jumps are bound to Command-digit so plain digits stay typable
    /// into the filter.
    private func onKey(_ press: KeyPress) -> KeyPress.Result {
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
