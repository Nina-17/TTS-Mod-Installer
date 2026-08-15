import Foundation

public final class CopyEngine {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func scan(
        sourceRoot: URL,
        targetRoot: URL,
        cancellationToken: CancellationToken? = nil
    ) throws -> CopySummary {
        try PathSafety.assertSeparate(source: sourceRoot, target: targetRoot)
        try FileTreeScanner.assertNoSymbolicLinks(root: sourceRoot, cancellationToken: cancellationToken)
        if fileManager.fileExists(atPath: targetRoot.path), try PathSafety.isSymbolicLink(targetRoot) {
            throw InstallerError.unsafePackage("Mods 目标目录是符号链接：\(targetRoot.path)")
        }

        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let enumerator = fileManager.enumerator(at: sourceRoot, includingPropertiesForKeys: keys, options: []) else {
            throw InstallerError.invalidInput("无法扫描图包目录：\(sourceRoot.path)")
        }
        var items: [CopyItemPlan] = []
        var paths: [String] = []
        var totalBytes: Int64 = 0
        var conflictCount = 0
        var overwriteBytes: Int64 = 0
        var requiredGrowthBytes: Int64 = 0

        let sourcePrefix = sourceRoot.standardizedFileURL.path + "/"
        while let url = enumerator.nextObject() as? URL {
            try cancellationToken?.throwIfCancelled()
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true {
                throw InstallerError.unsafePackage("图包包含符号链接：\(url.path)")
            }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true else {
                throw InstallerError.unsafePackage("图包包含不支持的特殊文件：\(url.path)")
            }
            guard url.standardizedFileURL.path.hasPrefix(sourcePrefix) else {
                throw InstallerError.unsafePackage("图包文件逃逸出来源目录：\(url.path)")
            }
            let relative = String(url.standardizedFileURL.path.dropFirst(sourcePrefix.count))
            paths.append(relative)
            let size = Int64(values.fileSize ?? 0)
            items.append(CopyItemPlan(sourceURL: url, relativePath: relative, size: size))
            totalBytes += size
            if items.count > InstallerConstants.maximumArchiveFiles {
                throw InstallerError.invalidInput("图包包含超过 250000 个文件，已停止扫描。")
            }
            if totalBytes > InstallerConstants.maximumUncompressedBytes {
                throw InstallerError.invalidInput("图包内容超过 250 GB 的安全上限，已停止扫描。")
            }

            let target = targetRoot.appendingPathComponent(relative)
            try PathSafety.assertNoSymbolicLinkComponents(from: targetRoot, to: target)
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: target.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue {
                    throw InstallerError.copy("目标中同名路径是文件夹，无法用文件覆盖：\(target.path)")
                }
                conflictCount += 1
                overwriteBytes += size
                let existing = (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                requiredGrowthBytes += max(0, size - existing)
            } else {
                requiredGrowthBytes += size
            }
        }
        guard !items.isEmpty else { throw InstallerError.invalidInput("识别出的 Mods 目录中没有任何文件。") }
        try PathSafety.assertNoPathCollisions(paths)
        let available = DiskSpace.availableCapacity(near: targetRoot, fileManager: fileManager)
        if let available, available < requiredGrowthBytes {
            throw InstallerError.insufficientSpace("目标磁盘空间不足；预计至少需要新增 \(ByteCountText.string(requiredGrowthBytes))。")
        }
        return CopySummary(
            items: items,
            totalBytes: totalBytes,
            conflictCount: conflictCount,
            overwriteBytes: overwriteBytes,
            requiredGrowthBytes: requiredGrowthBytes,
            availableBytes: available
        )
    }

    public func copy(
        summary: CopySummary,
        targetRoot: URL,
        logger: InstallerLogger,
        cancellationToken: CancellationToken? = nil,
        progress: ((Int, Int, Int64, Int64, URL) -> Void)? = nil
    ) throws {
        try fileManager.createDirectory(at: targetRoot, withIntermediateDirectories: true)
        var completedBytes: Int64 = 0
        for (index, item) in summary.items.enumerated() {
            try cancellationToken?.throwIfCancelled()
            let target = targetRoot.appendingPathComponent(item.relativePath)
            try PathSafety.assertNoSymbolicLinkComponents(from: targetRoot, to: target)
            let parent = target.deletingLastPathComponent()
            try createDirectoriesSafely(from: targetRoot, to: parent)
            let temporary = parent.appendingPathComponent(".ttsmodinstaller-\(UUID().uuidString).tmp")
            do {
                try fileManager.copyItem(at: item.sourceURL, to: temporary)
                if fileManager.fileExists(atPath: target.path) {
                    _ = try fileManager.replaceItemAt(target, withItemAt: temporary, backupItemName: nil, options: [])
                } else {
                    try fileManager.moveItem(at: temporary, to: target)
                }
                completedBytes += item.size
                logger.copy("WRITE \(item.relativePath) \(item.size) bytes")
                progress?(index + 1, summary.items.count, completedBytes, summary.totalBytes, target)
            } catch {
                try? fileManager.removeItem(at: temporary)
                throw InstallerError.copy("复制失败：\(item.relativePath)：\(error.localizedDescription)。部分文件可能已经写入，可修复问题后重新安装同一图包。")
            }
        }
    }

    private func createDirectoriesSafely(from root: URL, to directory: URL) throws {
        guard directory.path == root.path || directory.path.hasPrefix(root.path + "/") else {
            throw InstallerError.unsafePackage("目标目录逃逸出 Mods：\(directory.path)")
        }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let relative = String(directory.path.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var cursor = root
        for component in relative.split(separator: "/") {
            cursor.appendPathComponent(String(component), isDirectory: true)
            if fileManager.fileExists(atPath: cursor.path) {
                if try PathSafety.isSymbolicLink(cursor) {
                    throw InstallerError.unsafePackage("目标中包含符号链接，拒绝跟随：\(cursor.path)")
                }
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: cursor.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                    throw InstallerError.copy("目标中同名路径不是文件夹：\(cursor.path)")
                }
            } else {
                try fileManager.createDirectory(at: cursor, withIntermediateDirectories: false)
            }
        }
    }
}
