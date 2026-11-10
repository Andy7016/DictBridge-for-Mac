import Foundation

/// A release newer than the running version.
public struct AvailableUpdate: Sendable, Equatable {
    public let version: String
    /// The release page to open in the browser.
    public let page: URL
}

public enum UpdateCheckError: LocalizedError {
    case badResponse(String)

    public var errorDescription: String? {
        switch self {
        case .badResponse(let detail): return "Could not read the latest release from GitHub (\(detail))."
        }
    }
}

/// Looks up the latest release on GitHub. Nothing about the user or the Mac is sent: it is one
/// GET request to GitHub's public API.
public enum UpdateChecker {
    public static let latestReleaseAPI = URL(string: "https://api.github.com/repos/Andy7016/DictBridge-for-Mac/releases/latest")!
    public static let releasesPage = URL(string: "https://github.com/Andy7016/DictBridge-for-Mac/releases/latest")!

    /// Numeric components of a version such as `v0.4.1` or `1.2.0-beta.1` (the suffix is ignored).
    static func components(_ version: String) -> [Int]? {
        var s = Substring(version.trimmingCharacters(in: .whitespacesAndNewlines))
        if s.hasPrefix("v") || s.hasPrefix("V") { s = s.dropFirst() }
        if let cut = s.firstIndex(where: { $0 == "-" || $0 == "+" }) { s = s[..<cut] }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(part) else { return nil }
            numbers.append(n)
        }
        return numbers
    }

    /// Whether `candidate` is a later version than `current`. Unreadable versions are never newer.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let a = components(candidate), let b = components(current) else { return false }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Reads GitHub's "latest release" JSON. Returns nil when it is not newer than `current`.
    static func parse(_ data: Data, current: String) throws -> AvailableUpdate? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String, components(tag) != nil else {
            throw UpdateCheckError.badResponse("unexpected reply")
        }
        guard isNewer(tag, than: current) else { return nil }
        var page = releasesPage
        // Only ever open a github.com page, whatever the reply says.
        if let text = object["html_url"] as? String, let url = URL(string: text),
           url.scheme == "https", url.host == "github.com" {
            page = url
        }
        var version = tag
        if version.hasPrefix("v") || version.hasPrefix("V") { version.removeFirst() }
        return AvailableUpdate(version: version, page: page)
    }

    /// Asks GitHub for the latest release. Returns nil when the running version is current.
    public static func check(current: String = DictBridge.version) async throws -> AvailableUpdate? {
        var request = URLRequest(url: latestReleaseAPI, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("DictBridge/\(current)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UpdateCheckError.badResponse("HTTP \(http.statusCode)")
        }
        return try parse(data, current: current)
    }
}
