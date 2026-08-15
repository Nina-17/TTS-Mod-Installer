import CryptoKit
import Foundation

public enum PathSafety {
    public static func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    public static func isSameOrNested(_ candidate: URL, under root: URL) -> Bool {
        let candidatePath = canonicalURL(candidate).path
        let rootPath = canonicalURL(root).path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    public static func assertSeparate(source: URL, target: URL) throws {
        if isSameOrNested(source, under: target) || isSameOrNested(target, under: source) {
            throw InstallerError.unsafePackage("图包来源和安装目标相同或互相嵌套，已停止以避免递归复制。")
        }
    }

    public static func normalizedCollisionKey(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "/")
            .precomposedStringWithCanonicalMapping
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    public static func validateArchivePath(_ rawPath: String) throws {
        let path = rawPath.replacingOccurrences(of: "\\", with: "/")
        if path.isEmpty || path.hasPrefix("/") || path.hasPrefix("//") {
            throw InstallerError.unsafePackage("压缩包包含绝对或空路径：\(rawPath)")
        }
        if path.range(of: #"^[A-Za-z]:"#, options: .regularExpression) != nil {
            throw InstallerError.unsafePackage("压缩包包含 Windows 绝对路径：\(rawPath)")
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        if components.contains(where: { $0 == ".." }) {
            throw InstallerError.unsafePackage("压缩包包含越级路径：\(rawPath)")
        }
    }

    public static func assertNoPathCollisions(_ paths: [String]) throws {
        var seen: [String: String] = [:]
        for path in paths {
            let key = normalizedCollisionKey(path)
            if let previous = seen[key], !previous.utf8.elementsEqual(path.utf8) {
                throw InstallerError.unsafePackage("图包包含大小写或 Unicode 归一化冲突：\(previous) / \(path)")
            }
            seen[key] = path
        }
    }

    public static func isSymbolicLink(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        return values.isSymbolicLink == true
    }

    public static func assertNoSymbolicLinkComponents(from root: URL, to target: URL) throws {
        let rootURL = root.standardizedFileURL
        let targetURL = target.standardizedFileURL
        guard targetURL.path == rootURL.path || targetURL.path.hasPrefix(rootURL.path + "/") else {
            throw InstallerError.unsafePackage("目标路径逃逸出 Mods 目录：\(target.path)")
        }
        var cursor = rootURL
        if FileManager.default.fileExists(atPath: cursor.path), try isSymbolicLink(cursor) {
            throw InstallerError.unsafePackage("Mods 目标目录是符号链接：\(cursor.path)")
        }
        let relative = String(targetURL.path.dropFirst(rootURL.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        for component in relative.split(separator: "/") {
            cursor.appendPathComponent(String(component))
            if FileManager.default.fileExists(atPath: cursor.path), try isSymbolicLink(cursor) {
                throw InstallerError.unsafePackage("目标中包含符号链接，拒绝跟随：\(cursor.path)")
            }
        }
    }
}

public enum FileHash {
    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            guard let data = try handle.read(upToCount: 1_048_576), !data.isEmpty else { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public enum DiskSpace {
    public static func availableCapacity(near url: URL, fileManager: FileManager = .default) -> Int64? {
        var cursor = url.standardizedFileURL
        while !fileManager.fileExists(atPath: cursor.path) {
            let parent = cursor.deletingLastPathComponent()
            if parent.path == cursor.path { return nil }
            cursor = parent
        }
        let capacity = try? cursor.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
        return capacity.flatMap { $0 > 0 ? $0 : nil }
    }
}

public final class InstallerLogger {
    public let logURL: URL
    public let copyLogURL: URL
    private let lock = NSLock()

    public init(fileManager: FileManager = .default, now: Date = Date(), directory: URL? = nil) throws {
        let home = fileManager.homeDirectoryForCurrentUser
        let directory = directory ?? home.appendingPathComponent("Library/Logs/TTS Mod Installer", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let stamp = formatter.string(from: now)
        logURL = directory.appendingPathComponent("install-\(stamp).log")
        copyLogURL = directory.appendingPathComponent("copy-\(stamp).log")
        try "TTS Mod Installer macOS\nVersion: \(InstallerConstants.version)\nStarted: \(ISO8601DateFormatter().string(from: now))\n\n"
            .write(to: logURL, atomically: true, encoding: .utf8)
        try "TTS Mod Installer copy log\n\n".write(to: copyLogURL, atomically: true, encoding: .utf8)
    }

    public func write(_ level: String = "INFO", _ message: String) {
        append("\(ISO8601DateFormatter().string(from: Date())) [\(level)] \(message)\n", to: logURL)
    }

    public func copy(_ message: String) {
        append("\(message)\n", to: copyLogURL)
    }

    private func append(_ text: String, to url: URL) {
        lock.lock()
        defer { lock.unlock() }
        guard let data = text.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }

    public static func cleanStaleData(fileManager: FileManager = .default, now: Date = Date()) {
        let home = fileManager.homeDirectoryForCurrentUser
        clean(directory: home.appendingPathComponent("Library/Logs/TTS Mod Installer"), olderThan: now.addingTimeInterval(-30 * 86_400), fileManager: fileManager)
        clean(directory: home.appendingPathComponent("Library/Caches/TTS Mod Installer/Extract"), olderThan: now.addingTimeInterval(-86_400), fileManager: fileManager)
    }

    private static func clean(directory: URL, olderThan cutoff: Date, fileManager: FileManager) {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for entry in entries {
            let date = try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            if let date, date < cutoff { try? fileManager.removeItem(at: entry) }
        }
    }
}
