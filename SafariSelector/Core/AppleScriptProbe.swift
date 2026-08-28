import Foundation
import os.log

/// Safari's AppleScript view of its windows.
///
/// Two things only AppleScript can do, and both are essential:
///   1. Name the tab group a window is showing. Safari's scripting dictionary has no
///      tab group class, but a window's `name` renders as "TabGroupName — PageTitle"
///      (or "ProfileName — PageTitle" for a window showing loose tabs). That prefix is
///      the only place a tab group's name is exposed anywhere.
///   2. See *every* window across *every* profile. An extension instance only ever
///      sees its own profile's windows, and only while that profile is awake.
enum AppleScriptProbe {

    struct Window {
        let appleScriptID: Int
        /// Tab group name, or the profile name for a loose-tab window.
        let prefix: String?
        let activeTabURL: String
        let activeTabTitle: String
        let tabCount: Int
    }

    private static let log = Logger(subsystem: "cc.wtb.SafariSelector", category: "applescript")

    /// NSAppleScript is not thread-safe, and a query against Safari can be slow when
    /// windows hold hundreds of tabs, so every call is funnelled through one
    /// dedicated serial queue — never the main queue, and never a Network queue.
    static let queue = DispatchQueue(label: "cc.wtb.SafariSelector.applescript")

    /// U+2014 EM DASH, the separator Safari uses between prefix and page title.
    private static let separator = " — "

    private static let listScript = """
    tell application "Safari"
        set out to ""
        repeat with w in windows
            try
                set out to out & (id of w as text) & "\\t" & (name of w) & "\\t" ¬
                    & (URL of current tab of w) & "\\t" & (name of current tab of w) & "\\t" ¬
                    & (count of tabs of w)  & "\\n"
            end try
        end repeat
        return out
    end tell
    """

    static func windows() -> [Window] {
        guard let output = run(listScript) else { return [] }
        var result: [Window] = []
        for line in output.split(separator: "\n") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard f.count >= 5, let wid = Int(f[0]) else { continue }
            let name = String(f[1])
            let prefix = name.components(separatedBy: separator).first
            result.append(Window(
                appleScriptID: wid,
                prefix: (prefix?.isEmpty == false && prefix != name) ? prefix : nil,
                activeTabURL: String(f[2]),
                activeTabTitle: String(f[3]),
                tabCount: Int(f[4]) ?? 0
            ))
        }
        return result
    }

    /// Brings a window to the front. This is also how a dormant profile is woken:
    /// focusing one of its windows fires `windows.onFocusChanged` inside that
    /// profile, which starts its extension worker.
    static func focus(windowID: Int) {
        let ok = run("""
        tell application "Safari"
            activate
            set index of window id \(windowID) to 1
        end tell
        """)
        DebugLog.write("focus(window \(windowID)) -> \(ok == nil ? "FAILED" : "ok")")
    }

    private static func run(_ source: String) -> String? {
        var error: NSDictionary?
        guard let apple = NSAppleScript(source: source) else { return nil }
        let out = apple.executeAndReturnError(&error)
        if let error {
            let message = (error[NSAppleScript.errorMessage] as? String) ?? String(describing: error)
            let number = (error[NSAppleScript.errorNumber] as? Int).map(String.init) ?? "?"
            log.warning("AppleScript failed (\(number, privacy: .public)): \(message, privacy: .public)")
            DebugLog.write("AppleScript error \(number): \(message)")
            return nil
        }
        // Empty string, not nil, when the script simply has no result — nil is
        // reserved for an actual error so callers can tell the two apart.
        return out.stringValue ?? ""
    }
}
