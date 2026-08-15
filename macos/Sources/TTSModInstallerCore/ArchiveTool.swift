import Foundation

public final class SevenZipTool {
    public let executableURL: URL
    private let extractionBaseURL: URL

    public init(executableURL: URL? = nil, bundle: Bundle = .main, extractionBaseURL: URL? = nil) throws {
        let candidates: [URL?] = [
            executableURL,
            ProcessInfo.processInfo.environment["TTS_MOD_INSTALLER_7ZZ"].map { URL(fileURLWithPath: $0) },
            bundle.resourceURL?.appendingPathComponent("tools/7zip/7zz")
        ]
        guard let selected = candidates.compactMap({ $0 }).first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }) else {
            throw InstallerError.dependency("发布包中缺少官方 7zz 组件，请重新下载完整 macOS 安装器。")
        }
        let hash = try FileHash.sha256(of: selected)
        let allowedHashes = [InstallerConstants.sevenZipOfficialSHA256, InstallerConstants.sevenZipSignedSHA256]
        guard allowedHashes.contains(hash) else {
            throw InstallerError.dependency("7zz 完整性校验失败，实际 SHA-256：\(hash)。")
        }
        self.executableURL = selected
        self.extractionBaseURL = extractionBaseURL ?? Self.extractionBaseURL()
    }

    public func inspect(archiveURL: URL, cancellationToken: CancellationToken? = nil) throws -> ArchiveInfo {
        let result = try ProcessRunner.run(
            executable: executableURL,
            arguments: ["l", "-slt", "-ba", "--", archiveURL.path],
            cancellationToken: cancellationToken
        )
        guard result.exitCode == 0 || result.exitCode == 1 else {
            throw InstallerError.archive("7‑Zip 无法读取压缩包（退出码 \(result.exitCode)）：\(archiveURL.lastPathComponent)")
        }
        let entries = try Self.parseTechnicalListing(result.output)
        let compressed = (try? archiveURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let info = ArchiveInfo(entries: entries, compressedBytes: compressed, hadWarnings: result.exitCode == 1)
        try validate(info: info, temporaryBase: extractionBaseURL)
        return info
    }

    public func extract(
        archiveURL: URL,
        cancellationToken: CancellationToken? = nil
    ) throws -> (root: URL, hadWarnings: Bool) {
        let info = try inspect(archiveURL: archiveURL, cancellationToken: cancellationToken)
        guard info.fileCount > 0 else { throw InstallerError.archive("压缩包中没有文件。") }
        let base = extractionBaseURL
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let destination = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        do {
            let result = try ProcessRunner.run(
                executable: executableURL,
                arguments: ["x", "-y", "-bso0", "-bsp0", "-bb0", "-o\(destination.path)", "--", archiveURL.path],
                cancellationToken: cancellationToken
            )
            guard result.exitCode == 0 || result.exitCode == 1 else {
                throw InstallerError.archive("7‑Zip 解压失败（退出码 \(result.exitCode)）：\(archiveURL.lastPathComponent)")
            }
            try FileTreeScanner.assertNoSymbolicLinks(root: destination, cancellationToken: cancellationToken)
            return (destination, info.hadWarnings || result.exitCode == 1)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    public static func parseTechnicalListing(_ output: String) throws -> [ArchiveEntry] {
        var records: [[String: String]] = []
        var record: [String: String] = [:]
        for line in output.components(separatedBy: .newlines) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !record.isEmpty { records.append(record); record = [:] }
                continue
            }
            guard let separator = line.range(of: " = ") else { continue }
            let key = String(line[..<separator.lowerBound])
            let value = String(line[separator.upperBound...])
            record[key] = value
        }
        if !record.isEmpty { records.append(record) }

        var entries: [ArchiveEntry] = []
        var paths: [String] = []
        for record in records {
            guard let path = record["Path"], !path.isEmpty else { continue }
            try PathSafety.validateArchivePath(path)
            let folder = record["Folder"] == "+" || record["Attributes"]?.hasPrefix("D") == true
            let link = record["Symbolic Link"] != nil || record["Hard Link"] != nil || record["Attributes"]?.contains("L") == true
            let size = Int64(record["Size"] ?? "0") ?? 0
            if size < 0 { throw InstallerError.unsafePackage("压缩包包含负数文件大小：\(path)") }
            entries.append(ArchiveEntry(path: path, size: size, isDirectory: folder, isLink: link))
            paths.append(path)
        }
        try PathSafety.assertNoPathCollisions(paths)
        if let link = entries.first(where: { $0.isLink }) {
            throw InstallerError.unsafePackage("压缩包包含符号链接或硬链接：\(link.path)")
        }
        return entries
    }

    private func validate(info: ArchiveInfo, temporaryBase: URL) throws {
        if info.fileCount > InstallerConstants.maximumArchiveFiles {
            throw InstallerError.archive("压缩包包含 \(info.fileCount) 个文件，超过 250000 个文件的安全上限。")
        }
        if info.uncompressedBytes > InstallerConstants.maximumUncompressedBytes {
            throw InstallerError.archive("压缩包声明的解压大小为 \(ByteCountText.string(info.uncompressedBytes))，超过 250 GB 的安全上限。")
        }
        if info.compressedBytes > 0 && info.uncompressedBytes > InstallerConstants.compressionRatioThresholdBytes {
            let ratio = Double(info.uncompressedBytes) / Double(info.compressedBytes)
            if ratio > InstallerConstants.maximumCompressionRatio {
                throw InstallerError.archive("压缩包压缩比异常（约 \(Int(ratio)):1），已停止以避免异常解压。")
            }
        }
        let available = DiskSpace.availableCapacity(near: temporaryBase)
        if let available, available < info.uncompressedBytes + InstallerConstants.freeSpaceReserve {
            throw InstallerError.insufficientSpace("临时磁盘空间不足；解压预计需要 \(ByteCountText.string(info.uncompressedBytes))，并预留 256 MB。")
        }
    }

    public static func extractionBaseURL(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/TTS Mod Installer/Extract", isDirectory: true)
    }
}

