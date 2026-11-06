import Darwin
import Foundation

/// A conversion's build folder, `~/Library/Caches/DictBridge/build-<UUID>`.
///
/// The folder holds a locked file for as long as its conversion runs. The lock goes away with
/// the process, so folders left behind by a conversion that never finished (the app was force
/// quit or crashed, the Mac lost power) can be told apart from folders in use and removed.
public final class WorkDirectory {
    static let namePrefix = "build-"
    static let lockName = ".in-use"
    /// Folders without a lock file (kept with `--keep-work`, or left behind by DictBridge 0.4.0
    /// and earlier) are removed once they have not changed for this long.
    static let unlockedLifetime: TimeInterval = 7 * 24 * 3600

    let url: URL
    private var lock: Int32

    init(in parent: URL = DictBridge.cacheDirectory) throws {
        let url = parent.appendingPathComponent(Self.namePrefix + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // O_EXLOCK creates and locks the file in one step, so a cleanup never finds it unlocked.
        let fd = open(url.appendingPathComponent(Self.lockName).path, O_RDWR | O_CREAT | O_EXLOCK | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            try? FileManager.default.removeItem(at: url)
            throw POSIXError(code)
        }
        self.url = url
        self.lock = fd
    }

    deinit {
        if lock >= 0 { close(lock) }
    }

    /// Deletes the folder, or with `keep` leaves it (without its lock file) for inspection.
    func finish(keep: Bool) {
        guard lock >= 0 else { return }
        if keep {
            unlink(url.appendingPathComponent(Self.lockName).path)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
        close(lock)
        lock = -1
    }

    /// Removes the build folders no conversion is using: locked ones whose conversion has
    /// ended, and ones without a lock file that are older than `unlockedLifetime`.
    /// - Returns: the number of folders removed.
    @discardableResult
    public static func removeLeftovers(in parent: URL = DictBridge.cacheDirectory, now: Date = Date()) -> Int {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.contentModificationDateKey],
                                                      options: [.skipsHiddenFiles]) else { return 0 }
        var removed = 0
        for dir in items where dir.lastPathComponent.hasPrefix(namePrefix) {
            let fd = open(dir.appendingPathComponent(lockName).path, O_RDONLY | O_EXLOCK | O_NONBLOCK | O_CLOEXEC)
            if fd >= 0 {
                // Nobody holds the lock: the conversion that made the folder ended without removing it.
                defer { close(fd) }
                if (try? fm.removeItem(at: dir)) != nil { removed += 1 }
                continue
            }
            guard errno == ENOENT else { continue }  // EWOULDBLOCK: a conversion is using it
            let modified = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
            if now.timeIntervalSince(modified) > unlockedLifetime, (try? fm.removeItem(at: dir)) != nil {
                removed += 1
            }
        }
        return removed
    }
}
