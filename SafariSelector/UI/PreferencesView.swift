//
//  SafariSelector — open links in a chosen Safari window's active tab group.
//  Copyright (C) 2026 SafariSelector contributors
//
//  This program is free software: you can redistribute it and/or modify it under
//  the terms of the GNU General Public License as published by the Free Software
//  Foundation, either version 3 of the License, or (at your option) any later
//  version. See <https://www.gnu.org/licenses/>.
//

import SwiftUI

/// Settings: naming profiles, managing routing rules, and seeing what is connected.
///
/// Naming is manual by necessity. Safari gives the native handler a stable profile
/// UUID but never the profile's *name*, and a profile's name only surfaces in a
/// window title when that window happens to be showing loose tabs — which is not
/// something we can rely on. So the user names each profile once, and the UUID keeps
/// that name attached forever.
struct PreferencesView: View {
    @ObservedObject var config: Config
    @ObservedObject var store: TargetStore

    @State private var profiles: [String] = []
    @State private var revealingWindow = false
    @State private var revealError: String?

    var body: some View {
        TabView {
            generalTab.tabItem { Label("General", systemImage: "gearshape") }
            profilesTab.tabItem { Label("Profiles", systemImage: "person.2") }
            rulesTab.tabItem { Label("Rules", systemImage: "arrow.triangle.branch") }
        }
        .frame(minWidth: 640, idealWidth: 660, minHeight: 480, idealHeight: 720)
        .onReceive(store.$targets) { _ in
            // AppDelegate starts one scan whenever Settings opens, including when
            // reusing its window. Refresh profiles when that scan publishes results.
            profiles = store.knownProfiles.sorted()
        }
    }

    // MARK: - General

    @State private var defaultBrowser: String = ""

    private var generalTab: some View {
        ScrollView {
            generalContent.padding(14)
        }
    }

