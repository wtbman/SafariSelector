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
        /// host -> target id, so a repeat visit pre-selects where it went last time.
        var lastChoiceByHost: [String: String] = [:]
        var lastChoice: String?
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
