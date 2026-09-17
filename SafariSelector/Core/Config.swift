//
//  SafariSelector — open links in a chosen Safari window's active tab group.
//  Copyright (C) 2026 SafariSelector contributors
//
//  This program is free software: you can redistribute it and/or modify it under
//  the terms of the GNU General Public License as published by the Free Software
//  Foundation, either version 3 of the License, or (at your option) any later
//  version. See <https://www.gnu.org/licenses/>.
//

import Foundation
import Combine

/// Persisted settings: profile aliases, routing rules, and last-choice memory.
final class Config: ObservableObject {

    struct Rule: Codable, Identifiable, Hashable {
        var id = UUID()
        /// What to match. A bare host (`tickets.example.com`), a host glob
        /// (`*.example.com`), or a whole URL pasted straight in — people
        /// naturally paste the link they want routed, and rejecting that silently
        /// is worse than accepting it.
        var pattern: String
        var profileUUID: String
        /// Resolved to a live window at open time, so the rule survives window churn.
        var tabGroupLabel: String?

        func matches(_ url: URL) -> Bool {
            let raw = pattern.trimmingCharacters(in: .whitespaces).lowercased()
            guard !raw.isEmpty else { return false }

            // Strip a scheme if one was pasted in.
            var p = raw
            for scheme in ["https://", "http://"] where p.hasPrefix(scheme) {
                p = String(p.dropFirst(scheme.count))
            }
            guard let host = url.host?.lowercased() else { return false }

            // A pattern with a path is matched against host+path, so a pasted URL
            // routes that page (and anything beneath it) rather than never matching.
            if p.contains("/") {
                let subject = host + url.path.lowercased()
                let prefix = p.hasSuffix("/") ? String(p.dropLast()) : p
                return subject == prefix
                    || subject.hasPrefix(prefix + "/")
                    || Config.glob(p, matches: subject)
            }

            if p.hasPrefix("*.") {
                let suffix = String(p.dropFirst(2))
                return host == suffix || host.hasSuffix("." + suffix)
            }
            if p.contains("*") || p.contains("?") {
                return Config.glob(p, matches: host)
            }
            return host == p || host.hasSuffix("." + p)
        }
    }

    struct Stored: Codable {
        var profileAliases: [String: String] = [:]
        var rules: [Rule] = []
        /// Tab group name -> the profile that owns it. A tab group belongs to exactly
        /// one profile and does not move, so once seen this stays true — and it lets a
        /// dormant profile's windows still be labelled correctly in the picker.
        var groupToProfile: [String: String] = [:]
        /// host -> target id, so a repeat visit pre-selects where it went last time.
        var lastChoiceByHost: [String: String] = [:]
        var lastChoice: String?

        /// Auto-select a target if the picker sits untouched this long. Zero is off.
        var autoSelectSeconds: Int = 0
        /// Which target auto-select lands on: two separate wildcards, matched against
        /// the profile name and the tab group name independently. Deliberately text
        /// rather than an id: window ids and even profile UUIDs change, but "Work*"
        /// keeps meaning what you meant. Separate fields (rather than one pattern
        /// glued together with a separator) so "Personal" the profile and "Personal"
        /// the tab group can't be confused for one another, and so nothing needs an
        /// em dash typed into a text field.
        var autoSelectProfilePattern: String = ""
        var autoSelectGroupPattern: String = ""
        /// Older patterns can match either half or span the separator. Retain their
        /// exact semantics until the user chooses to replace them with separate fields.
        var legacyAutoSelectPattern: String?

        var hasAutoSelectPattern: Bool {
            [legacyAutoSelectPattern ?? "", autoSelectProfilePattern, autoSelectGroupPattern]
                .contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        }

        /// Re-enable Safari's "Allow Unsigned Extensions" when it resets. Off by
        /// default: it drives Safari's menus through Accessibility, which the user
        /// should opt into knowingly.
        var autoAllowUnsignedExtensions: Bool = false

        init() {}

        /// Missing fields in older settings must use defaults instead of rejecting
        /// the entire file and losing aliases, routing rules, and choice history.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            profileAliases = try c.decodeIfPresent([String: String].self, forKey: .profileAliases) ?? [:]
            rules = try c.decodeIfPresent([Rule].self, forKey: .rules) ?? []
            groupToProfile = try c.decodeIfPresent([String: String].self, forKey: .groupToProfile) ?? [:]
            lastChoiceByHost = try c.decodeIfPresent([String: String].self, forKey: .lastChoiceByHost) ?? [:]
            lastChoice = try c.decodeIfPresent(String.self, forKey: .lastChoice)
            autoSelectSeconds = try c.decodeIfPresent(Int.self, forKey: .autoSelectSeconds) ?? 0
            autoSelectProfilePattern = try c.decodeIfPresent(String.self, forKey: .autoSelectProfilePattern) ?? ""
            autoSelectGroupPattern = try c.decodeIfPresent(String.self, forKey: .autoSelectGroupPattern) ?? ""
            autoAllowUnsignedExtensions = try c.decodeIfPresent(Bool.self, forKey: .autoAllowUnsignedExtensions) ?? false
            if autoSelectProfilePattern.trimmingCharacters(in: .whitespaces).isEmpty,
               autoSelectGroupPattern.trimmingCharacters(in: .whitespaces).isEmpty,
               let legacy = try c.decodeIfPresent(String.self, forKey: .legacyAutoSelectPattern),
               !legacy.trimmingCharacters(in: .whitespaces).isEmpty {
                legacyAutoSelectPattern = legacy
            }
        }

