import Foundation

/// Errors thrown while reading MDict files.
public enum MDictError: Error, LocalizedError, Equatable {
    /// The file is not an MDict file or is truncated.
    case invalidFile(String)
    /// The file uses a feature this reader does not support.
    case unsupported(String)
    /// A checksum or structural consistency check failed.
    case corrupt(String)

    public var errorDescription: String? {
        switch self {
        case .invalidFile(let m): return "Not a valid MDict file: \(m)"
        case .unsupported(let m): return "Unsupported MDict feature: \(m)"
        case .corrupt(let m): return "Damaged MDict file: \(m)"
        }
    }
}
