import Foundation

// Diagnostics are intentionally silent and never touch the user's log or settings.
enum DebugLog { static func write(_ message: String) {} }

@main
struct RoutingRegressionTests {
    struct Failure: Error { let message: String }
    static var checks = 0

    static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(message: message) }
        checks += 1
    }

    static func request(_ base: URL, _ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: path, relativeTo: base)!)
        request.timeoutInterval = 4
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw Failure(message: "Unexpected HTTP status")
        }
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    static func isWaiting(_ base: URL, _ profile: String) async throws -> Bool {
        let status = try await request(base, "/status")
        let rows = status["activity"] as! [[String: Any]]
        return rows.first { $0["profileUUID"] as? String == profile }?["waitingForCommand"] as? Bool ?? false
    }

    static func waitForPoll(_ base: URL, _ profile: String, waiting: Bool) async throws {
        for _ in 0..<50 {
            if try await isWaiting(base, profile) == waiting { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw Failure(message: "Poll state never became \(waiting) for \(profile)")
    }

    static func main() async throws {
        let parsed = AppleScriptProbe.parseWindows("""
        1\tPersonal — Settings\t\t\t0\t0,0,480,630
        2\tSocial — Start Page\t\t\t1\t0,30,1920,1080
        3\tWTB — Example\thttps://example.com\tExample\t4\t1920,30,3840,1080
        """)
        try expect(parsed.map(\.appleScriptID) == [2, 3], "Non-browser zero-tab windows must not be picker targets")
        try expect(parsed.first?.activeTabURL == "" && parsed.first?.tabCount == 1,
                   "A real empty Start Page tab must remain a destination")

        let repeated = AppleScriptProbe.parseWindows("""
        10\tHome — Example\thttps://example.com\tExample\t4\t0,30,1920,1080
        10\tHome — Example\thttps://example.com\tExample\t4\t0,30,1920,1080
        11\tSocial — Example\thttps://example.com\tExample\t4\t0,30,1920,1080
        12\tHome — Example\thttps://example.com\tExample\t4\t1920,30,3840,1080
        """)
        try expect(repeated.map(\.appleScriptID) == [10, 11, 12],
                   "Duplicate window IDs must be removed while distinct windows with the same title remain")
        let invalidThenValid = AppleScriptProbe.parseWindows("""
        10\tHome — Example\t\t\t0\t0,30,1920,1080
        10\tHome — Example\t\t\t4\tinvalid
        10\tHome — Example\t\t\t4\t0,30,1920,1080
        """)
        try expect(invalidThenValid.count == 1 && invalidThenValid[0].tabCount == 4,
                   "An invalid duplicate must not hide the valid window record")

        let port = UInt16.random(in: 55000...59000)
        let server = try BridgeServer(port: port, token: "isolated-routing-test")
        server.statusProvider = { profiles, activity in
            try! JSONSerialization.data(withJSONObject: ["profiles": profiles, "activity": activity])
        }
        server.start()
        let base = URL(string: "http://127.0.0.1:\(port)")!
        for _ in 0..<50 {
            if (try? await request(base, "/status")) != nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        _ = try await request(base, "/snapshot", body: ["profileUUID": "snapshot-only", "windows": []])
        try expect(!server.connectedProfiles.contains("snapshot-only"),
                   "An old snapshot alone must not imply a live command channel")

        let expired = Bridge.Command.open(windowId: 99, url: "https://example.invalid/expired", match: nil)
        let expiredResult = await server.send(expired, to: "test-profile", timeout: 0.1)
        try expect(expiredResult == nil, "Unclaimed command must time out")

        let poll = Task { try await request(base, "/poll?profile=test-profile") }
        try await waitForPoll(base, "test-profile", waiting: true)
        let ping = Bridge.Command.relay(type: "PING", args: nil)
        let result = Task { await server.send(ping, to: "test-profile", timeout: 2) }
        let delivered = try await poll.value
        try expect(delivered["commandId"] as? String == ping.commandId,
                   "A late worker must never receive the expired OPEN")
        _ = try await request(base, "/result", body: ["profileUUID": "test-profile", "commandId": ping.commandId,
                                                       "result": ["ok": true]])
        let pingResult = await result.value
        try expect(pingResult?.ok == true, "Round-trip commands must complete")

        let abandoned = Task { try await request(base, "/poll?profile=abandoned") }
        try await waitForPoll(base, "abandoned", waiting: true)
        abandoned.cancel()
        _ = try? await abandoned.value
        try await waitForPoll(base, "abandoned", waiting: false)
        try expect(true, "A disconnected worker must stop appearing as a parked poll")

        let oldPoll = Task { try await request(base, "/poll?profile=replaced") }
        try await waitForPoll(base, "replaced", waiting: true)
        let newPoll = Task { try await request(base, "/poll?profile=replaced") }
        let oldAnswer = try await oldPoll.value
        try expect(oldAnswer["type"] as? String == "IDLE", "A new worker must replace the old poll")
        try await waitForPoll(base, "replaced", waiting: true)
        let newPing = Bridge.Command.relay(type: "PING", args: nil)
        let newResult = Task { await server.send(newPing, to: "replaced", timeout: 2) }
        let newAnswer = try await newPoll.value
        try expect(newAnswer["commandId"] as? String == newPing.commandId,
                   "Old connection cleanup must not remove the new worker's poll")
        _ = try await request(base, "/result", body: ["profileUUID": "replaced", "commandId": newPing.commandId,
                                                       "result": ["ok": true]])
        _ = await newResult.value
        print("Passed \(checks) routing regression checks.")
    }
}
