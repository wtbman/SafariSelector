import Foundation

// Isolate Safari and user settings while exercising the production Opener and
// BridgeServer. These stand-ins are compiled only by test-opener.sh.
enum DebugLog { static func write(_ message: String) {} }
enum AppleScriptProbe {
    static let queue = DispatchQueue(label: "opener-test-probe")
    static func focus(windowID: Int) {}
}
struct SafariTarget {
    struct Bounds { var left = 0, top = 0, width = 100, height = 100 }
    var appleScriptWindowID: Int? = 42
    var profileUUID: String? = "slow-profile"
    var windowId: Int? = 7
    var isWarm = true
    var displayLabel = "Test"
    var extensionBounds: Bounds? = nil
}
final class TargetStore {
    var targets = [SafariTarget()]
    func rebuild(_ completion: (() -> Void)? = nil) { completion?() }
}

@main
struct OpenerReadinessTests {
    struct Failure: Error { let message: String }
    static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }

    static func request(_ base: URL, _ path: String,
                        body: [String: Any]? = nil) async throws -> Data {
        var req = URLRequest(url: URL(string: path, relativeTo: base)!)
        req.timeoutInterval = 12
        if let body {
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        try expect((response as? HTTPURLResponse)?.statusCode == 200, "HTTP request failed")
        return data
    }

    static func main() async throws {
        let port = UInt16.random(in: 55000...59000)
        let server = try BridgeServer(port: port, token: "isolated-opener-test")
        server.start()
        let base = URL(string: "http://127.0.0.1:\(port)")!
        for _ in 0..<50 {
            if (try? await request(base, "/status")) != nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let store = TargetStore()
        let opener = Opener(bridge: server, store: store)
        var noWindow = SafariTarget()
        noWindow.appleScriptWindowID = nil
        let missing = await opener.resolve(noWindow)
        try expect(missing == nil, "A target without a Safari window must remain unresolved")

        let worker = Task {
            let data = try await request(base, "/poll?profile=slow-profile")
            let cmd = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            try expect(cmd["type"] as? String == "PING", "Readiness must use a harmless PING")
            // Longer than the former one-second deadline, but still healthy.
            try await Task.sleep(nanoseconds: 1_500_000_000)
            _ = try await request(base, "/result", body: [
                "profileUUID": "slow-profile", "commandId": cmd["commandId"]!,
                "result": ["ok": true],
            ])
        }
        let ready = await opener.resolve(store.targets[0])
        try await worker.value
        try expect(ready?.windowId == 7 && ready?.profileUUID == "slow-profile",
                   "A delayed healthy reply must resolve the intended window instead of falling back")
        print("Passed 3 opener readiness checks.")
    }
}
