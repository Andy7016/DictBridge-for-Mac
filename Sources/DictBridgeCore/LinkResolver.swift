import Foundation

/// Maps headwords and `@@@LINK=` redirects to entry indexes, the same way MDict looks
/// words up (case-insensitive, optionally ignoring punctuation when `StripKey` is on).
public final class LinkResolver {
    /// Headword of every real (non-redirect) entry, by entry index.
    public let headwords: [String]
    private var exact: [String: [Int]] = [:]
    private var loose: [String: [Int]] = [:]
    private var exactLinks: [String: String] = [:]
    private var looseLinks: [String: String] = [:]
    private let redirects: [(alias: String, target: String)]

    public init(headwords: [String], redirects: [(alias: String, target: String)]) {
        self.headwords = headwords
        self.redirects = redirects
        for (i, word) in headwords.enumerated() {
            exact[Self.normalize(word), default: []].append(i)
            let l = Self.looseKey(word)
            if !l.isEmpty { loose[l, default: []].append(i) }
        }
        for (alias, target) in redirects {
            let n = Self.normalize(alias)
            if exactLinks[n] == nil { exactLinks[n] = target }
            let l = Self.looseKey(alias)
            if !l.isEmpty, looseLinks[l] == nil { looseLinks[l] = target }
        }
    }

    /// Lower-cased, whitespace-collapsed key.
    public static func normalize(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        var lastWasSpace = false
        for scalar in s.lowercased().unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                if !lastWasSpace && !out.isEmpty { out.unicodeScalars.append(" ") }
                lastWasSpace = true
            } else {
                out.unicodeScalars.append(scalar)
                lastWasSpace = false
            }
        }
        if out.hasSuffix(" ") { out.removeLast() }
        return out
    }

    /// Letters and digits only (MDict's `StripKey` comparison).
    public static func looseKey(_ s: String) -> String {
        var out = ""
        for scalar in s.lowercased().unicodeScalars where CharacterSet.alphanumerics.contains(scalar) {
            out.unicodeScalars.append(scalar)
        }
        return out
    }

    /// Entry indexes for `word`, following redirect chains. `nil` if nothing matches.
    public func resolve(_ word: String) -> [Int]? {
        var w = word
        var seen = Set<String>()
        for _ in 0..<8 {
            let n = Self.normalize(w)
            if let hit = exact[n] { return hit }
            guard let next = exactLinks[n], !seen.contains(n) else { break }
            seen.insert(n)
            w = next
        }
        w = word
        seen.removeAll()
        for _ in 0..<8 {
            let l = Self.looseKey(w)
            if l.isEmpty { return nil }
            if let hit = loose[l] { return hit }
            guard let next = looseLinks[l], !seen.contains(l) else { break }
            seen.insert(l)
            w = next
        }
        return nil
    }

    /// Extra search keys for each entry, derived from the redirects that point at it.
    /// - Returns: entry index → alias headwords (deduplicated, never equal to the headword).
    public func aliasesByEntry() -> (aliases: [Int: [String]], unresolved: Int) {
        var result: [Int: [String]] = [:]
        var seen: [Int: Set<String>] = [:]
        var unresolved = 0
        for (alias, target) in redirects {
            guard let ids = resolve(target) else { unresolved += 1; continue }
            let n = Self.normalize(alias)
            if n.isEmpty { continue }
            for id in ids where Self.normalize(headwords[id]) != n {
                if seen[id, default: []].insert(n).inserted {
                    result[id, default: []].append(alias)
                }
            }
        }
        return (result, unresolved)
    }
}
