import Foundation
import Sparkle
import TTSModInstallerCore

@MainActor
private protocol ProxyFallbackUserDriverDelegate: AnyObject {
    func shouldSuppressUpdateError(_ error: NSError) -> Bool
    func shouldContinueUpdateInstall() -> Bool
}

@MainActor
private final class ProxyFallbackUserDriver: SPUStandardUserDriver {
    weak var fallbackDelegate: ProxyFallbackUserDriverDelegate?

    init(hostBundle: Bundle) {
        super.init(hostBundle: hostBundle, delegate: nil)
    }

    override func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        if fallbackDelegate?.shouldSuppressUpdateError(error as NSError) == true {
            acknowledgement()
        } else {
            super.showUpdaterError(error, acknowledgement: acknowledgement)
        }
    }

    override func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        if fallbackDelegate?.shouldContinueUpdateInstall() == true {
            reply(.install)
        } else {
            super.showUpdateFound(with: appcastItem, state: state, reply: reply)
        }
    }
}

@MainActor
final class UpdateCoordinator: NSObject, SPUUpdaterDelegate, ProxyFallbackUserDriverDelegate {
    enum CheckKind {
        case background
        case manual
    }

    var onStateChange: (() -> Void)?

    private static var directFeedURL: URL {
#if DEBUG
        if let testFeed = ProcessInfo.processInfo.environment["TTS_MOD_INSTALLER_TEST_FEED_URL"],
           let testURL = URL(string: testFeed) {
            return testURL
        }
#endif
        return URL(string: "https://nina-17.github.io/TTS-Mod-Installer/appcast.xml")!
    }

    private let userDriver: ProxyFallbackUserDriver
    private let logger = UpdateEventLogger()
    private var updater: SPUUpdater!
    private var canCheckObservation: NSKeyValueObservation?
    private var fallbackState = UpdateFallbackState()
    private var checkKind: CheckKind = .background
    private var retryPending = false
    private var started = false

    override init() {
        userDriver = ProxyFallbackUserDriver(hostBundle: .main)
        super.init()
        userDriver.fallbackDelegate = self
        updater = SPUUpdater(
            hostBundle: .main,
            applicationBundle: .main,
            userDriver: userDriver,
            delegate: self
        )
        canCheckObservation = updater.observe(\.canCheckForUpdates, options: [.initial, .new]) {
            [weak self] _, _ in
            DispatchQueue.main.async {
                self?.performPendingRetryIfPossible()
                self?.onStateChange?()
            }
        }
    }

    var canCheckForUpdates: Bool { started && updater.canCheckForUpdates }
    var isBusy: Bool { started && updater.sessionInProgress }
    var buttonTitle: String { isBusy ? "正在检查更新…" : "检查更新…" }

    func start() {
        guard !started else { return }
        do {
            try updater.start()
            started = true
            logger.write("Sparkle 已启动，当前版本 v\(InstallerConstants.version)。")
            beginCheck(.background)
        } catch {
            logger.write("Sparkle 启动失败：\(error.localizedDescription)", level: "ERROR")
        }
        onStateChange?()
    }

    func checkManually() {
        guard canCheckForUpdates else { return }
        beginCheck(.manual)
    }

    private func beginCheck(_ kind: CheckKind, isRetry: Bool = false) {
        guard started, updater.canCheckForUpdates else { return }
        checkKind = kind
        retryPending = false
        if !isRetry { fallbackState.beginFreshCheck() }
        logger.write(
            "开始\(kind == .manual ? "手动" : "后台")更新检查，通道：\(fallbackState.channel == .direct ? "GitHub" : "gh-proxy.com")。"
        )
        switch kind {
        case .background: updater.checkForUpdatesInBackground()
        case .manual: updater.checkForUpdates()
        }
        onStateChange?()
    }

