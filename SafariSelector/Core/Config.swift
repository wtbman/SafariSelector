import Foundation
import Combine

/// Persisted settings: profile aliases, routing rules, and last-choice memory.
final class Config: ObservableObject {

    struct Rule: Codable, Identifiable, Hashable {
        var id = UUID()
        /// Host glob, e.g. "*.example.com".
        var pattern: String
        var profileUUID: String
        /// Resolved to a live window at open time, so the rule survives window churn.
        var tabGroupLabel: String?

        func matches(host: String) -> Bool {
            let p = pattern.lowercased(), h = host.lowercased()
            if p.hasPrefix("*.") {
                let suffix = String(p.dropFirst(2))
                return h == suffix || h.hasSuffix("." + suffix)
            }
            return h == p
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
        guard let host = url.host else { return nil }
        return stored.rules.first { $0.matches(host: host) }
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