public enum FileTreeScanner {
    public static let knownModDirectories: Set<String> = [
        "images", "images raw", "models", "models raw", "workshop", "assetbundles",
        "audio", "textures", "pdf", "text", "translations"
    ]

    public static func assertNoSymbolicLinks(root: URL, cancellationToken: CancellationToken? = nil) throws {
        if try PathSafety.isSymbolicLink(root) {
            throw InstallerError.unsafePackage("图包根目录是符号链接：\(root.path)")
        }
        let keys: [URLResourceKey] = [.isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else {
            throw InstallerError.invalidInput("无法读取图包目录：\(root.path)")
        }
        while let value = enumerator.nextObject() as? URL {
            try cancellationToken?.throwIfCancelled()
            if try PathSafety.isSymbolicLink(value) {
                throw InstallerError.unsafePackage("图包包含符号链接：\(value.path)")
            }
        }
    }

    public static func resolveModsRoot(_ root: URL) throws -> URL {
        try assertNoSymbolicLinks(root: root)
        let fileManager = FileManager.default
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey])
        guard rootValues.isDirectory == true else {
            throw InstallerError.invalidInput("图包分析根路径不是文件夹。")
        }
        if root.lastPathComponent.caseInsensitiveCompare("Mods") == .orderedSame { return root }

        let direct = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        let directMods = direct.filter { $0.lastPathComponent.caseInsensitiveCompare("Mods") == .orderedSame }
        if directMods.count == 1 { return directMods[0] }
        if directMods.count > 1 {
            throw InstallerError.unsafePackage("图包中发现多个 Mods 候选，无法安全选择。")
        }

        var nested: [URL] = []
        for directory in direct {
            let children = (try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            )) ?? []
            nested.append(contentsOf: children.filter {
                $0.lastPathComponent.caseInsensitiveCompare("Mods") == .orderedSame &&
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            })
        }
        if nested.count == 1 { return nested[0] }
        if nested.count > 1 {
            throw InstallerError.unsafePackage("图包中发现多个嵌套 Mods 候选，无法安全选择。")
        }

        if direct.contains(where: { knownModDirectories.contains($0.lastPathComponent.lowercased()) }) {
            return root
        }
        throw InstallerError.invalidInput("没有找到可识别的 Mods 结构。请选择 Mods 文件夹，或包含 Mods 文件夹的图包。")
    }
}
