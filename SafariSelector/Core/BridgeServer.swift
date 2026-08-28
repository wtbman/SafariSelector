import Foundation
import Network
import os.log

/// Loopback HTTP server that every Safari profile's extension instance talks to.
///
/// HTTP long-polling rather than a WebSocket: the capability spike verified that
/// `fetch()` to `http://127.0.0.1` works from a Safari extension, `ws://` was never
/// verified, and an in-flight fetch has the useful side effect of keeping the MV3
/// background worker alive.
///
/// Routes:
///   POST /snapshot  — an instance reports its windows
///   GET  /poll      — an instance parks here until the app has a command for it
///   POST /result    — an instance reports a command's outcome
final class BridgeServer {

    static let port: UInt16 = 53127

    private let listener: NWListener
    private let queue = DispatchQueue(label: "cc.wtb.SafariSelector.bridge")
    private let log = Logger(subsystem: "cc.wtb.SafariSelector", category: "bridge")

    /// Shared secret handed to instances via the native discovery handler.
    let token: String

    /// Connections parked on /poll, keyed by profile UUID. A profile is only
    /// present here while a poll is actually in flight — there is always a gap
    /// between one poll returning and the next arriving, which is why commands are
    /// queued rather than requiring a live waiter.
    private var waiters: [String: (Bridge.Command) -> Void] = [:]
    /// Commands waiting for their profile's next poll.
    private var queued: [String: [Bridge.Command]] = [:]
    /// Every profile that has ever polled or pushed, whether or not it is mid-poll.
    private(set) var knownProfiles: Set<String> = []
    /// Callbacks awaiting a command result, keyed by command id.
    private var pending: [String: (Bridge.CommandResult) -> Void] = [:]

    var onSnapshot: ((String, [Bridge.WindowInfo]) -> Void)?
    /// Supplies the merged target list for the status endpoint. Receives the
    /// connected profile list as an argument: it is invoked while already on the
    /// bridge queue, so it must never call back into a queue-synchronised property.
    var statusProvider: (([String]) -> Data)?

