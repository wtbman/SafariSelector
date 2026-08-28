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
    let knownProfiles: () -> [String]

    @State private var profiles: [String] = []

    var body: some View {
        TabView {
            generalTab.tabItem { Label("General", systemImage: "gearshape") }
            profilesTab.tabItem { Label("Profiles", systemImage: "person.2") }
            rulesTab.tabItem { Label("Rules", systemImage: "arrow.triangle.branch") }
        }
        .frame(width: 560, height: 380)
        .onAppear { profiles = knownProfiles().sorted() }
    }

    // MARK: - General

    @State private var defaultBrowser: String = ""

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox("Default web browser") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Current: \(defaultBrowser.isEmpty ? "—" : defaultBrowser)")
                        .font(.system(size: 12))
                    Text("System Settings will not list SafariSelector in its Default web browser menu — it filters out apps like this one even when they are correctly registered. Use these buttons instead.")
                        .font(.system(size: 11))
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
                        Text("seconds, open in")
                        TextField("Work*", text: $config.stored.autoSelectPattern)
                            .frame(width: 190)
                            .disabled(config.stored.autoSelectSeconds == 0)
                    }
                    Text("Matched against \u{201C}profile — tab group\u{201D}, case-insensitively. Use * and ? as wildcards; text with no wildcard matches anywhere in the name. Deliberately text rather than a fixed window, so it keeps working as windows come and go.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(autoPreview)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(autoPreviewIsMatch ? .green : .orange)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }
            Spacer()
        }
        .padding(14)
        .onAppear { refreshDefault() }
    }

    private var autoPreviewIsMatch: Bool {
        config.autoSelectTarget(from: store.targets) != nil
    }

    /// Shows what the pattern would pick right now, so a typo is obvious here rather
    /// than ten seconds into a link opening somewhere unexpected.
    private var autoPreview: String {
        guard config.stored.autoSelectSeconds > 0 else { return " " }
        guard !config.stored.autoSelectPattern.trimmingCharacters(in: .whitespaces).isEmpty else {
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
            Text("Name each Safari profile. Safari identifies profiles only by UUID, so these names are yours to set.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            if profiles.isEmpty {
                ContentUnavailableView(
                    "No profiles connected",
                    systemImage: "puzzlepiece.extension",
                    description: Text("Enable the SafariSelector extension in Safari Settings → Extensions, then click a window in each profile.")
                )
            } else {
                List(profiles, id: \.self) { uuid in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            TextField("Profile name", text: binding(for: uuid))
                                .textFieldStyle(.roundedBorder)
                            Text(uuid)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(windowSummary(uuid))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
            Button("Refresh") { profiles = knownProfiles().sorted(); store.rebuild() }
        }
        .padding(14)
    }

    private func binding(for uuid: String) -> Binding<String> {
        Binding(
            get: { config.stored.profileAliases[uuid] ?? "" },
            set: { config.stored.profileAliases[uuid] = $0.isEmpty ? nil : $0 }
        )
    }

    private func windowSummary(_ uuid: String) -> String {
        let n = store.targets.filter { $0.profileUUID == uuid }.count
        return n == 1 ? "1 window" : "\(n) windows"
    }

    // MARK: - Rules

    private var rulesTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Links matching a rule skip the picker. Rules name a tab group rather than a window, so they survive windows being opened and closed.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            List {
                ForEach($config.stored.rules) { $rule in
                    HStack(spacing: 8) {
                        TextField("*.example.com", text: $rule.pattern)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 190)
                        Text("→").foregroundStyle(.secondary)
                        Picker("", selection: Binding(
                            get: { "\(rule.profileUUID)|\(rule.tabGroupLabel ?? "")" },
                            set: { combined in
                                let parts = combined.split(separator: "|", maxSplits: 1,
                                                           omittingEmptySubsequences: false)
                                rule.profileUUID = String(parts.first ?? "")
                                let group = parts.count > 1 ? String(parts[1]) : ""
                                rule.tabGroupLabel = group.isEmpty ? nil : group
                            }
                        )) {
                            ForEach(store.targets) { t in
                                Text("\(t.profileLabel) — \(t.displayLabel)")
                                    .tag("\(t.profileUUID ?? "")|\(t.tabGroupLabel ?? "")")
                            }
                        }
                        .labelsHidden()
                    }
                }
                .onDelete { config.stored.rules.remove(atOffsets: $0) }
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
                Text("Select a rule and press Delete to remove it.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
    }
}
