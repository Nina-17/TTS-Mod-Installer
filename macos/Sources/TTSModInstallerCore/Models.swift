import Foundation

public enum InstallerConstants {
    public static let version = "0.6.1"
    public static let bundleIdentifier = "io.github.nina-17.tts-mod-installer"
    public static let ttsBundleIdentifier = "com.berserk-games.tabletop-simulator"
    public static let sevenZipVersion = "26.02"
    public static let sevenZipOfficialSHA256 = "9c56cf3379a0d8544e9244958b96fdc7c17f9ce70f5a160eb2b41f5f3df96d8c"
    public static let sevenZipSignedSHA256 = "29034e8f067c2f939f4bcac26fd552da2c72ffa2c7e572e4b41f3131e5a86208"
    public static let maximumArchiveFiles = 250_000
    public static let maximumUncompressedBytes: Int64 = 250 * 1_024 * 1_024 * 1_024
    public static let compressionRatioThresholdBytes: Int64 = 1_024 * 1_024 * 1_024
    public static let maximumCompressionRatio = 1_000.0
    public static let freeSpaceReserve: Int64 = 256 * 1_024 * 1_024
}

public enum ModLocationMode: String, Codable, CaseIterable {
    case userData
    case gameData

    public var displayName: String {
        switch self {
        case .userData: return "用户目录"
        case .gameData: return "Game Data"
        }
    }
}

public struct ConfigResolution: Equatable {
    public let mode: ModLocationMode?
    public let isAmbiguous: Bool
    public let valueNames: [String]

    public init(mode: ModLocationMode?, isAmbiguous: Bool, valueNames: [String]) {
        self.mode = mode
        self.isAmbiguous = isAmbiguous
        self.valueNames = valueNames
    }
}

public struct DestinationResolution {
    public let config: ConfigResolution
    public let userDataURL: URL
    public let gameDataURL: URL?
    public let steamAppURL: URL?

    public init(config: ConfigResolution, userDataURL: URL, gameDataURL: URL?, steamAppURL: URL?) {
        self.config = config
        self.userDataURL = userDataURL
        self.gameDataURL = gameDataURL
        self.steamAppURL = steamAppURL
    }

    public func destination(for requestedMode: ModLocationMode?) -> URL? {
        switch requestedMode ?? config.mode {
        case .userData: return userDataURL
        case .gameData: return gameDataURL
        case nil: return nil
        }
    }
}

public struct ArchiveEntry: Equatable {
    public let path: String
    public let size: Int64
    public let isDirectory: Bool
    public let isLink: Bool

    public init(path: String, size: Int64, isDirectory: Bool, isLink: Bool) {
        self.path = path
        self.size = size
        self.isDirectory = isDirectory
        self.isLink = isLink
    }
}

public struct ArchiveInfo {
    public let entries: [ArchiveEntry]
    public let compressedBytes: Int64
    public let hadWarnings: Bool

    public init(entries: [ArchiveEntry], compressedBytes: Int64, hadWarnings: Bool) {
        self.entries = entries
        self.compressedBytes = compressedBytes
        self.hadWarnings = hadWarnings
    }

    public var fileCount: Int { entries.filter { !$0.isDirectory }.count }
    public var uncompressedBytes: Int64 { entries.reduce(0) { $0 + ($1.isDirectory ? 0 : $1.size) } }
}

public struct CopyItemPlan {
    public let sourceURL: URL
    public let relativePath: String
    public let size: Int64

    public init(sourceURL: URL, relativePath: String, size: Int64) {
        self.sourceURL = sourceURL
        self.relativePath = relativePath
        self.size = size
    }
}

public struct CopySummary {
    public let items: [CopyItemPlan]
    public let totalBytes: Int64
    public let conflictCount: Int
    public let overwriteBytes: Int64
    public let requiredGrowthBytes: Int64
    public let availableBytes: Int64?

    public init(
        items: [CopyItemPlan],
        totalBytes: Int64,
        conflictCount: Int,
        overwriteBytes: Int64,
        requiredGrowthBytes: Int64,
        availableBytes: Int64?
    ) {
        self.items = items
        self.totalBytes = totalBytes
        self.conflictCount = conflictCount
        self.overwriteBytes = overwriteBytes
        self.requiredGrowthBytes = requiredGrowthBytes
        self.availableBytes = availableBytes
    }
}

public struct PackageFailure {
    public let packageURL: URL
    public let message: String

    public init(packageURL: URL, message: String) {
        self.packageURL = packageURL
        self.message = message
    }
}

public struct PackageResult {
    public let packageURL: URL
    public let succeeded: Bool
    public let hadWarnings: Bool
    public let message: String
    public let logURL: URL?

    public init(packageURL: URL, succeeded: Bool, hadWarnings: Bool, message: String, logURL: URL?) {
        self.packageURL = packageURL
        self.succeeded = succeeded
        self.hadWarnings = hadWarnings
        self.message = message
        self.logURL = logURL
    }
}

public enum InstallerError: Error, LocalizedError, Equatable {
    case cancelled
    case invalidInput(String)
    case destination(String)
    case unsafePackage(String)
    case archive(String)
    case insufficientSpace(String)
    case copy(String)
    case dependency(String)

    public var errorDescription: String? {
        switch self {
        case .cancelled: return "操作已取消。"
        case .invalidInput(let message), .destination(let message), .unsafePackage(let message),
             .archive(let message), .insufficientSpace(let message), .copy(let message),
             .dependency(let message):
            return message
        }
    }
}

public final class CancellationToken {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    public func throwIfCancelled() throws {
        if isCancelled { throw InstallerError.cancelled }
    }
}

public enum ByteCountText {
    public static func string(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: bytes)
    }
}