    init() throws {
        token = BridgeServer.loadOrCreateToken()
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Bind loopback only: nothing outside this machine should reach the bridge.
        if let tcp = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            tcp.version = .v4
        }
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback),
                                                 port: .init(rawValue: BridgeServer.port)!)
        listener = try NWListener(using: params)
    }

    func start() {
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            conn.start(queue: self.queue)
            self.receive(conn, buffer: Data())
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.log.info("bridge listening on 127.0.0.1:\(BridgeServer.port)")
                FileHandle.standardError.write(Data("bridge ready on \(BridgeServer.port)\n".utf8))
            case .failed(let error), .waiting(let error):
                self.log.error("bridge listener: \(String(describing: error), privacy: .public)")
                FileHandle.standardError.write(Data("bridge error: \(error)\n".utf8))
            default:
                break
            }
        }
        listener.start(queue: queue)
    }

    // MARK: - Sending commands

    /// Hands `command` to the given profile's instance and waits for its result.
    /// Returns nil if that profile is not currently polling, or if it doesn't answer.
    func send(_ command: Bridge.Command, to profileUUID: String,
              timeout: TimeInterval = 5) async -> Bridge.CommandResult? {
        await withCheckedContinuation { continuation in
            queue.async {
                var settled = false
                self.pending[command.commandId] = { result in
                    guard !settled else { return }
                    settled = true
                    continuation.resume(returning: result)
                }
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    guard !settled else { return }
                    settled = true
                    self.pending.removeValue(forKey: command.commandId)
                    continuation.resume(returning: nil)
                }
                // Hand it to a parked poll if there is one, otherwise queue it for
                // the next poll. A profile between polls is not a dead profile.
                if let waiter = self.waiters.removeValue(forKey: profileUUID) {
                    waiter(command)
                } else {
                    self.queued[profileUUID, default: []].append(command)
                }
            }
        }
    }

    /// Profiles that have made contact. Deliberately not "profiles currently parked
    /// on a poll" — that set flickers empty between polls.
    var connectedProfiles: [String] {
        queue.sync { Array(knownProfiles) }
    }

    // MARK: - Connection handling

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isDone, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if error != nil { conn.cancel(); return }

            guard let headerEnd = buf.range(of: Data("\r\n\r\n".utf8)) else {
                if isDone { conn.cancel() } else { self.receive(conn, buffer: buf) }
                return
            }
            let head = String(decoding: buf[..<headerEnd.lowerBound], as: UTF8.self)
            let lines = head.split(separator: "\r\n", omittingEmptySubsequences: false)
            guard let requestLine = lines.first else { conn.cancel(); return }
            let parts = requestLine.split(separator: " ")
            guard parts.count >= 2 else { conn.cancel(); return }
            let method = String(parts[0]), target = String(parts[1])

            let contentLength = lines
                .first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0

            let body = buf[headerEnd.upperBound...]
            if body.count < contentLength {
                if isDone { conn.cancel() } else { self.receive(conn, buffer: buf) }
                return
            }
            self.handle(conn, method: method, target: target, body: Data(body.prefix(contentLength)))
        }
    }

    private func handle(_ conn: NWConnection, method: String, target: String, body: Data) {
        // The extension's fetch of application/json triggers a CORS preflight.
        if method == "OPTIONS" { respond(conn, status: 204, json: nil); return }

        let path = target.split(separator: "?").first.map(String.init) ?? target
        let query = queryItems(target)

        switch (method, path) {
        case ("POST", "/snapshot"):
            guard let snap = try? JSONDecoder().decode(Bridge.Snapshot.self, from: body),
                  authorised(snap.token) else { respond(conn, status: 403, json: nil); return }
            knownProfiles.insert(snap.profileUUID)
            onSnapshot?(snap.profileUUID, snap.windows)
            respond(conn, status: 200, json: ["ok": true])

        case ("GET", "/poll"):
            guard let profile = query["profile"], authorised(query["token"]) else {
                respond(conn, status: 403, json: nil); return
            }
            park(conn, profile: profile)

        case ("POST", "/result"):
            guard let env = try? JSONDecoder().decode(Bridge.ResultEnvelope.self, from: body),
                  authorised(env.token) else { respond(conn, status: 403, json: nil); return }
            if let cb = pending.removeValue(forKey: env.commandId) { cb(env.result) }
            respond(conn, status: 200, json: ["ok": true])

        case ("GET", "/status"):
            // Read-only introspection: what the app currently believes is openable.
            let body = statusProvider?(Array(knownProfiles)) ?? Data("[]".utf8)
            write(conn, status: 200, body: body)

        default:
            respond(conn, status: 404, json: nil)
        }
    }

    /// Holds the connection open until there is a command for this profile, or the
    /// poll ages out. Replacing an existing waiter is deliberate — a profile only
    /// ever has one live instance, and a stale parked connection must not win.
    private func park(_ conn: NWConnection, profile: String) {
        knownProfiles.insert(profile)
        // Anything queued while this profile was between polls goes out immediately.
        if var pendingForProfile = queued[profile], !pendingForProfile.isEmpty {
            let next = pendingForProfile.removeFirst()
            queued[profile] = pendingForProfile
            respond(conn, status: 200, jsonEncodable: next)
            return
        }
        waiters[profile]?(Bridge.Command.idle)
        var answered = false
        let reply: (Bridge.Command) -> Void = { [weak self] cmd in
            guard let self, !answered else { return }
            answered = true
            self.respond(conn, status: 200, jsonEncodable: cmd)
        }
        waiters[profile] = reply
        queue.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, !answered else { return }
            if self.waiters[profile] != nil { self.waiters.removeValue(forKey: profile) }
            reply(Bridge.Command.idle)
        }
    }

    // MARK: - Responses

    private func respond(_ conn: NWConnection, status: Int, json: [String: Any]?) {
        let body = json.flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data()
        write(conn, status: status, body: body)
    }

    private func respond<T: Encodable>(_ conn: NWConnection, status: Int, jsonEncodable: T) {
        let body = (try? JSONEncoder().encode(jsonEncodable)) ?? Data()
        write(conn, status: status, body: body)
    }

    private func write(_ conn: NWConnection, status: Int, body: Data) {
        var head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "")\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Access-Control-Allow-Origin: *\r\n"
        head += "Access-Control-Allow-Headers: Content-Type\r\n"
        head += "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
        head += "Connection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + body,
                  completion: .contentProcessed { _ in conn.cancel() })
    }

    private func authorised(_ candidate: String?) -> Bool {
        // A missing token is tolerated so a freshly enabled instance can still make
        // contact; the listener is loopback-only either way.
        guard let candidate, !candidate.isEmpty else { return true }
        return candidate == token
    }

    private func queryItems(_ target: String) -> [String: String] {
        guard let q = target.split(separator: "?").dropFirst().first else { return [:] }
        var out: [String: String] = [:]
        for pair in q.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            out[String(kv[0])] = String(kv[1]).removingPercentEncoding ?? String(kv[1])
        }
        return out
    }

    // MARK: - Token

    static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SafariSelector")
    }

    private static func loadOrCreateToken() -> String {
        let dir = supportDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("bridge.json")
        if let data = try? Data(contentsOf: file),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let existing = obj["token"] as? String, !existing.isEmpty {
            return existing
        }
        let fresh = UUID().uuidString
        let payload: [String: Any] = ["port": Int(BridgeServer.port), "token": fresh]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted) {
            try? data.write(to: file, options: .atomic)
        }
        return fresh
    }
}
