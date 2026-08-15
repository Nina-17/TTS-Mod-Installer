import Darwin
import Foundation
import TTSModInstallerCore

private var passed = 0
private var failed = 0

private func check(_ condition: @autoclosure () throws -> Bool, _ name: String) {
    do {
        if try condition() {
            passed += 1
            print("PASS: \(name)")
        } else {
            failed += 1
            print("FAIL: \(name)")
        }
    } catch {
        failed += 1
        print("FAIL: \(name) — \(error)")
    }
}

private func didThrow(_ body: () throws -> Void) -> Bool {
    do { try body(); return false } catch { return true }
}

private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("TTSModInstallerTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(root)
}

do {
    let data = try PropertyListSerialization.data(
        fromPropertyList: ["ConfigGame": #"{"ConfigMods":{"Caching":true,"Location":0}}"#],
        format: .binary,
        options: 0
    )
    let result = TTSPathResolver.parseConfiguration(plistData: data)
    check(result.mode == .userData && !result.isAmbiguous, "解析 macOS ConfigGame Location=0")
} catch { check(false, "构造 macOS plist fixture") }

do {
    let data = try PropertyListSerialization.data(
        fromPropertyList: [
            "ConfigGame": #"{"ConfigMods":{"Location":0}}"#,
            "ConfigGame_h1": #"{"ConfigMods":{"Location":1}}"#
        ],
        format: .xml,
        options: 0
    )
    let result = TTSPathResolver.parseConfiguration(plistData: data)
    check(result.mode == nil && result.isAmbiguous, "配置冲突时不静默猜测")
} catch { check(false, "构造配置冲突 fixture") }

let vdf = #""path" "/Volumes/Games/SteamLibrary""# + "\n" + #""path" "/Users/test/Library/Application Support/Steam""#
check(TTSPathResolver.parseSteamLibraries(vdf: vdf) == [
    "/Volumes/Games/SteamLibrary",
    "/Users/test/Library/Application Support/Steam"
], "解析 Steam libraryfolders.vdf")
check(TTSPathResolver.parseInstallDirectory(manifest: #""installdir" "Tabletop Simulator""#) == "Tabletop Simulator", "解析 Steam appmanifest")

check(!didThrow { try PathSafety.validateArchivePath("Mods/Images/card.png") }, "接受安全压缩包路径")
check(didThrow { try PathSafety.validateArchivePath("../escape") }, "拒绝越级路径")
check(didThrow { try PathSafety.validateArchivePath("/absolute/file") }, "拒绝 Unix 绝对路径")
check(didThrow { try PathSafety.validateArchivePath("C:\\escape\\file") }, "拒绝 Windows 绝对路径")
check(didThrow { try PathSafety.assertNoPathCollisions(["Images/Card.png", "images/card.png"]) }, "拒绝大小写冲突")
check(didThrow { try PathSafety.assertNoPathCollisions(["Images/café.png", "Images/cafe\u{301}.png"]) }, "拒绝 Unicode 归一化冲突")

let listing = """
Path = Mods
Folder = +
Size = 0
Attributes = D drwxr-xr-x

Path = Mods/Images/card.png
Size = 123
Packed Size = 90
Attributes = A -rw-r--r--

"""
do {
    let entries = try SevenZipTool.parseTechnicalListing(listing)
    check(entries.count == 2 && entries[1].size == 123, "解析 7‑Zip 技术列表")
} catch { check(false, "解析 7‑Zip 技术列表") }
let linkedListing = """
Path = Mods/Images/link.png
Size = 0
Symbolic Link = ../../outside

"""
check(didThrow { _ = try SevenZipTool.parseTechnicalListing(linkedListing) }, "拒绝压缩包符号链接")
let negativeSizeListing = """
Path = Mods/Images/bad.png
Size = -1

"""
check(didThrow { _ = try SevenZipTool.parseTechnicalListing(negativeSizeListing) }, "拒绝负数文件大小")

if let sevenZipPath = ProcessInfo.processInfo.environment["TTS_MOD_INSTALLER_7ZZ"] {
    do {
        try withTemporaryDirectory { root in
            let packageRoot = root.appendingPathComponent("source", isDirectory: true)
            let images = packageRoot.appendingPathComponent("Mods/Images", isDirectory: true)
            try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
            try Data("archive integration".utf8).write(to: images.appendingPathComponent("card.txt"))
            let executable = URL(fileURLWithPath: sevenZipPath)
            let cache = root.appendingPathComponent("cache", isDirectory: true)
            let tool = try SevenZipTool(executableURL: executable, extractionBaseURL: cache)
            for archiveType in ["zip", "7z"] {
                let archive = root.appendingPathComponent("package.\(archiveType)")
                let created = try ProcessRunner.run(
                    executable: executable,
                    arguments: ["a", "-t\(archiveType)", archive.path, "Mods"],
                    currentDirectoryURL: packageRoot
                )
                check(created.exitCode == 0, "生成 \(archiveType.uppercased()) 集成 fixture")
                let info = try tool.inspect(archiveURL: archive)
                check(info.fileCount == 1 && info.uncompressedBytes == 19, "预检 \(archiveType.uppercased()) 压缩包")
                let extracted = try tool.extract(archiveURL: archive)
                let mods = try FileTreeScanner.resolveModsRoot(extracted.root)
                check(try String(contentsOf: mods.appendingPathComponent("Images/card.txt")) == "archive integration", "解压 \(archiveType.uppercased()) 压缩包")
                try? FileManager.default.removeItem(at: extracted.root)
                if archiveType == "zip" {
                    let ttsmod = root.appendingPathComponent("package.ttsmod")
                    try FileManager.default.copyItem(at: archive, to: ttsmod)
                    let ttsmodExtracted = try tool.extract(archiveURL: ttsmod)
                    let ttsmodMods = try FileTreeScanner.resolveModsRoot(ttsmodExtracted.root)
                    check(try String(contentsOf: ttsmodMods.appendingPathComponent("Images/card.txt")) == "archive integration", "按 ZIP 内容解压 TTSMOD")
                    try? FileManager.default.removeItem(at: ttsmodExtracted.root)
                }
            }

            if let encodedRAR = Bundle.module.url(forResource: "test_read_format_rar.rar", withExtension: "uu", subdirectory: "Fixtures") {
                let rar = root.appendingPathComponent("fixture.rar")
                let decoded = try ProcessRunner.run(
                    executable: URL(fileURLWithPath: "/usr/bin/uudecode"),
                    arguments: ["-o", rar.path, encodedRAR.path]
                )
                check(decoded.exitCode == 0, "解码上游 RAR fixture")
                let rarInfo = try tool.inspect(archiveURL: rar)
                check(rarInfo.fileCount > 0, "预检 RAR 压缩包")
                do {
                    let rarExtracted = try tool.extract(archiveURL: rar)
                    check(false, "RAR 上游安全 fixture 应包含符号链接")
                    try? FileManager.default.removeItem(at: rarExtracted.root)
                } catch InstallerError.unsafePackage {
                    check(true, "RAR 解压后拒绝符号链接")
                }
            } else {
                check(false, "加载上游 RAR fixture")
            }
        }
    } catch { check(false, "真实压缩包集成：\(error)") }
}

do {
    try withTemporaryDirectory { root in
        try FileManager.default.createDirectory(at: root.appendingPathComponent("图包/Mods/Images"), withIntermediateDirectories: true)
        let actual = try FileTreeScanner.resolveModsRoot(root)
        let expected = root.appendingPathComponent("图包/Mods")
        check(PathSafety.canonicalURL(actual).path == PathSafety.canonicalURL(expected).path, "识别嵌套 Mods 包装")
    }
    try withTemporaryDirectory { root in
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Translations"), withIntermediateDirectories: true)
        check(try FileTreeScanner.resolveModsRoot(root).path == root.path, "识别 macOS Translations Mods 根目录")
    }
    try withTemporaryDirectory { root in
        try FileManager.default.createDirectory(at: root.appendingPathComponent("A/Mods"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("B/Mods"), withIntermediateDirectories: true)
        check(didThrow { _ = try FileTreeScanner.resolveModsRoot(root) }, "拒绝多个 Mods 候选")
    }
} catch { check(false, "Mods 包装目录测试准备") }

do {
    try withTemporaryDirectory { root in
        let source = root.appendingPathComponent("source/Mods", isDirectory: true)
        let target = root.appendingPathComponent("target/Mods", isDirectory: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("Images"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target.appendingPathComponent("Images"), withIntermediateDirectories: true)
        try Data("NEW!".utf8).write(to: source.appendingPathComponent("Images/card.txt"))
        try Data("old!!".utf8).write(to: target.appendingPathComponent("Images/card.txt"))
        try Data("keep".utf8).write(to: target.appendingPathComponent("Images/unrelated.txt"))
        let engine = CopyEngine()
        let summary = try engine.scan(sourceRoot: source, targetRoot: target)
        check(summary.conflictCount == 1 && summary.requiredGrowthBytes == 0, "区分写入量和同大小净增长")
        let logger = try InstallerLogger(directory: root.appendingPathComponent("logs"))
        try engine.copy(summary: summary, targetRoot: target, logger: logger)
        check(try String(contentsOf: target.appendingPathComponent("Images/card.txt")) == "NEW!", "覆盖同名文件")
        check(try String(contentsOf: target.appendingPathComponent("Images/unrelated.txt")) == "keep", "保留无关文件")
    }
} catch { check(false, "安全合并端到端：\(error)") }

do {
    try withTemporaryDirectory { root in
        let source = root.appendingPathComponent("source", isDirectory: true)
        let target = root.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("Images"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("Images/link"), withDestinationURL: URL(fileURLWithPath: "/private/tmp"))
        check(didThrow { _ = try CopyEngine().scan(sourceRoot: source, targetRoot: target) }, "拒绝来源符号链接")
    }
} catch { check(false, "符号链接测试准备") }

do {
    try withTemporaryDirectory { root in
        let source = root.appendingPathComponent("source/Mods", isDirectory: true)
        let target = root.appendingPathComponent("target/Mods", isDirectory: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("Images"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("blocked".utf8).write(to: source.appendingPathComponent("Images/card.txt"))
        try FileManager.default.createSymbolicLink(
            at: target.appendingPathComponent("Images"),
            withDestinationURL: FileManager.default.temporaryDirectory
        )
        check(didThrow { _ = try CopyEngine().scan(sourceRoot: source, targetRoot: target) }, "拒绝目标目录中的符号链接")
        check(didThrow { try PathSafety.assertSeparate(source: source, target: source.appendingPathComponent("nested")) }, "拒绝来源与目标互相嵌套")
    }
} catch { check(false, "目标路径安全测试准备") }

do {
    try withTemporaryDirectory { root in
        let package = root.appendingPathComponent("package/Mods/Models", isDirectory: true)
        let target = root.appendingPathComponent("target/Mods", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data("model".utf8).write(to: package.appendingPathComponent("piece.obj"))
        let service = InstallerService(
            logDirectory: root.appendingPathComponent("logs"),
            extractionBaseURL: root.appendingPathComponent("cache")
        )
        try service.verifyWritableTarget(target)
        let batch = try service.prepare(packageURLs: [root.appendingPathComponent("package")], targetURL: target)
        let results = service.execute(batch: batch)
        check(results.count == 1 && results[0].succeeded, "文件夹批处理端到端")
        check(try String(contentsOf: target.appendingPathComponent("Models/piece.obj")) == "model", "批处理写入目标")
    }
} catch { check(false, "文件夹批处理端到端：\(error)") }

do {
    try withTemporaryDirectory { root in
        let good = root.appendingPathComponent("good/Mods/Images", isDirectory: true)
        let bad = root.appendingPathComponent("bad/Unknown", isDirectory: true)
        let target = root.appendingPathComponent("target/Mods", isDirectory: true)
        try FileManager.default.createDirectory(at: good, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        try Data("first".utf8).write(to: good.appendingPathComponent("card.txt"))
        try Data("invalid".utf8).write(to: bad.appendingPathComponent("file.txt"))
        let service = InstallerService(
            logDirectory: root.appendingPathComponent("logs"),
            extractionBaseURL: root.appendingPathComponent("cache")
        )
        let goodPackage = root.appendingPathComponent("good")
        let badPackage = root.appendingPathComponent("bad")
        let batch = try service.prepare(packageURLs: [badPackage, goodPackage], targetURL: target)
        check(batch.failures.count == 1 && batch.packages.count == 1, "多包预检允许单包失败")
        let results = service.execute(batch: batch)
        check(results.count == 2 && results.filter(\.succeeded).count == 1, "多包部分失败仍安装安全图包")

        try Data("second".utf8).write(to: good.appendingPathComponent("card.txt"), options: .atomic)
        let retry = try service.prepare(packageURLs: [goodPackage], targetURL: target)
        let retryResults = service.execute(batch: retry)
        check(retryResults.first?.succeeded == true, "重新运行可恢复覆盖")
        check(try String(contentsOf: target.appendingPathComponent("Images/card.txt")) == "second", "重新运行写入最新文件")
    }
} catch { check(false, "多包部分失败与重试：\(error)") }

check(SemanticVersion("v0.6.0") == SemanticVersion("0.6.0"), "解析三段正式版本")
check(SemanticVersion("0.6.1")! > SemanticVersion("0.6.0")!, "比较更新版本")
check(SemanticVersion("v0.6-beta") == nil, "拒绝非正式版本")

let releaseURL = URL(string: "https://github.com/Nina-17/TTS-Mod-Installer/releases/download/v0.6.1/TTSModInstaller-macOS-v0.6.1.sparkle.zip")!
check(UpdateProxyURL.isAllowed(releaseURL), "允许 GitHub Release HTTPS 更新地址")
check(
    UpdateProxyURL.proxyURL(for: releaseURL)?.absoluteString ==
        "https://gh-proxy.com/https://github.com/Nina-17/TTS-Mod-Installer/releases/download/v0.6.1/TTSModInstaller-macOS-v0.6.1.sparkle.zip",
    "生成 gh-proxy.com 更新归档备用地址"
)
let encodedReleaseURL = URL(string: "https://github.com/Nina-17/TTS-Mod-Installer/releases/download/v0.6.1/TTS%20Mod.zip?source=app%20update")!
check(
    UpdateProxyURL.proxyURL(for: encodedReleaseURL)?.absoluteString ==
        "https://gh-proxy.com/https://github.com/Nina-17/TTS-Mod-Installer/releases/download/v0.6.1/TTS%20Mod.zip?source=app%20update",
    "代理地址保留原始 URL 编码"
)
check(UpdateProxyURL.isAllowed(URL(string: "https://nina-17.github.io/TTS-Mod-Installer/appcast.xml")!), "允许官方 GitHub Pages appcast")
check(!UpdateProxyURL.isAllowed(URL(string: "http://github.com/Nina-17/file.zip")!), "代理拒绝非 HTTPS 地址")
check(!UpdateProxyURL.isAllowed(URL(string: "https://example.com/file.zip")!), "代理拒绝非白名单域名")
check(!UpdateProxyURL.isAllowed(URL(string: "https://github.com/file.zip#fragment")!), "代理拒绝带片段的地址")

var feedFallback = UpdateFallbackState()
check(feedFallback.channel == .direct, "更新检查默认使用 GitHub 直连")
check(feedFallback.requestProxyRetry(forDownloadError: true), "直连下载错误触发代理重试")
check(feedFallback.channel == .proxy && feedFallback.retryUsed, "代理重试只切换一次通道")
check(!feedFallback.requestProxyRetry(forDownloadError: true), "代理失败不循环重试")

var archiveFallback = UpdateFallbackState()
archiveFallback.recordDownloadStarted()
check(archiveFallback.requestProxyRetry(forDownloadError: true), "更新归档直连失败切换代理")
check(archiveFallback.consumeContinueInstall(), "代理重试延续已确认安装")
check(!archiveFallback.consumeContinueInstall(), "已确认安装状态只消费一次")

var validationFailure = UpdateFallbackState()
check(!validationFailure.requestProxyRetry(forDownloadError: false), "签名或解析错误不切换代理")
check(validationFailure.channel == .direct && !validationFailure.retryUsed, "非网络错误保持直连状态")
validationFailure.beginFreshCheck()
check(validationFailure == UpdateFallbackState(), "新检查重置代理重试状态")

let liveResolver = TTSPathResolver()
if FileManager.default.fileExists(atPath: liveResolver.preferencesURL.path) {
    let resolution = liveResolver.resolve()
    check(resolution.userDataURL.path.hasSuffix("Library/Tabletop Simulator/Mods"), "本机用户 Mods 路径只读验收")
    if let app = resolution.steamAppURL {
        check(resolution.gameDataURL?.path == app.appendingPathComponent("Contents/Mods").path, "本机 Game Data 路径只读验收")
    }
}

print("\nSummary: \(passed) passed, \(failed) failed")
if failed > 0 { exit(1) }
