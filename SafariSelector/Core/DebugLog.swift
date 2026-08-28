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

/// Append-only diagnostic log.
///
/// os_log is awkward to read back for a background agent launched by LaunchServices,
/// so the interesting decisions in the open pipeline are also written to a plain file.
enum DebugLog {
    private static let queue = DispatchQueue(label: "cc.wtb.SafariSelector.debuglog")
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static var url: URL {
        BridgeServer.supportDirectory.appendingPathComponent("debug.log")
    }

    static func write(_ message: String) {
        queue.async {
            let line = "\(formatter.string(from: Date()))  \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            try? FileManager.default.createDirectory(at: BridgeServer.supportDirectory,
                                                     withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }
}
