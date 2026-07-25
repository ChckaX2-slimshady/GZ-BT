import Foundation

/// Small formatting helpers. Utilities own no state and depend on nothing above them.
enum ByteFormat {
    static func string(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
