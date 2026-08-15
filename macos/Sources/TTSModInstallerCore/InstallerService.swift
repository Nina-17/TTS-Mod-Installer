import Foundation

public struct PreparedPackage {
    public let packageURL: URL
    public let sourceRoot: URL
    public let temporaryRoot: URL?
    public let summary: CopySummary
    public let hadWarnings: Bool

    public init(packageURL: URL, sourceRoot: URL, temporaryRoot: URL?, summary: CopySummary, hadWarnings: Bool) {
        self.packageURL = packageURL
        self.sourceRoot = sourceRoot
        self.temporaryRoot = temporaryRoot
        self.summary = summary
        self.hadWarnings = hadWarnings
    }
}

public final class PreparedBatch {
    public let targetURL: URL
    public let packages: [PreparedPackage]
    public let failures: [PackageFailure]
    public let logger: InstallerLogger
    public let fileCount: Int
    public let totalBytes: Int64
    public let conflictCount: Int
    public let overwriteBytes: Int64
    public let requiredGrowthBytes: Int64
    public let peakRequiredBytes: Int64
    public let availableBytes: Int64?
    private let fileManager: FileManager
    private let cleanupLock = NSLock()
    private var cleaned = false

    public init(
        targetURL: URL,
        packages: [PreparedPackage],
        failures: [PackageFailure],
        logger: InstallerLogger,
        fileManager: FileManager = .default
    ) {
        self.targetURL = targetURL
        self.packages = packages
        self.failures = failures
        self.logger = logger
        self.fileManager = fileManager

        fileCount = packages.reduce(0) { $0 + $1.summary.items.count }
        totalBytes = packages.reduce(0) { $0 + $1.summary.totalBytes }
        availableBytes = DiskSpace.availableCapacity(near: targetURL, fileManager: fileManager)

        var knownPaths = Set<String>()
        var existingPaths = Set<String>()
        var initialSizes: [String: Int64] = [:]
        var currentSizes: [String: Int64] = [:]
        var conflicts = 0
        var overwrites: Int64 = 0
        var currentNetGrowth: Int64 = 0
        var peakRequired: Int64 = 0

        for package in packages {
            for item in package.summary.items {
                let key = PathSafety.normalizedCollisionKey(item.relativePath)
                if knownPaths.insert(key).inserted {
                    let target = targetURL.appendingPathComponent(item.relativePath)
                    var isDirectory: ObjCBool = false
                    if fileManager.fileExists(atPath: target.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                        let size = (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                        existingPaths.insert(key)
                        initialSizes[key] = size
                        currentSizes[key] = size
                    } else {
                        initialSizes[key] = 0
                        currentSizes[key] = 0
                    }
                }

                let oldSize = currentSizes[key] ?? 0
                peakRequired = max(peakRequired, currentNetGrowth + item.size)
                if existingPaths.contains(key) {
                    conflicts += 1
                    overwrites += item.size
                } else {
                    existingPaths.insert(key)
                }
                currentNetGrowth += item.size - oldSize
                currentSizes[key] = item.size
            }
        }

        conflictCount = conflicts
        overwriteBytes = overwrites
        requiredGrowthBytes = currentSizes.reduce(0) { partial, pair in
            partial + max(0, pair.value - (initialSizes[pair.key] ?? 0))
        }
        peakRequiredBytes = max(0, peakRequired)
    }

    deinit { cleanup() }

    public func cleanup() {
        cleanupLock.lock()
        defer { cleanupLock.unlock() }
        guard !cleaned else { return }
        cleaned = true
        for package in packages {
            if let temporaryRoot = package.temporaryRoot {
                try? fileManager.removeItem(at: temporaryRoot)
            }
        }
    }
}

public struct InstallProgress {
    public let packageIndex: Int
    public let packageCount: Int
    public let fileIndex: Int
    public let fileCount: Int
    public let completedBytes: Int64
    public let totalBytes: Int64
    public let currentURL: URL

    public init(
        packageIndex: Int,
        packageCount: Int,
        fileIndex: Int,
        fileCount: Int,
        completedBytes: Int64,
        totalBytes: Int64,
        currentURL: URL
    ) {
        self.packageIndex = packageIndex
        self.packageCount = packageCount
        self.fileIndex = fileIndex
        self.fileCount = fileCount
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
        self.currentURL = currentURL
    }
}

public final class InstallerService {
    private let fileManager: FileManager
    private let sevenZipURL: URL?
    private let logDirectory: URL?
    private let extractionBaseURL: URL?

    public init(
        fileManager: FileManager = .default,
        sevenZipURL: URL? = nil,
        logDirectory: URL? = nil,
        extractionBaseURL: URL? = nil
    ) {
        self.fileManager = fileManager
        self.sevenZipURL = sevenZipURL
        self.logDirectory = logDirectory
        self.extractionBaseURL = extractionBaseURL
    }

    public func verifyWritableTarget(_ target: URL) throws {
        if fileManager.fileExists(atPath: target.path), try PathSafety.isSymbolicLink(target) {
            throw InstallerError.destination("Mods 目标目录是符号链接，已拒绝写入：\(target.path)")
        }
        do {
            try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
            let sentinel = target.appendingPathComponent(".ttsmodinstaller-write-test-\(UUID().uuidString)")
            try Data().write(to: sentinel, options: .withoutOverwriting)
            try fileManager.removeItem(at: sentinel)
        } catch {
            throw InstallerError.destination("目标目录不可写：\(target.path)。如果使用 Game Data，请在 TTS 中切回用户目录，或修复 Steam 库权限。")
        }
    }

