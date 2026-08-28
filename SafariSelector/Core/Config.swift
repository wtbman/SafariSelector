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
        /// Which target auto-select lands on, as a wildcard matched against
        /// "profile — tab group". Deliberately text rather than an id: window ids and
        /// even profile UUIDs change, but "Work*" keeps meaning what you meant.
        var autoSelectPattern: String = ""

        /// Re-enable Safari's "Allow Unsigned Extensions" when it resets. Off by
        /// default: it drives Safari's menus through Accessibility, which the user
        /// should opt into knowingly.
        var autoAllowUnsignedExtensions: Bool = false
    }

    /// Best target for the auto-select pattern, or nil if nothing matches.
    ///
    /// Matching is a case-insensitive glob over "profile — tab group", preferring the
    /// tightest match so "Open*" beats a looser candidate. Never guesses when the
    /// pattern matches nothing: silently opening somewhere arbitrary is worse than
    /// leaving the picker up.
    func autoSelectTarget(from targets: [SafariTarget]) -> SafariTarget? {
        let pattern = stored.autoSelectPattern.trimmingCharacters(in: .whitespaces)
        guard !pattern.isEmpty else { return nil }
        let matches = targets.filter { Config.glob(pattern, matches: $0.matchHaystack) }
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
