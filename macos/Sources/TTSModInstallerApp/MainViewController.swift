import AppKit
import TTSModInstallerCore
import UniformTypeIdentifiers

final class MainViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let pathResolver = TTSPathResolver()
    private let updateCoordinator: UpdateCoordinator
    private var destinationResolution: DestinationResolution!
    private var packageURLs: [URL] = []
    private var lastLogURL: URL?
    private var cancellationToken: CancellationToken?

    private let dropZone = DropZoneView()
    private let tableView = NSTableView()
    private let targetPopup = NSPopUpButton()
    private let targetPathLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "准备好接收图包啦 ✨")
    private let progressIndicator = NSProgressIndicator()
    private let installButton = NSButton(title: "开始安装 ✨", target: nil, action: nil)
    private let cancelButton = NSButton(title: "取消", target: nil, action: nil)
    private let openLogButton = NSButton(title: "查看日志", target: nil, action: nil)
    private let openModsButton = NSButton(title: "打开 Mods", target: nil, action: nil)
    private let updateButton = NSButton(title: "发现新版本", target: nil, action: nil)

    init(updateCoordinator: UpdateCoordinator) {
        self.updateCoordinator = updateCoordinator
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 680))
        configureUI()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        dropZone.onURLs = { [weak self] urls in self?.addPackageURLs(urls) }
        updateCoordinator.onStateChange = { [weak self] in self?.updateControls() }
        refreshDestination()
        updateControls()
    }

    func addPackageURLs(_ urls: [URL]) {
        let supported = Set(["zip", "ttsmod", "7z", "rar"])
        var rejected: [String] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            guard exists && (isDirectory.boolValue || supported.contains(url.pathExtension.lowercased())) else {
                rejected.append(url.lastPathComponent)
                continue
            }
            if !packageURLs.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) {
                packageURLs.append(url)
            }
        }
        tableView.reloadData()
        if rejected.isEmpty {
            statusLabel.stringValue = "已收到 \(packageURLs.count) 个图包，确认目标后就可以安装啦～"
        } else {
            statusLabel.stringValue = "已忽略不支持的项目：\(rejected.joined(separator: "、"))"
        }
        updateControls()
    }

    private func configureUI() {
        let title = NSTextField(labelWithString: "TTS 本地图包安装器")
        title.font = .systemFont(ofSize: 25, weight: .bold)
        title.textColor = NSColor(calibratedRed: 0.72, green: 0.37, blue: 0.50, alpha: 1)
        let subtitle = NSTextField(labelWithString: "macOS v\(InstallerConstants.version)  ·  安全合并覆盖，不删除原有文件")
        subtitle.textColor = .secondaryLabelColor

        updateButton.bezelStyle = .rounded
        updateButton.title = "检查更新…"
        updateButton.target = self
        updateButton.action = #selector(checkForUpdates)
        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [NSStackView(views: [title, subtitle]), headerSpacer, updateButton])
        (header.views[0] as? NSStackView)?.orientation = .vertical
        (header.views[0] as? NSStackView)?.alignment = .leading
        header.orientation = .horizontal
        header.alignment = .centerY

        dropZone.translatesAutoresizingMaskIntoConstraints = false
        dropZone.heightAnchor.constraint(equalToConstant: 115).isActive = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("package"))
        column.title = "待安装图包"
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.delegate = self
        tableView.dataSource = self
        tableView.rowHeight = 28
        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 125).isActive = true

        let chooseButton = NSButton(title: "选择图包…", target: self, action: #selector(choosePackages))
        let clearButton = NSButton(title: "清空列表", target: self, action: #selector(clearPackages))
        let packageButtons = NSStackView(views: [chooseButton, clearButton])
        packageButtons.orientation = .horizontal

        let targetTitle = NSTextField(labelWithString: "安装目标")
        targetTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        targetPopup.addItems(withTitles: ["跟随 TTS 配置", "用户目录", "Game Data"])
        targetPopup.target = self
        targetPopup.action = #selector(targetChanged)
        targetPathLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        targetPathLabel.textColor = .secondaryLabelColor
        targetPathLabel.maximumNumberOfLines = 3
        let targetRow = NSStackView(views: [targetTitle, targetPopup])
        targetRow.orientation = .horizontal
        targetRow.spacing = 12
        let targetBox = NSBox()
        targetBox.boxType = .custom
        targetBox.cornerRadius = 10
        targetBox.fillColor = NSColor(calibratedRed: 0.93, green: 0.96, blue: 0.98, alpha: 0.8)
        targetBox.borderColor = NSColor(calibratedRed: 0.65, green: 0.78, blue: 0.84, alpha: 0.8)
        let targetStack = NSStackView(views: [targetRow, targetPathLabel])
        targetStack.orientation = .vertical
        targetStack.alignment = .leading
        targetStack.spacing = 7
        targetStack.translatesAutoresizingMaskIntoConstraints = false
        targetBox.contentView = targetStack
        NSLayoutConstraint.activate([
            targetStack.leadingAnchor.constraint(equalTo: targetBox.leadingAnchor, constant: 12),
            targetStack.trailingAnchor.constraint(equalTo: targetBox.trailingAnchor, constant: -12),
            targetStack.topAnchor.constraint(equalTo: targetBox.topAnchor, constant: 10),
            targetStack.bottomAnchor.constraint(equalTo: targetBox.bottomAnchor, constant: -10)
        ])

        progressIndicator.minValue = 0
        progressIndicator.maxValue = 1
        progressIndicator.doubleValue = 0
        progressIndicator.isIndeterminate = false
        progressIndicator.controlSize = .regular
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 3

        installButton.bezelStyle = .rounded
        installButton.keyEquivalent = "\r"
        installButton.target = self
        installButton.action = #selector(startInstall)
        cancelButton.target = self
        cancelButton.action = #selector(cancelInstall)
        cancelButton.isHidden = true
        openLogButton.target = self
        openLogButton.action = #selector(openLogs)
        openModsButton.target = self
        openModsButton.action = #selector(openMods)
        let footer = NSStackView(views: [installButton, cancelButton, openLogButton, openModsButton])
        footer.orientation = .horizontal

        let content = NSStackView(views: [header, dropZone, scroll, packageButtons, targetBox, progressIndicator, statusLabel, footer])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            content.topAnchor.constraint(equalTo: view.topAnchor, constant: 22),
            content.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -22),
            header.widthAnchor.constraint(equalTo: content.widthAnchor),
            dropZone.widthAnchor.constraint(equalTo: content.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: content.widthAnchor),
            targetBox.widthAnchor.constraint(equalTo: content.widthAnchor),
            progressIndicator.widthAnchor.constraint(equalTo: content.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: content.widthAnchor)
        ])
    }

    func numberOfRows(in tableView: NSTableView) -> Int { packageURLs.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("PackageCell")
        let field: NSTextField
        if let existing = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField {
            field = existing
        } else {
            field = NSTextField(labelWithString: "")
            field.identifier = identifier
            field.lineBreakMode = .byTruncatingMiddle
        }
        field.stringValue = "🎁  " + packageURLs[row].path
        field.toolTip = packageURLs[row].path
        return field
    }

    @objc private func choosePackages() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = ["zip", "ttsmod", "7z", "rar"].compactMap { UTType(filenameExtension: $0) }
        if panel.runModal() == .OK { addPackageURLs(panel.urls) }
    }

    @objc private func clearPackages() {
        packageURLs.removeAll()
        tableView.reloadData()
        statusLabel.stringValue = "列表清空啦，可以继续拖入图包～"
        updateControls()
    }

    @objc private func targetChanged() { updateTargetPathLabel() }

    private func refreshDestination() {
        destinationResolution = pathResolver.resolve()
        updateTargetPathLabel()
        if destinationResolution.config.isAmbiguous {
            statusLabel.stringValue = "检测到多个 TTS 配置冲突，请手动选择用户目录或 Game Data。"
        } else if destinationResolution.config.mode == nil {
            statusLabel.stringValue = "未能读取 TTS Mods 位置，请手动选择安装目标。"
        }
    }

    private func selectedTarget() -> URL? {
        switch targetPopup.indexOfSelectedItem {
        case 1: return destinationResolution.userDataURL
        case 2: return destinationResolution.gameDataURL
        default: return destinationResolution.destination(for: nil)
        }
    }

    private func updateTargetPathLabel() {
        if let target = selectedTarget() {
            targetPathLabel.stringValue = target.path
        } else if targetPopup.indexOfSelectedItem == 2 && destinationResolution.gameDataURL == nil {
            targetPathLabel.stringValue = "未找到 Steam 中的 Tabletop Simulator.app"
        } else {
            targetPathLabel.stringValue = "配置缺失或冲突，请从上方菜单明确选择。"
        }
        updateControls()
    }

    private func updateControls(busy: Bool = false) {
        installButton.isEnabled = !busy && !packageURLs.isEmpty && selectedTarget() != nil
        targetPopup.isEnabled = !busy
        openModsButton.isEnabled = selectedTarget() != nil
        cancelButton.isHidden = !busy
        updateButton.title = updateCoordinator.buttonTitle
        updateButton.isEnabled = !busy && updateCoordinator.canCheckForUpdates
    }

    @objc private func startInstall() {
        guard !packageURLs.isEmpty, let target = selectedTarget() else { return }
        if !NSRunningApplication.runningApplications(withBundleIdentifier: InstallerConstants.ttsBundleIdentifier).isEmpty {
            showAlert(title: "请先退出 Tabletop Simulator", message: "游戏运行时配置和 Mods 文件可能仍在使用。安装器不会自动结束游戏，请退出后再试。")
            return
        }
        let token = CancellationToken()
        cancellationToken = token
        progressIndicator.isIndeterminate = true
        progressIndicator.startAnimation(nil)
        statusLabel.stringValue = "正在安全预检图包，请稍候… 🔍"
        updateControls(busy: true)
        let packages = packageURLs
        let service = InstallerService()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try service.verifyWritableTarget(target)
                let batch = try service.prepare(packageURLs: packages, targetURL: target, cancellationToken: token)
                DispatchQueue.main.async {
                    guard let self else { batch.cleanup(); return }
                    self.lastLogURL = batch.logger.logURL
                    if token.isCancelled { batch.cleanup(); self.finishCancelled(); return }
                    guard !batch.packages.isEmpty else {
                        batch.cleanup()
                        let details = batch.failures.map { "• \($0.packageURL.lastPathComponent)：\($0.message)" }.joined(separator: "\n")
                        self.finishWithError("没有可安装的图包。\n\(details)")
                        return
                    }
                    guard self.confirm(batch: batch) else {
                        batch.cleanup()
                        self.finishCancelled()
                        return
                    }
                    self.execute(batch: batch, service: service, token: token)
                }
            } catch {
                DispatchQueue.main.async { self?.finishWithError(error.localizedDescription) }
            }
        }
    }

    private func confirm(batch: PreparedBatch) -> Bool {
        progressIndicator.stopAnimation(nil)
        progressIndicator.isIndeterminate = false
        let alert = NSAlert()
        alert.messageText = "确认安装这批图包？"
        var message = "目标：\(batch.targetURL.path)\n\n文件：\(batch.fileCount) 个\n本次写入约：\(ByteCountText.string(batch.totalBytes))\n同名覆盖：\(batch.conflictCount) 个（\(ByteCountText.string(batch.overwriteBytes))）\n预计净增长：\(ByteCountText.string(batch.requiredGrowthBytes))"
        if let available = batch.availableBytes {
            message += "\n目标剩余空间：\(ByteCountText.string(available))"
        }
        if !batch.failures.isEmpty { message += "\n\n另有 \(batch.failures.count) 个图包预检失败，将跳过。" }
        alert.informativeText = message
        alert.alertStyle = batch.failures.isEmpty ? .informational : .warning
        alert.addButton(withTitle: "开始安装")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func execute(batch: PreparedBatch, service: InstallerService, token: CancellationToken) {
        progressIndicator.isIndeterminate = false
        progressIndicator.doubleValue = 0
        statusLabel.stringValue = "正在合并覆盖，原有无关文件会保留～ 🐾"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let results = service.execute(batch: batch, cancellationToken: token) { progress in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.progressIndicator.doubleValue = progress.totalBytes > 0
                        ? Double(progress.completedBytes) / Double(progress.totalBytes) : 0
                    self.statusLabel.stringValue = "图包 \(progress.packageIndex)/\(progress.packageCount) · 文件 \(progress.fileIndex)/\(progress.fileCount)\n\(progress.currentURL.lastPathComponent)"
                }
            }
            DispatchQueue.main.async { self?.finish(results: results, cancelled: token.isCancelled) }
        }
    }

    @objc private func cancelInstall() {
        cancellationToken?.cancel()
        cancelButton.isEnabled = false
        statusLabel.stringValue = "正在安全停止，请稍候…"
    }

    private func finish(results: [PackageResult], cancelled: Bool) {
        cancellationToken = nil
        cancelButton.isEnabled = true
        progressIndicator.stopAnimation(nil)
        progressIndicator.isIndeterminate = false
        let succeeded = results.filter(\.succeeded).count
        let warned = results.filter { $0.succeeded && $0.hadWarnings }.count
        let failed = results.count - succeeded
        if cancelled {
            statusLabel.stringValue = "已取消。已经完成的文件不会回滚，可重新安装同一图包继续覆盖。"
        } else if failed == 0 && warned == 0 {
            statusLabel.stringValue = "安装完成：\(succeeded)/\(results.count) 个图包成功！ヽ(✿ﾟ▽ﾟ)ノ"
        } else {
            statusLabel.stringValue = "批次结束：成功 \(succeeded)，警告 \(warned)，失败 \(failed)。请查看日志。"
        }
        progressIndicator.doubleValue = succeeded > 0 ? 1 : 0
        updateControls()
        let details = results.map { result in
            "\(result.succeeded ? (result.hadWarnings ? "⚠️" : "✅") : "❌") \(result.packageURL.lastPathComponent)：\(result.message)"
        }.joined(separator: "\n")
        showAlert(title: cancelled ? "安装已取消" : "批次结果", message: details)
    }

    private func finishCancelled() {
        cancellationToken = nil
        progressIndicator.stopAnimation(nil)
        progressIndicator.isIndeterminate = false
        progressIndicator.doubleValue = 0
        statusLabel.stringValue = "本次操作已取消。"
        updateControls()
    }

    private func finishWithError(_ message: String) {
        cancellationToken = nil
        progressIndicator.stopAnimation(nil)
        progressIndicator.isIndeterminate = false
        progressIndicator.doubleValue = 0
        statusLabel.stringValue = "没有完成：\(message)"
        updateControls()
        showAlert(title: "安装没有完成", message: message)
    }

    @objc private func openLogs() {
        let directory = lastLogURL?.deletingLastPathComponent() ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/TTS Mod Installer")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }

    @objc private func openMods() {
        guard let target = selectedTarget() else { return }
        if FileManager.default.fileExists(atPath: target.path) { NSWorkspace.shared.open(target) }
        else { showAlert(title: "Mods 目录尚不存在", message: target.path) }
    }

    @objc private func checkForUpdates() { updateCoordinator.checkManually() }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}
