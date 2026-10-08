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

        // Reproduce the measured 2511pt secondary-display origin difference.
        let upperA = window(10, group: "Upper A", url: "https://a.example/", title: "A", count: 190, top: -1247)
        let upperB = window(11, group: "Upper B", url: "https://b.example/", title: "B", count: 48, top: -2520)
        let upperC = window(12, group: "Upper C", url: "https://c.example/", title: "C", count: 23, top: -3810)
        var shiftedA = reported(upperA, id: 110)
        var shiftedB = reported(upperB, id: 111)
        var shiftedC = reported(upperC, id: 112)
        shiftedA.top! += 2511
        shiftedB.top! += 2511
        shiftedC.top! += 2511
        let shiftedWindows = [upperA, upperB, upperC, lending]
        let shiftedSnapshot = ["personal": [shiftedA, shiftedB, shiftedC], "lending": [lendingReport]]
        let shifted = TargetStore.pairWindows(scriptWindows: shiftedWindows, snapshot: shiftedSnapshot)
        try expect(shifted[10]?.info.windowId == 110 && shifted[11]?.info.windowId == 111
                   && shifted[12]?.info.windowId == 112 && shifted[1]?.profile == "lending",
                   "Corroborated secondary-display offsets must coexist with ordinary coordinates")
        var shiftedSocial = socialReport
        shiftedSocial.top! += 2511
        let crossProfile = TargetStore.pairWindows(scriptWindows: shiftedWindows + [social],
            snapshot: ["personal": [shiftedA, shiftedB, shiftedC],
                       "lending": [lendingReport], "social": [shiftedSocial]])
        try expect(crossProfile[2]?.profile == "social" && crossProfile[2]?.info.windowId == 202,
                   "Confirmed display offsets must warm a uniquely identified single-window profile")
        shiftedSocial.top! += 300
        try expect(TargetStore.pairWindows(scriptWindows: shiftedWindows + [social],
            snapshot: ["personal": [shiftedA, shiftedB, shiftedC],
                       "lending": [lendingReport], "social": [shiftedSocial]])[2] == nil,
                   "A different offset must not borrow confirmation from another profile")
        try expect(TargetStore.pairWindows(scriptWindows: [upperA], snapshot: ["personal": [shiftedA]]).isEmpty,
                   "One distinct page alone must not justify ignoring a stale vertical position")
        try expect(TargetStore.pairWindows(scriptWindows: [upperA, upperB],
            snapshot: ["one": [shiftedA], "two": [shiftedB]]).isEmpty,
                   "Two uncorroborated single-window profiles must not establish an offset")
        var inconsistentB = shiftedB
        inconsistentB.top! += 300
        try expect(TargetStore.pairWindows(scriptWindows: [upperA, upperB],
            snapshot: ["personal": [shiftedA, inconsistentB]]).isEmpty,
                   "Unrelated window moves must not be mistaken for a shared origin")
        let repeatedA = window(13, group: "Repeated A", url: upperA.activeTabURL,
                               title: upperA.activeTabTitle, count: upperA.tabCount, top: -5100)
        let ambiguousShift = TargetStore.pairWindows(scriptWindows: shiftedWindows + [repeatedA],
                                                   snapshot: shiftedSnapshot)
        try expect(ambiguousShift[10] == nil && ambiguousShift[13] == nil
                   && ambiguousShift[11]?.info.windowId == 111 && ambiguousShift[12]?.info.windowId == 112,
                   "A confirmed offset must not guess which duplicate page owns a report")
        let blankUpper = window(14, group: "Blank", top: -6500)
        var blankReport = reported(blankUpper, id: 114)
        blankReport.top! += 2511
        try expect(TargetStore.pairWindows(scriptWindows: shiftedWindows + [blankUpper],
            snapshot: ["personal": [shiftedA, shiftedB, shiftedC, blankReport], "lending": [lendingReport]])[14] == nil,
                   "Confirmed offsets must not attribute blank pages with little identifying evidence")
        let sameURLA = window(15, group: "Same URL A", url: "https://same.example/", title: "Page", count: 2, top: -1000)
        let sameURLB = window(16, group: "Same URL B", url: "https://same.example/", title: "Page", count: 3, top: -2000)
        var sameReportA = reported(sameURLA, id: 115)
        var sameReportB = reported(sameURLB, id: 116)
        sameReportA.top! += 2511
        sameReportB.top! += 2511
        try expect(TargetStore.pairWindows(scriptWindows: [sameURLA, sameURLB],
            snapshot: ["personal": [sameReportA, sameReportB]]).isEmpty,
                   "Two counts of the same page must not count as independent offset evidence")

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

        // Changing Safari's front-to-back order must not change per-profile lists.
        for order in [Array(windows.reversed()), windows, Array(windows.reversed())] {
            restartedStore.apply(scriptWindows: order, snapshot: [:])
            try expect(restartedStore.windows(for: "social").map(\.appleScriptWindowID) == [2]
                       && restartedStore.windows(for: "lending").map(\.appleScriptWindowID) == [1],
                       "Focusing a window must not remove it or duplicate another profile's window")
        }
        restartedStore.apply(scriptWindows: nil, snapshot: [:])
        try expect(restartedStore.scanFailed && restartedStore.windowCount(for: "social") == 1,
                   "A failed scan must preserve the Show Window target and report refresh failure")
        restartedStore.apply(scriptWindows: windows, snapshot: [:])
        try expect(!restartedStore.scanFailed && restartedStore.windowCount(for: "social") == 1,
                   "A successful rescan must clear the failure and preserve open windows")
        restartedStore.apply(scriptWindows: [], snapshot: [:])
        try expect(!restartedStore.scanFailed && restartedStore.targets.isEmpty,
                   "A successful empty scan must remove genuinely closed windows")
        store.apply(scriptWindows: shiftedWindows, snapshot: shiftedSnapshot)
        let shiftedTarget = store.targets.first { $0.appleScriptWindowID == 11 }
        try expect(shiftedTarget?.bounds?.top == -2520 && shiftedTarget?.extensionBounds?.top == -9,
                   "OPEN geometry must retain the extension origin separately from native diagnostics")
        try expect(store.targets.first { $0.appleScriptWindowID == 10 }?.profileUUID == "personal",
                   "Corroborated multi-display pairs must be available as warm routing targets")
        print("Passed \(checks) window attribution regression checks.")
    }
}