    private var generalContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox("Default web browser") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Current: \(defaultBrowser.isEmpty ? "—" : defaultBrowser)")
                        .font(.system(size: 15))
                    Text("System Settings will not list SafariSelector in its Default web browser menu — it filters out apps like this one even when they are correctly registered. Use these buttons instead.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Make SafariSelector the Default") {
                            Task { _ = await DefaultBrowser.makeDefault(); refreshDefault() }
                        }
                        Button("Restore Safari") {
                            Task { _ = await DefaultBrowser.restoreSafari(); refreshDefault() }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }
            GroupBox("Auto-select") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Choose a window automatically if I don't pick one", isOn: Binding(
                        get: { config.stored.autoSelectSeconds > 0 },
                        set: { config.stored.autoSelectSeconds = $0 ? 10 : 0 }
                    ))
                    HStack(spacing: 6) {
                        Text("After")
                        TextField("", value: Binding(
                            get: { config.stored.autoSelectSeconds },
                            set: { config.stored.autoSelectSeconds = max(0, $0) }
                        ), format: .number)
                            .frame(width: 46)
                            .disabled(config.stored.autoSelectSeconds == 0)
                        Text("seconds, open in the matching window")
                    }
                    if config.stored.legacyAutoSelectPattern != nil {
                        HStack {
                            Text("Existing pattern")
                            TextField("Work* — Tickets*", text: Binding(
                                get: { config.stored.legacyAutoSelectPattern ?? "" },
                                set: { config.stored.legacyAutoSelectPattern = $0 }
                            ))
                            .disabled(config.stored.autoSelectSeconds == 0)
                            Button("Use separate fields") {
                                config.stored.legacyAutoSelectPattern = nil
                            }
                        }
                        Text("Your existing pattern still matches the combined profile and tab-group name. Choose separate fields to replace it.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        HStack {
                            Text("Profile")
                            TextField("Work*", text: $config.stored.autoSelectProfilePattern)
                            Text("Tab group")
                            TextField("Tickets*", text: $config.stored.autoSelectGroupPattern)
                        }
                        .disabled(config.stored.autoSelectSeconds == 0)
                        Text("Each field matches its own name, case-insensitively. Leave either blank to match any. Use * and ? as wildcards; text without wildcards matches anywhere in the name.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(autoPreview)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(autoPreviewIsMatch ? .green : .orange)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }
            GroupBox("Safari extension") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Keep \u{201C}Allow Unsigned Extensions\u{201D} switched on",
                           isOn: Binding(
                            get: { config.stored.autoAllowUnsignedExtensions },
                            set: { on in
                                config.stored.autoAllowUnsignedExtensions = on
                                if on {
                                    UnsignedExtensionsGuard.requestAccessibilityPermission()
                                    UnsignedExtensionsGuard.ensureEnabled()
                                }
                                refreshGuard()
                            }))
                    Text("Safari resets this every time it launches, which silently disables the extension and sends links to the wrong window. Turning this on lets SafariSelector switch it back, which needs Accessibility permission. Not needed once the app is signed with a Developer ID and notarized, which requires paid Apple Developer Program membership.\n\nIf the extension stops after a reinstall, switching it off and on in Safari\u{2019}s Extensions settings restarts it.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Text(guardStatus).font(.system(size: 15, weight: .medium))
                        if !UnsignedExtensionsGuard.hasAccessibilityPermission {
                            Button("Grant Accessibility…") {
                                UnsignedExtensionsGuard.requestAccessibilityPermission()
                                refreshGuard()
                            }
                            .font(.system(size: 13))
                        }
                        Button("Check now") {
                            let outcome = UnsignedExtensionsGuard.ensureEnabled()
                            let time = Date().formatted(date: .omitted, time: .standard)
                            lastCheck = "Checked at \(time): \(outcome.message)"
                            refreshGuard()
                        }
                        .font(.system(size: 13))
                        Button("Open Safari Extension Settings…") { SafariExtension.showSettings() }
                            .font(.system(size: 13))
                    }
                    if !lastCheck.isEmpty {
                        Text(lastCheck)
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }
        }
        .onAppear { refreshDefault(); refreshGuard() }
    }

    @State private var guardStatus = ""
    @State private var lastCheck = ""

    private func refreshGuard() {
        guard UnsignedExtensionsGuard.hasAccessibilityPermission else {
            guardStatus = "Accessibility permission not granted."
            return
        }
        switch UnsignedExtensionsGuard.currentState() {
        case .on:          guardStatus = "Allow Unsigned Extensions: on"
        case .off:         guardStatus = "Allow Unsigned Extensions: OFF — the extension will not load"
        case .unavailable: guardStatus = "Can't read the Develop menu (is Safari running, with the Develop menu enabled?)"
        }
    }

    private var autoPreviewIsMatch: Bool {
        config.autoSelectTarget(from: store.targets) != nil
    }

    /// Shows what the pattern would pick right now, so a typo is obvious here rather
    /// than ten seconds into a link opening somewhere unexpected.
    private var autoPreview: String {
        guard config.stored.autoSelectSeconds > 0 else { return " " }
        guard config.stored.hasAutoSelectPattern else {
            return "No pattern set — the picker will stay open."
        }
        if let t = config.autoSelectTarget(from: store.targets) {
            return "Currently matches: \(t.matchHaystack)"
        }
        return "Matches nothing right now — the picker will stay open rather than guess."
    }

    private func refreshDefault() {
        defaultBrowser = DefaultBrowser.current?
            .deletingPathExtension().lastPathComponent ?? "unknown"
    }

    // MARK: - Profiles

    private var profilesTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Name each Safari profile. Use the tab group hints or Show Window to bring a profile's Safari window forward and recognize it.")
                    .font(.system(size: 16))
                Text("Saved profiles stay listed even when their windows are closed or their extension is asleep. Counts show open browsing windows, including previously identified profiles. To discover a missing profile, open one of its Safari windows and press Refresh. The link picker lists open windows, not every saved tab group.")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if profiles.isEmpty {
                ContentUnavailableView(
                    "No profiles discovered",
                    systemImage: "puzzlepiece.extension",
                    description: Text("Enable the SafariSelector extension in Safari Settings → Extensions, then click a window in each profile.")
                )
            } else {
                List(profiles, id: \.self) { uuid in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            TextField("Profile name", text: binding(for: uuid))
                                .textFieldStyle(.roundedBorder)
                            Text(uuid)
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundStyle(.secondary)
                            if (config.profileLabel(for: uuid) ?? "")
                                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                profileHints(uuid)
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 6) {
                            Text(windowSummary(uuid))
                                .font(.system(size: 16))
                                .foregroundStyle(.secondary)
                                .fixedSize()
                            revealControl(for: uuid)
                        }
                        .padding(.top, 3)
                    }
                    .padding(.vertical, 2)
                }
            }
            if let revealError {
                Text(revealError)
                    .font(.system(size: 13))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Refresh") {
                revealError = nil
                store.rebuild()
            }
        }
        .padding(14)
    }

    @ViewBuilder
    private func revealControl(for uuid: String) -> some View {
        let windows = store.windows(for: uuid).filter { $0.appleScriptWindowID != nil }
        if windows.count > 1 {
            Menu("Show Window") {
                ForEach(windows, id: \.rowKey) { window in
                    Button(revealLabel(window)) { reveal(window) }
                }
            }
            .fixedSize()
            .disabled(revealingWindow)
            .help("Choose an open Safari window in this profile to bring forward.")
        } else {
            Button("Show Window") {
                if let window = windows.first { reveal(window) }
            }
            .disabled(windows.isEmpty || revealingWindow)
            .help(windows.isEmpty
                  ? "This profile has no open window to show."
                  : "Bring this profile's Safari window forward without opening a tab.")
        }
    }

    private func revealLabel(_ window: SafariTarget) -> String {
        let title = window.activeTabTitle.isEmpty ? "Untitled tab" : window.activeTabTitle
        // The ID distinguishes windows even when both group and page titles match.
        return "\(window.displayLabel) — \(title) (window \(window.appleScriptWindowID ?? -1))"
    }

    private func reveal(_ window: SafariTarget) {
        guard let id = window.appleScriptWindowID, !revealingWindow else { return }
        revealingWindow = true
        revealError = nil
        AppleScriptProbe.queue.async {
            let succeeded = AppleScriptProbe.focus(windowID: id)
            DispatchQueue.main.async {
                if !succeeded {
                    revealError = "Couldn't show the Safari window. It may have closed, or Safari automation access may be unavailable. Refresh and try again."
                }
                store.rebuild { revealingWindow = false }
            }
        }
    }

    private func profileHints(_ uuid: String) -> some View {
        let hints = config.profileNamingHints(for: uuid, targets: store.targets)
        return VStack(alignment: .leading, spacing: 2) {
            Text("Tab group hints")
                .font(.system(size: 12, weight: .medium))
            if hints.isEmpty {
                Text("No hints yet. Show a tab group in this profile, then press Refresh.")
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(hints, id: \.self) { name in
                    Text("• \(name)")
                        .lineLimit(1)
                        .help(name)
                }
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
        .padding(.top, 4)
        .help("Up to four tab groups from open windows or previously seen in this profile. The focused window's group comes first when available. Safari window titles can also show the profile name.")
    }

    private func binding(for uuid: String) -> Binding<String> {
        Binding(
            get: { config.stored.profileAliases[uuid] ?? "" },
            set: { config.stored.profileAliases[uuid] = $0.isEmpty ? nil : $0 }
        )
    }

    private func windowSummary(_ uuid: String) -> String {
        let n = store.windowCount(for: uuid)
        return n == 1 ? "1 open window" : "\(n) open windows"
    }

    // MARK: - Rules

    private var rulesTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Links matching a rule skip the picker. Rules name a tab group rather than a window, so they survive windows being opened and closed.")
                .font(.system(size: 16))
            Text("Match a host (tickets.example.com), a wildcard (*.example.com), or paste a whole link to route that page and everything under it.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List {
                ForEach($config.stored.rules) { $rule in
                    HStack(spacing: 10) {
                        TextField("tickets.example.com", text: $rule.pattern)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 14))
                            .frame(minWidth: 240)
                        Text("→").foregroundStyle(.secondary)
                        Picker("", selection: Binding(
                            get: { rule.tabGroupLabel ?? "" },
                            set: { label in
                                rule.tabGroupLabel = label.isEmpty ? nil : label
                                // Keep the owning profile in step. A cold target has no
                                // profile of its own, so fall back to what the app
                                // learned about which profile owns that tab group.
                                if let owner = store.targets.first(where: { $0.tabGroupLabel == label })?.profileUUID
                                    ?? config.profileOwning(group: label) {
                                    rule.profileUUID = owner
                                }
                            }
                        )) {
                            ForEach(groupOptions(including: rule.tabGroupLabel), id: \.self) { label in
                                Text(label).tag(label)
                            }
                        }
                        .labelsHidden()
                        .font(.system(size: 14))
                        Button {
                            config.stored.rules.removeAll { $0.id == rule.id }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Remove this rule")
                    }
                    .padding(.vertical, 3)
                }
            }

            HStack {
                Button("Add Rule") {
                    let t = store.targets.first
                    config.stored.rules.append(.init(
                        pattern: "",
                        profileUUID: t?.profileUUID ?? "",
                        tabGroupLabel: t?.tabGroupLabel
                    ))
                }
                Spacer()
            }
        }
        .padding(14)
    }

    /// Tab groups to choose from. Always includes whatever the rule already points
    /// at, even if that window is closed or its profile is dormant — otherwise the
    /// menu shows blank and looks like the setting was lost.
    private func groupOptions(including current: String?) -> [String] {
        var labels = Set(store.targets.compactMap(\.tabGroupLabel))
        labels.formUnion(config.stored.groupToProfile.keys)
        if let current, !current.isEmpty { labels.insert(current) }
        return labels.sorted()
    }

}