    public func prepare(
        packageURLs: [URL],
        targetURL: URL,
        cancellationToken: CancellationToken? = nil
    ) throws -> PreparedBatch {
        let logger = try InstallerLogger(fileManager: fileManager, directory: logDirectory)
        logger.write("INFO", "目标：\(targetURL.path)")
        var prepared: [PreparedPackage] = []
        var failures: [PackageFailure] = []
        let copyEngine = CopyEngine(fileManager: fileManager)

        for packageURL in packageURLs {
            try cancellationToken?.throwIfCancelled()
            var temporaryRoot: URL?
            do {
                let source: URL
                let hadWarnings: Bool
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: packageURL.path, isDirectory: &isDirectory) else {
                    throw InstallerError.invalidInput("路径不存在：\(packageURL.path)")
                }
                if isDirectory.boolValue {
                    source = packageURL
                    hadWarnings = false
                } else {
                    let supported = ["zip", "ttsmod", "7z", "rar"]
                    guard supported.contains(packageURL.pathExtension.lowercased()) else {
                        throw InstallerError.invalidInput("不支持的文件类型：.\(packageURL.pathExtension)")
                    }
                    let tool = try SevenZipTool(executableURL: sevenZipURL, extractionBaseURL: extractionBaseURL)
                    let extracted = try tool.extract(archiveURL: packageURL, cancellationToken: cancellationToken)
                    source = extracted.root
                    temporaryRoot = extracted.root
                    hadWarnings = extracted.hadWarnings
                }
                let modsRoot = try FileTreeScanner.resolveModsRoot(source)
                let summary = try copyEngine.scan(
                    sourceRoot: modsRoot,
                    targetRoot: targetURL,
                    cancellationToken: cancellationToken
                )
                prepared.append(PreparedPackage(
                    packageURL: packageURL,
                    sourceRoot: modsRoot,
                    temporaryRoot: temporaryRoot,
                    summary: summary,
                    hadWarnings: hadWarnings
                ))
                logger.write("INFO", "预检完成：\(packageURL.path)，\(summary.items.count) 个文件，\(summary.totalBytes) bytes")
            } catch {
                if error as? InstallerError == .cancelled { throw error }
                if let temporaryRoot { try? fileManager.removeItem(at: temporaryRoot) }
                let message = error.localizedDescription
                failures.append(PackageFailure(packageURL: packageURL, message: message))
                logger.write("ERROR", "预检失败：\(packageURL.path)：\(message)")
            }
        }
        let batch = PreparedBatch(
            targetURL: targetURL,
            packages: prepared,
            failures: failures,
            logger: logger,
            fileManager: fileManager
        )
        if let available = batch.availableBytes, available < batch.peakRequiredBytes {
            batch.cleanup()
            throw InstallerError.insufficientSpace("目标磁盘空间不足；原子覆盖过程预计至少需要 \(ByteCountText.string(batch.peakRequiredBytes)) 可用空间。")
        }
        return batch
    }

    public func execute(
        batch: PreparedBatch,
        cancellationToken: CancellationToken? = nil,
        progress: ((InstallProgress) -> Void)? = nil
    ) -> [PackageResult] {
        var results = batch.failures.map {
            PackageResult(packageURL: $0.packageURL, succeeded: false, hadWarnings: false, message: $0.message, logURL: batch.logger.logURL)
        }
        let copyEngine = CopyEngine(fileManager: fileManager)
        for (packageIndex, package) in batch.packages.enumerated() {
            do {
                try cancellationToken?.throwIfCancelled()
                try copyEngine.copy(
                    summary: package.summary,
                    targetRoot: batch.targetURL,
                    logger: batch.logger,
                    cancellationToken: cancellationToken
                ) { fileIndex, fileCount, completedBytes, totalBytes, url in
                    progress?(InstallProgress(
                        packageIndex: packageIndex + 1,
                        packageCount: batch.packages.count,
                        fileIndex: fileIndex,
                        fileCount: fileCount,
                        completedBytes: completedBytes,
                        totalBytes: totalBytes,
                        currentURL: url
                    ))
                }
                let message = package.hadWarnings ? "安装完成，但压缩包处理有警告。" : "安装完成。"
                batch.logger.write(package.hadWarnings ? "WARN" : "OK", "\(package.packageURL.path)：\(message)")
                results.append(PackageResult(
                    packageURL: package.packageURL,
                    succeeded: true,
                    hadWarnings: package.hadWarnings,
                    message: message,
                    logURL: batch.logger.logURL
                ))
            } catch {
                batch.logger.write("ERROR", "\(package.packageURL.path)：\(error.localizedDescription)")
                results.append(PackageResult(
                    packageURL: package.packageURL,
                    succeeded: false,
                    hadWarnings: false,
                    message: error.localizedDescription,
                    logURL: batch.logger.logURL
                ))
                if error as? InstallerError == .cancelled { break }
            }
        }
        batch.cleanup()
        return results
    }
}