    private func performPendingRetryIfPossible() {
        guard retryPending, started, updater.canCheckForUpdates else { return }
        beginCheck(checkKind, isRetry: true)
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        switch fallbackState.channel {
        case .direct:
            return Self.directFeedURL.absoluteString
        case .proxy:
            return UpdateProxyURL.proxyURL(for: Self.directFeedURL)?.absoluteString
        }
    }

    func updater(
        _ updater: SPUUpdater,
        willDownloadUpdate item: SUAppcastItem,
        with request: NSMutableURLRequest
    ) {
        fallbackState.recordDownloadStarted()
        guard fallbackState.channel == .proxy, let originalURL = request.url else { return }
        guard let proxyURL = UpdateProxyURL.proxyURL(for: originalURL) else {
            logger.write("拒绝代理非白名单更新 URL：\(originalURL.absoluteString)", level: "ERROR")
            return
        }
        request.url = proxyURL
        logger.write("更新归档切换至 gh-proxy.com：\(originalURL.lastPathComponent)")
    }

    func updater(
        _ updater: SPUUpdater,
        shouldProceedWithUpdate updateItem: SUAppcastItem,
        updateCheck: SPUUpdateCheck
    ) throws {
        guard fallbackState.channel == .proxy else { return }
        guard let fileURL = updateItem.fileURL, UpdateProxyURL.isAllowed(fileURL) else {
            let rejectedURL = updateItem.fileURL?.absoluteString ?? "<missing>"
            logger.write("拒绝代理非白名单更新 URL：\(rejectedURL)", level: "ERROR")
            throw NSError(
                domain: "io.github.nina-17.tts-mod-installer.update",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "更新归档地址不在受信任的 GitHub 白名单中。"]
            )
        }
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let nsError = error as NSError
        let isDownloadError = nsError.domain == SUSparkleErrorDomain && nsError.code == 2001
        if retryPending {
            return
        } else if fallbackState.requestProxyRetry(forDownloadError: isDownloadError) {
            retryPending = true
            logger.write("GitHub 直连失败，准备通过 gh-proxy.com 自动重试：\(nsError.localizedDescription)", level: "WARN")
        } else if nsError.code != 1001 {
            logger.write("更新周期失败：\(nsError.localizedDescription)", level: "WARN")
        }
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: Error?
    ) {
        if retryPending {
            DispatchQueue.main.async { [weak self] in
                self?.performPendingRetryIfPossible()
            }
        } else {
            if error == nil { logger.write("更新检查完成。") }
            fallbackState.beginFreshCheck()
        }
        onStateChange?()
    }

    func shouldSuppressUpdateError(_ error: NSError) -> Bool {
        let isDownloadError = error.domain == SUSparkleErrorDomain && error.code == 2001
        if !retryPending && fallbackState.requestProxyRetry(forDownloadError: isDownloadError) {
            retryPending = true
            logger.write("GitHub 直连失败，准备通过 gh-proxy.com 自动重试：\(error.localizedDescription)", level: "WARN")
        }
        return retryPending && isDownloadError
    }

    func shouldContinueUpdateInstall() -> Bool {
        let shouldContinue = fallbackState.consumeContinueInstall()
        if shouldContinue { logger.write("代理重试将继续用户已确认的更新安装。") }
        return shouldContinue
    }
}

private final class UpdateEventLogger {
    private let url: URL?
    private let lock = NSLock()

    init(fileManager: FileManager = .default) {
        let directory = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/TTS Mod Installer", isDirectory: true)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
            let logURL = directory.appendingPathComponent("update-\(formatter.string(from: Date())).log")
            try "TTS Mod Installer update log\nVersion: \(InstallerConstants.version)\n\n"
                .write(to: logURL, atomically: true, encoding: .utf8)
            url = logURL
        } catch {
            url = nil
        }
    }

    func write(_ message: String, level: String = "INFO") {
        guard let url,
              let data = "\(ISO8601DateFormatter().string(from: Date())) [\(level)] \(message)\n".data(using: .utf8) else { return }
        lock.lock()
        defer { lock.unlock() }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}
