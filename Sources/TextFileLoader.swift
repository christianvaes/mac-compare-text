import Foundation

/// Reads a text file for comparison: refuses folders, files over the size
/// limit and binary files, detects the encoding, and normalizes line
/// endings to `\n` (the comparison and the line numbers count `\n` only).
enum TextFileLoader {
    enum Failure: Error, Equatable {
        case unreadable
        case tooLarge
        case notText
    }

    static let maxBytes = 50 * 1024 * 1024
    /// Above this share of control characters in the first block, a file
    /// is treated as binary.
    private static let maxControlShare = 0.1
    private static let sniffBytes = 8192

    static func load(_ url: URL) -> Result<String, Failure> {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true else { return .failure(.unreadable) }
        if let size = values.fileSize, size > maxBytes { return .failure(.tooLarge) }
        guard let data = try? Data(contentsOf: url) else { return .failure(.unreadable) }
        guard let text = decode(data) else { return .failure(.notText) }
        return .success(normalizeLineEndings(text))
    }

    static func decode(_ data: Data) -> String? {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(data: data.dropFirst(3), encoding: .utf8)
        }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        let head = data.prefix(sniffBytes)
        if head.contains(0) { return nil }
        let control = head.filter { $0 < 0x20 && $0 != 0x09 && $0 != 0x0A && $0 != 0x0C && $0 != 0x0D }.count
        if !head.isEmpty, Double(control) / Double(head.count) > maxControlShare { return nil }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .windowsCP1252)
            ?? String(data: data, encoding: .isoLatin1)
    }

    static func normalizeLineEndings(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }
}
