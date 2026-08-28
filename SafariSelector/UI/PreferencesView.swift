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
            profilesTab.tabItem { Label("Profiles", systemImage: "person.2") }
            rulesTab.tabItem { Label("Rules", systemImage: "arrow.triangle.branch") }
        }
        .frame(width: 560, height: 380)
        .onAppear { profiles = knownProfiles().sorted() }
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
