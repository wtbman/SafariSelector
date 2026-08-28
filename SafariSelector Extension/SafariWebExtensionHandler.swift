//
//  SafariWebExtensionHandler.swift
//  SafariSelector Extension
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
/// It also hands back the shared auth token, read from the app's bridge file. That
/// read is why this target is not sandboxed.
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
