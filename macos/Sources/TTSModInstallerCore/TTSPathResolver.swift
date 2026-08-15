import Foundation

public final class TTSPathResolver {
    private let fileManager: FileManager
    private let homeDirectory: URL

    public init(fileManager: FileManager = .default, homeDirectory: URL? = nil) {
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory ?? fileManager.homeDirectoryForCurrentUser
    }

    public var preferencesURL: URL {
        homeDirectory.appendingPathComponent("Library/Preferences/com.berserk-games.tabletop-simulator.plist")
    }

    public var userDataModsURL: URL {
        homeDirectory.appendingPathComponent("Library/Tabletop Simulator/Mods", isDirectory: true)
    }

    public func resolve() -> DestinationResolution {
        let config: ConfigResolution
        if let data = try? Data(contentsOf: preferencesURL) {
            config = Self.parseConfiguration(plistData: data)
        } else {
            config = ConfigResolution(mode: nil, isAmbiguous: false, valueNames: [])
        }
        let appURL = findTTSApplication()
        return DestinationResolution(
            config: config,
            userDataURL: userDataModsURL,
            gameDataURL: appURL?.appendingPathComponent("Contents/Mods", isDirectory: true),
            steamAppURL: appURL
        )
    }

    public static func parseConfiguration(plistData: Data) -> ConfigResolution {
        guard let object = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil),
              let dictionary = object as? [String: Any] else {
            return ConfigResolution(mode: nil, isAmbiguous: false, valueNames: [])
        }

        var parsed: [(String, ModLocationMode)] = []
        for key in dictionary.keys.sorted() where key == "ConfigGame" || key.hasPrefix("ConfigGame_h") {
            guard let mode = parseConfigValue(dictionary[key]) else { continue }
            parsed.append((key, mode))
        }

        let modes = Set(parsed.map(\.1))
        if modes.count == 1 {
            return ConfigResolution(mode: modes.first, isAmbiguous: false, valueNames: parsed.map(\.0))
        }
        if modes.count > 1 {
            return ConfigResolution(mode: nil, isAmbiguous: true, valueNames: parsed.map(\.0))
        }
        return ConfigResolution(mode: nil, isAmbiguous: false, valueNames: [])
    }

    private static func parseConfigValue(_ value: Any?) -> ModLocationMode? {
        let data: Data?
        if let text = value as? String {
            data = text.data(using: .utf8)
        } else if let rawData = value as? Data {
            data = rawData
        } else {
            data = nil
        }
        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let configMods = json["ConfigMods"] as? [String: Any],
              let location = (configMods["Location"] as? NSNumber)?.intValue else {
            return nil
        }
        if location == 0 { return .userData }
        if location == 1 { return .gameData }
        return nil
    }

    public func findTTSApplication() -> URL? {
        var libraries: [URL] = []
        let defaultSteamRoot = homeDirectory.appendingPathComponent("Library/Application Support/Steam", isDirectory: true)
        libraries.append(defaultSteamRoot)

        let vdfURL = defaultSteamRoot.appendingPathComponent("steamapps/libraryfolders.vdf")
        if let content = try? String(contentsOf: vdfURL, encoding: .utf8) {
            for path in Self.parseSteamLibraries(vdf: content) {
                libraries.append(URL(fileURLWithPath: NSString(string: path).expandingTildeInPath, isDirectory: true))
            }
        }

        var seen = Set<String>()
        for library in libraries {
            let root = library.standardizedFileURL
            guard seen.insert(root.path).inserted else { continue }
            let steamApps: URL
            if root.lastPathComponent == "steamapps" {
                steamApps = root
            } else {
                steamApps = root.appendingPathComponent("steamapps", isDirectory: true)
            }
            let manifest = steamApps.appendingPathComponent("appmanifest_286160.acf")
            var installDirectory = "Tabletop Simulator"
            if let text = try? String(contentsOf: manifest, encoding: .utf8),
               let parsed = Self.parseInstallDirectory(manifest: text) {
                installDirectory = parsed
            }
            let app = steamApps
                .appendingPathComponent("common", isDirectory: true)
                .appendingPathComponent(installDirectory, isDirectory: true)
                .appendingPathComponent("Tabletop Simulator.app", isDirectory: true)
            if validateTTSApplication(app) { return app }
        }
        return nil
    }

    private func validateTTSApplication(_ appURL: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: appURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }
        let executable = appURL.appendingPathComponent("Contents/MacOS/Tabletop Simulator")
        return fileManager.isExecutableFile(atPath: executable.path)
    }

    public static func parseSteamLibraries(vdf: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"(?im)^\s*"path"\s+"([^"]+)""#) else { return [] }
        let range = NSRange(vdf.startIndex..<vdf.endIndex, in: vdf)
        return regex.matches(in: vdf, range: range).compactMap { match in
            guard let capture = Range(match.range(at: 1), in: vdf) else { return nil }
            return String(vdf[capture]).replacingOccurrences(of: #"\\"#, with: #"\"#)
        }
    }

    public static func parseInstallDirectory(manifest: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"(?im)^\s*"installdir"\s+"([^"]+)""#) else { return nil }
        let range = NSRange(manifest.startIndex..<manifest.endIndex, in: manifest)
        guard let match = regex.firstMatch(in: manifest, range: range),
              let capture = Range(match.range(at: 1), in: manifest) else { return nil }
        return String(manifest[capture])
    }
}
