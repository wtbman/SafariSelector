import Foundation

// Use production matching and persistence with isolated storage; never contact Safari.
enum BridgeServer {
    static let supportDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("SafariSelector-attribution-tests-\(UUID().uuidString)")
}
enum DebugLog { static func write(_ message: String) {} }

@main
struct WindowAttributionTests {
    struct Failure: Error { let message: String }
    static var checks = 0

    static func expect(_ value: Bool, _ message: String) throws {
        guard value else { throw Failure(message: message) }
        checks += 1
    }

    static func window(_ id: Int, group: String, url: String = "", title: String = "Start Page",
                       count: Int = 1, top: Int = 40) -> AppleScriptProbe.Window {
        AppleScriptProbe.Window(appleScriptID: id, prefix: group, activeTabURL: url,
            activeTabTitle: title, tabCount: count,
            bounds: .init(left: 0, top: top, width: 1200, height: 900))
    }

    static func reported(_ w: AppleScriptProbe.Window, id: Int) -> Bridge.WindowInfo {
        Bridge.WindowInfo(windowId: id, focused: false, tabCount: w.tabCount,
            activeTabUrl: w.activeTabURL, activeTabTitle: w.activeTabTitle,
            left: w.bounds.left, top: w.bounds.top, width: w.bounds.width, height: w.bounds.height)
    }

    static func main() throws {
        defer { try? FileManager.default.removeItem(at: BridgeServer.supportDirectory) }
        let lending = window(1, group: "Lending", count: 1)
        let social = window(2, group: "Social", url: "https://social.example/", title: "Social", count: 58)
        let lendingReport = reported(lending, id: 101)
        let socialReport = reported(social, id: 202)
        let windows = [lending, social]
        let snapshot = ["lending": [lendingReport], "social": [socialReport]]
        let paired = TargetStore.pairWindows(scriptWindows: windows, snapshot: snapshot)
        try expect(paired[1]?.profile == "lending" && paired[2]?.profile == "social",
                   "Overlapping windows must use page and tab-count evidence to find the right profile")

        let partial = TargetStore.pairWindows(scriptWindows: windows, snapshot: ["social": [socialReport]])
        try expect(partial[1] == nil && partial[2]?.profile == "social",
                   "A missing profile snapshot must not donate its window to another profile")

        let twin = window(3, group: "Another profile")
        try expect(TargetStore.pairWindows(scriptWindows: [lending, twin], snapshot: ["lending": [lendingReport]]).isEmpty,
                   "A single report matching two real windows must remain ambiguous")
        try expect(TargetStore.pairWindows(scriptWindows: [lending], snapshot: ["lending": [lendingReport], "other": [lendingReport]]).isEmpty,
                   "Two indistinguishable profile reports must never be resolved by dictionary order")

        let lower = window(4, group: "Other", top: 1100)
        let separate = TargetStore.pairWindows(scriptWindows: [lending, lower],
            snapshot: ["lending": [lendingReport], "other": [reported(lower, id: 404)]])
        try expect(separate[1]?.profile == "lending" && separate[4]?.profile == "other",
                   "Repeated Start Pages can still match when their full geometry is distinct")
        try expect(TargetStore.pairWindows(scriptWindows: [lower], snapshot: ["lending": [lendingReport]]).isEmpty,
                   "A stale vertical position must not be ignored when learning ownership")
        let differentCount = window(5, group: "Other", count: 2)
        try expect(TargetStore.pairWindows(scriptWindows: [differentCount], snapshot: ["lending": [lendingReport]]).isEmpty,
                   "Matching geometry and page must not override a mismatched tab count")
        var missingGeometry = lendingReport
        missingGeometry.top = nil
        try expect(TargetStore.pairWindows(scriptWindows: [lending], snapshot: ["lending": [missingGeometry]]).isEmpty,
                   "Incomplete geometry must leave ownership unresolved")

        let config = Config()
        config.stored.profileAliases = ["lending": "Lending profile", "social": "Social profile"]
        let store = TargetStore(config: config)
        store.apply(scriptWindows: windows, snapshot: ["social": [socialReport]])
        try expect(config.profileOwning(group: "Lending") == nil && store.windowCount(for: "social") == 1,
                   "Partial discovery must not persist a false Lending-to-Social association")
        try expect(store.targets.first { $0.appleScriptWindowID == 1 }?.profileLabel == "Unknown profile",
                   "An unresolved window must not display another profile's name")

        // Reproduce the poisoned remembered mapping, then repair it with a verified match.
        config.learn(group: "Lending", belongsTo: "social")
        store.apply(scriptWindows: windows, snapshot: snapshot)
        try expect(config.profileOwning(group: "Lending") == "lending",
                   "Verified live evidence must replace a bad remembered association")
        try expect(store.windowCount(for: "lending") == 1 && store.windowCount(for: "social") == 1,
                   "Profile counts must reflect corrected ownership")
        try expect(store.windows(for: "lending").map(\.appleScriptWindowID) == [1],
                   "Show Window must select the corrected profile's actual window")
        try expect(config.profileNamingHints(for: "social", targets: store.targets) == ["Social"],
                   "The wrong group must disappear from Social's naming hints")

        let reloaded = Config()
        let restartedStore = TargetStore(config: reloaded)
        restartedStore.apply(scriptWindows: windows, snapshot: [:])
        try expect(restartedStore.windows(for: "lending").map(\.appleScriptWindowID) == [1]
                   && restartedStore.windowCount(for: "social") == 1,
                   "Corrected ownership must survive restart while the extension is unavailable")
        try expect(reloaded.stored.profileAliases == config.stored.profileAliases,
                   "Learning ownership must preserve user-assigned profile names")
        print("Passed \(checks) window attribution regression checks.")
    }
}
