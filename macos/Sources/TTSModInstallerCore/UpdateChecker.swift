import Foundation

public enum SemanticVersion: Comparable, Equatable {
    case value(Int, Int, Int)

    public init?(_ text: String) {
        let clean = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let parts = clean.split(separator: ".")
        guard parts.count == 3,
              let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2]) else { return nil }
        self = .value(major, minor, patch)
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        switch (lhs, rhs) {
        case let (.value(lMajor, lMinor, lPatch), .value(rMajor, rMinor, rPatch)):
            return (lMajor, lMinor, lPatch) < (rMajor, rMinor, rPatch)
        }
    }
}

public enum UpdateChannel: Equatable {
    case direct
    case proxy
}

public enum UpdateProxyURL {
    public static let prefix = "https://gh-proxy.com/"

    public static func isAllowed(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              url.fragment == nil,
              let host = url.host?.lowercased() else { return false }
        return host == "github.com" ||
            host.hasSuffix(".github.com") ||
            host == "nina-17.github.io"
    }

    public static func proxyURL(for url: URL) -> URL? {
        guard isAllowed(url) else { return nil }
        return URL(string: prefix + url.absoluteString)
    }
}

public struct UpdateFallbackState: Equatable {
    public private(set) var channel: UpdateChannel = .direct
    public private(set) var retryUsed = false
    public private(set) var shouldContinueInstall = false

    public init() {}

    public mutating func beginFreshCheck() {
        channel = .direct
        retryUsed = false
        shouldContinueInstall = false
    }

    public mutating func recordDownloadStarted() {
        if channel == .direct { shouldContinueInstall = true }
    }

    @discardableResult
    public mutating func requestProxyRetry(forDownloadError isDownloadError: Bool) -> Bool {
        guard isDownloadError, channel == .direct, !retryUsed else { return false }
        channel = .proxy
        retryUsed = true
        return true
    }

    public mutating func consumeContinueInstall() -> Bool {
        guard channel == .proxy, shouldContinueInstall else { return false }
        shouldContinueInstall = false
        return true
    }
}
