//
//  SafariSelector — open links in a chosen Safari window's active tab group.
//  Copyright (C) 2026 SafariSelector contributors
//
//  This program is free software: you can redistribute it and/or modify it under
//  the terms of the GNU General Public License as published by the Free Software
//  Foundation, either version 3 of the License, or (at your option) any later
//  version. See <https://www.gnu.org/licenses/>.
//

import SafariServices
import os.log

/// Discovery endpoint for the bridge.
///
/// This exists for one reason the JavaScript side cannot cover: Safari passes the
/// native handler `SFExtensionProfileKey`, a stable per-profile UUID. Nothing in the
/// WebExtension API exposes profile identity, so this is the only way an instance can
/// tell the app *which profile* it speaks for.
///
/// It also attempts to hand back the app's shared auth token. In practice that read
/// usually fails: Safari requires web extension appexes to be sandboxed (pluginkit
/// silently refuses to register an unsandboxed one), so this process cannot see
/// ~/Library/Application Support. The bridge therefore accepts token-less instances
/// and relies on being bound to loopback only. See docs/SPIKE-FINDINGS.md.
class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {

    func beginRequest(with context: NSExtensionContext) {
        let request = context.inputItems.first as? NSExtensionItem
        let profile = request?.userInfo?[SFExtensionProfileKey] as? UUID

        var payload: [String: Any] = [
            "port": BridgeFile.port,
            "profileUUID": profile?.uuidString ?? "default",
        ]
        if let token = BridgeFile.readToken() {
            payload["token"] = token
        }

        os_log(.default, "SafariSelector: discovery for profile %{public}@",
               profile?.uuidString ?? "default")

        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: payload]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }
}

enum BridgeFile {
    /// Fixed loopback port. The extension hard-codes the same value so that a first
    /// contact is possible before any file has been read.
    static let port = 53127

    static var url: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SafariSelector/bridge.json")
    }

    static func readToken() -> String? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj["token"] as? String
    }
}
