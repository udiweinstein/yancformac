import AppKit
import Foundation

/// "Check for Updates…" in the app menu: compares this build with the VERSION file on GitHub.
@MainActor
enum UpdateChecker {
    nonisolated static let repo = "udiweinstein/yancformac"
    static let fallbackVersion = "1.1.0"          // used when run with `swift run` (no app bundle)

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? fallbackVersion
    }

    static func check() {
        let url = URL(string: "https://raw.githubusercontent.com/\(repo)/main/VERSION")!
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        URLSession.shared.dataTask(with: request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let latest = data.flatMap { String(data: $0, encoding: .utf8) }?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let errorText = error?.localizedDescription
            Task { @MainActor in
                if let errorText {
                    show("Could not check for updates", errorText)
                } else if status != 200 || latest?.isEmpty != false {
                    show("Could not check for updates", "GitHub answered with status \(status).")
                } else if let latest, isNewer(latest, than: currentVersion) {
                    let alert = NSAlert()
                    alert.messageText = "A new version is available"
                    alert.informativeText = "YANC for Mac \(latest) is available – you have \(currentVersion)."
                    alert.addButton(withTitle: "Open Download Page")
                    alert.addButton(withTitle: "Later")
                    if alert.runModal() == .alertFirstButtonReturn {
                        NSWorkspace.shared.open(URL(string: "https://github.com/\(repo)/releases/latest")!)
                    }
                } else {
                    show("You're up to date", "YANC for Mac \(currentVersion) is the latest version.")
                }
            }
        }.resume()
    }

    /// Numeric compare of dotted versions: "1.10" > "1.9", "1.0.1" > "1.0".
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private static func show(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}
