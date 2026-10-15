import Foundation
import MDictKit

/// An MDict dictionary on disk: the `.mdx` plus the companion files next to it.
public struct SourceDictionary: Sendable {
    public let mdx: URL
    /// `name.mdd`, `name.1.mdd`, `name.2.mdd`, … in order.
    public let mdds: [URL]
    /// Style sheets in the same folder.
    public let stylesheets: [URL]
    /// Scripts in the same folder.
    public let scripts: [URL]
    /// Fonts and images lying next to the dictionary (copied as resources).
    public let looseResources: [URL]

    public var folder: URL { mdx.deletingLastPathComponent() }
    public var baseName: String { mdx.deletingPathExtension().lastPathComponent }

    public var totalSize: Int64 {
        ([mdx] + mdds + stylesheets + scripts + looseResources).reduce(Int64(0)) { sum, url in
            sum + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    static let resourceExtensions: Set<String> = ["ttf", "otf", "woff", "woff2", "png", "jpg", "jpeg", "gif", "svg", "webp", "bmp"]

    /// Builds the source from an `.mdx`, an `.mdd`, or a folder that contains one `.mdx`.
    public init(url: URL) throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw ConversionError.sourceNotFound(url.path)
        }
        var mdx = url
        if isDir.boolValue {
            let items = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
            let mdxs = items.filter { $0.pathExtension.lowercased() == "mdx" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            guard let first = mdxs.first else { throw ConversionError.noMDX(url.path) }
            mdx = first
        } else if url.pathExtension.lowercased() == "mdd" {
            let candidate = Self.mddBase(url).appendingPathExtension("mdx")
            guard fm.fileExists(atPath: candidate.path) else { throw ConversionError.noMDX(url.path) }
            mdx = candidate
        } else if url.pathExtension.lowercased() != "mdx" {
            throw ConversionError.notMDict(url.lastPathComponent)
        }
        self.mdx = mdx

        let folder = mdx.deletingLastPathComponent()
        let base = mdx.deletingPathExtension().lastPathComponent.lowercased()
        let items = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []

        var mddParts: [(Int, URL)] = []
        var css: [URL] = []
        var js: [URL] = []
        var loose: [URL] = []
        for item in items {
            let ext = item.pathExtension.lowercased()
            let name = item.lastPathComponent.lowercased()
            switch ext {
            case "mdd":
                if name == base + ".mdd" {
                    mddParts.append((0, item))
                } else if name.hasPrefix(base + "."), let n = Int(name.dropFirst(base.count + 1).dropLast(4)) {
                    mddParts.append((n, item))
                }
            case "css": css.append(item)
            case "js": js.append(item)
            default:
                if Self.resourceExtensions.contains(ext) { loose.append(item) }
            }
        }
        mdds = mddParts.sorted { $0.0 < $1.0 }.map { $0.1 }
        stylesheets = css.sorted { $0.lastPathComponent < $1.lastPathComponent }
        scripts = js.sorted { $0.lastPathComponent < $1.lastPathComponent }
        looseResources = loose.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// `name.1.mdd` → `name`
    static func mddBase(_ url: URL) -> URL {
        var u = url.deletingPathExtension()
        if Int(u.pathExtension) != nil { u = u.deletingPathExtension() }
        return u
    }

    /// Reads the header to suggest a display name.
    public func suggestedName() -> String {
        if let header = try? MDictFile.header(of: mdx), let title = header.usableTitle,
           !title.lowercased().hasSuffix(".mdx") {
            return title
        }
        return baseName
    }
}