        private enum CodingKeys: String, CodingKey {
            case profileAliases, rules, groupToProfile, lastChoiceByHost, lastChoice,
                 autoSelectSeconds, autoSelectProfilePattern, autoSelectGroupPattern,
                 autoAllowUnsignedExtensions
            case legacyAutoSelectPattern = "autoSelectPattern"
        }
    }

    /// Best target for the auto-select patterns, or nil if nothing matches.
    ///
    /// The profile and tab-group patterns are matched independently, case-
    /// insensitively; an empty pattern matches anything for that half. Among
    /// matches, prefers the tightest so "Open*" beats a looser candidate. Never
    /// guesses when nothing matches: silently opening somewhere arbitrary is worse
    /// than leaving the picker up.
    func autoSelectTarget(from targets: [SafariTarget]) -> SafariTarget? {
        if let legacy = stored.legacyAutoSelectPattern {
            let pattern = legacy.trimmingCharacters(in: .whitespaces)
            guard !pattern.isEmpty else { return nil }
            return targets.filter { Config.glob(pattern, matches: $0.matchHaystack) }
                .min { $0.matchHaystack.count < $1.matchHaystack.count }
        }
        let profilePattern = stored.autoSelectProfilePattern.trimmingCharacters(in: .whitespaces)
        let groupPattern = stored.autoSelectGroupPattern.trimmingCharacters(in: .whitespaces)
        guard !profilePattern.isEmpty || !groupPattern.isEmpty else { return nil }
        let matches = targets.filter {
            (profilePattern.isEmpty || Config.glob(profilePattern, matches: $0.profileLabel))
            && (groupPattern.isEmpty || Config.glob(groupPattern, matches: $0.tabGroupLabel ?? "loose tabs"))
        }
        return matches.min { $0.matchHaystack.count < $1.matchHaystack.count }
    }

    /// Shell-style glob: `*` matches any run of characters, `?` a single one.
    /// A pattern with no wildcards is treated as a substring search, which is what
    /// people expect when they type "Tickets".
    static func glob(_ pattern: String, matches subject: String) -> Bool {
        let p = pattern.lowercased(), s = subject.lowercased()
        guard p.contains("*") || p.contains("?") else { return s.contains(p) }
        var regex = "^"
        for ch in p {
            switch ch {
            case "*": regex += ".*"
            case "?": regex += "."
            default: regex += NSRegularExpression.escapedPattern(for: String(ch))
            }
        }
        regex += "$"
        return s.range(of: regex, options: [.regularExpression]) != nil
    }

    @Published var stored: Stored {
        didSet { save() }
    }

    private var file: URL {
        BridgeServer.supportDirectory.appendingPathComponent("config.json")
    }

    init() {
        let url = BridgeServer.supportDirectory.appendingPathComponent("config.json")
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(Stored.self, from: data) {
            stored = decoded
        } else {
            stored = Stored()
        }
    }

    func profileLabel(for uuid: String) -> String? {
        stored.profileAliases[uuid]
    }

    /// Naming clues only: window-title prefixes can also describe loose tabs, and
    /// remembered groups may no longer be open. Never infer a profile name from them.
    func profileNamingHints(for uuid: String, targets: [SafariTarget]) -> [String] {
        let live = targets.filter { target in
            if let owner = target.profileUUID { return owner == uuid }
            return target.tabGroupLabel.flatMap { stored.groupToProfile[$0] } == uuid
        }.sorted {
            if $0.isFocused != $1.isFocused { return $0.isFocused }
            // Confirmed open windows precede inferred ownership for dormant ones.
            if $0.isWarm != $1.isWarm { return $0.isWarm }
            return ($0.tabGroupLabel ?? "") < ($1.tabGroupLabel ?? "")
        }
        let remembered = stored.groupToProfile
            .filter { $0.value == uuid }
            .map(\.key)
            .sorted()

        var seen = Set<String>()
        var hints: [String] = []
        for label in live.compactMap(\.tabGroupLabel) + remembered {
            let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, seen.insert(name).inserted else { continue }
            hints.append(name)
            if hints.count == 4 { break }
        }
        return hints
    }

    func learn(group: String, belongsTo profileUUID: String) {
        guard stored.groupToProfile[group] != profileUUID else { return }
        stored.groupToProfile[group] = profileUUID
    }

    func profileOwning(group: String) -> String? {
        stored.groupToProfile[group]
    }

    func rule(for url: URL) -> Rule? {
        stored.rules.first { $0.matches(url) }
    }

    func rememberChoice(_ target: SafariTarget, for url: URL) {
        if let host = url.host { stored.lastChoiceByHost[host] = target.id }
        stored.lastChoice = target.id
    }

    func preferredTargetID(for url: URL) -> String? {
        if let host = url.host, let id = stored.lastChoiceByHost[host] { return id }
        return stored.lastChoice
    }

    private func save() {
        try? FileManager.default.createDirectory(at: BridgeServer.supportDirectory,
                                                 withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? data.write(to: file, options: .atomic)
    }
}
