import Darwin
import Foundation

/// Runs a command, streaming its combined stdout/stderr line by line.
final class ProcessRunner: @unchecked Sendable {
    private let process = Process()
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    /// Stops the command and everything it started. `build_dict.sh` runs perl and Apple's
    /// helpers as child processes, which would otherwise keep running after the shell exits.
    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        guard process.isRunning else { return }
        // List the descendants first: once the shell is gone they are re-parented to launchd.
        let descendants = Self.descendants(of: process.processIdentifier)
        process.terminate()
        for pid in descendants.reversed() { kill(pid, SIGTERM) }
    }

    /// All processes started (directly or indirectly) by `root`.
    static func descendants(of root: pid_t) -> [pid_t] {
        var result: [pid_t] = []
        var queue: [pid_t] = [root]
        while !queue.isEmpty {
            let parent = queue.removeFirst()
            var buffer = [pid_t](repeating: 0, count: 512)
            let count = buffer.withUnsafeMutableBytes { raw -> Int32 in
                proc_listchildpids(parent, raw.baseAddress, Int32(raw.count))
            }
            guard count > 0 else { continue }
            let children = buffer.prefix(min(Int(count), buffer.count)).filter { $0 > 0 && $0 != root }
            for child in children where !result.contains(child) {
                result.append(child)
                queue.append(child)
            }
        }
        return result
    }

    /// Accumulates output and splits it into lines (accessed on one serial queue).
    private final class LineSplitter: @unchecked Sendable {
        var pending = Data()
        let onLine: (String) -> Void
        init(onLine: @escaping (String) -> Void) { self.onLine = onLine }

        func feed(_ chunk: Data) {
            pending.append(chunk)
            while let nl = pending.firstIndex(of: 0x0A) {
                let line = pending.subdata(in: pending.startIndex..<nl)
                pending.removeSubrange(pending.startIndex...nl)
                onLine(String(decoding: line, as: UTF8.self))
            }
        }

        func finish() {
            if !pending.isEmpty {
                onLine(String(decoding: pending, as: UTF8.self))
                pending.removeAll()
            }
        }
    }

    /// - Returns: the exit status.
    func run(executable: URL, arguments: [String], workingDirectory: URL,
             environment: [String: String], onLine: @escaping (String) -> Void) throws -> Int32 {
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        let splitter = LineSplitter(onLine: onLine)
        let queue = DispatchQueue(label: "org.dictbridge.process-output")
        let done = DispatchSemaphore(value: 0)

        pipe.fileHandleForReading.readabilityHandler = { h in
            let chunk = h.availableData
            queue.sync {
                if chunk.isEmpty {
                    h.readabilityHandler = nil
                    splitter.finish()
                    done.signal()
                } else {
                    splitter.feed(chunk)
                }
            }
        }

        if isCancelled { throw CancellationError() }
        try process.run()
        process.waitUntilExit()
        _ = done.wait(timeout: .now() + 10)
        if isCancelled { throw CancellationError() }
        return process.terminationStatus
    }
}
