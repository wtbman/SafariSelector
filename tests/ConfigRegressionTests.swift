import Foundation

// Compile the production Config and SafariTarget without starting the app,
// contacting Safari, or accessing the user's Application Support directory.
enum BridgeServer {
    static let supportDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("SafariSelector-config-tests-\(UUID().uuidString)")
}

enum AppleScriptProbe {
    struct Bounds: Hashable {}
}

@main
struct ConfigRegressionTests {
    struct Failure: Error { let message: String }
    static var checks = 0

    static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(message: message) }
        checks += 1
    }

    static func decode(_ json: [String: Any]) throws -> Config.Stored {
        try JSONDecoder().decode(Config.Stored.self, from: JSONSerialization.data(withJSONObject: json))
    }

    static func roundTrip(_ settings: Config.Stored) throws -> Config.Stored {
        try JSONDecoder().decode(Config.Stored.self, from: JSONEncoder().encode(settings))
    }

    static func target(_ id: Int, _ profile: String, _ group: String?) -> SafariTarget {
        SafariTarget(appleScriptWindowID: id, profileUUID: profile, windowId: id,
                     profileLabel: profile, tabGroupLabel: group, activeTabTitle: "Example",
                     activeTabURL: "https://example.com", tabCount: 1, isFocused: false, bounds: nil)
    }

    static func main() throws {
        defer { try? FileManager.default.removeItem(at: BridgeServer.supportDirectory) }
        let oldSettings: [String: Any] = [
            "profileAliases": ["work-id": "Work"],
            "rules": [["id": "00000000-0000-0000-0000-000000000001", "pattern": "example.com",
                       "profileUUID": "work-id", "tabGroupLabel": "Tickets"]],
            "groupToProfile": ["Tickets": "work-id"],
            "lastChoiceByHost": ["example.com": "group:work-id:Tickets"],
            "lastChoice": "group:work-id:Tickets"
        ]
        let old = try decode(oldSettings)
        try expect(old.profileAliases["work-id"] == "Work" && old.rules.count == 1,
                   "Missing newer keys must not discard aliases or rules")
        try expect(old.autoSelectSeconds == 0 && !old.autoAllowUnsignedExtensions,
                   "Missing settings must receive defaults")
        let reloaded = try roundTrip(old)
        try expect(reloaded.profileAliases == old.profileAliases && reloaded.rules == old.rules
                   && reloaded.groupToProfile == old.groupToProfile
                   && reloaded.lastChoiceByHost == old.lastChoiceByHost && reloaded.lastChoice == old.lastChoice,
                   "Saving older settings must preserve all user data")
        let defaults = try decode([:])
        try expect(defaults.rules.isEmpty && defaults.profileAliases.isEmpty && !defaults.hasAutoSelectPattern,
                   "An empty settings object must load with defaults")
        let nulls = try decode(["autoSelectProfilePattern": NSNull(), "autoSelectGroupPattern": NSNull(),
                                "autoSelectPattern": NSNull(), "autoSelectSeconds": NSNull()])
        try expect(!nulls.hasAutoSelectPattern && nulls.autoSelectSeconds == 0,
                   "Null optional settings must receive defaults")

        let tickets = target(1, "Work", "Tickets")
        let personalTickets = target(2, "Personal", "Tickets")
        let ticketsProfile = target(3, "Tickets", "Inbox")
        let loose = target(4, "Work", nil)
        let archive = target(5, "Work", "Tickets — Archive")
        let targets = [personalTickets, ticketsProfile, loose, archive, tickets]
        let config = Config()
        let legacyCases: [(String, SafariTarget?)] = [
            ("Tickets", tickets), ("*Tickets", tickets), ("Work*", tickets),
            ("Work*Tickets", tickets), ("Work — Tick", tickets),
            ("Work — T?ckets", tickets), ("* — Tickets", tickets),
            ("  tIcKeTs  ", tickets), ("loose tabs", loose),
            ("Work — Tickets — Archive", archive), ("Missing", nil)
        ]
        for (pattern, expected) in legacyCases {
            var json = oldSettings
            json["autoSelectPattern"] = pattern
            json["autoSelectSeconds"] = 10
            config.stored = try decode(json)
            try expect(config.stored.legacyAutoSelectPattern == pattern,
                       "Legacy pattern must be retained verbatim: \(pattern)")
            try expect(config.autoSelectTarget(from: targets) == expected,
                       "Legacy matching changed: \(pattern)")
            config.stored.profileAliases["another-id"] = "Another"
            let diskConfig = Config()
            try expect(diskConfig.stored.rules == old.rules
                       && diskConfig.stored.legacyAutoSelectPattern == pattern
                       && diskConfig.autoSelectTarget(from: targets) == expected,
                       "An unrelated settings change must preserve legacy matching after restart: \(pattern)")
        }

        config.stored = try decode(["autoSelectPattern": "Tickets"])
        config.stored.legacyAutoSelectPattern = nil
        config.stored = try roundTrip(config.stored)
        try expect(!config.stored.hasAutoSelectPattern && config.autoSelectTarget(from: targets) == nil,
                   "Choosing separate fields must not resurrect an old pattern or select an arbitrary window")

        let separateCases: [(String, String, SafariTarget?)] = [
            ("Work", "Tickets", tickets), ("wOrK*", "tIck?ts", tickets),
            ("", "Tickets", tickets), ("Tickets", "", ticketsProfile),
            ("Work", "loose tabs", loose), ("Personal", "Tickets", personalTickets),
            ("Work", "Missing", nil), ("Missing", "Tickets", nil), (" ", " ", nil)
        ]
        for (profile, group, expected) in separateCases {
            config.stored.autoSelectProfilePattern = profile
            config.stored.autoSelectGroupPattern = group
            try expect(config.autoSelectTarget(from: targets) == expected,
                       "Separate fields matched incorrectly: \(profile) / \(group)")
        }
        let explicitNew = try decode(["autoSelectPattern": "Work*",
                                      "autoSelectProfilePattern": "Personal", "autoSelectGroupPattern": "Tickets"])
        config.stored = explicitNew
        try expect(config.stored.legacyAutoSelectPattern == nil
                   && config.autoSelectTarget(from: targets) == personalTickets,
                   "Explicit separate patterns must take precedence over a stale legacy key")
        config.stored = try decode(["autoSelectPattern": "   "])
        try expect(config.stored.legacyAutoSelectPattern == nil && !config.stored.hasAutoSelectPattern,
                   "Whitespace-only legacy patterns must not enable auto-selection")
        print("Passed \(checks) config regression checks.")
    }
}
