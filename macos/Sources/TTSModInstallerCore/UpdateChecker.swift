import Foundation

public struct ReleaseInformation: Decodable {
    public let tagName: String
    public let pageURL: URL

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case pageURL = "html_url"
    }
}

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

public final class UpdateChecker {
    private let session: URLSession
    private let directURL = URL(string: "https://api.github.com/repos/Nina-17/TTS-Mod-Installer/releases/latest")!

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func check(completion: @escaping (Result<ReleaseInformation?, Error>) -> Void) {
        request(directURL) { [weak self] directResult in
            switch directResult {
            case .success(let release): self?.finish(release, completion: completion)
            case .failure:
                guard let self,
                      let proxyURL = URL(string: "https://gh-proxy.com/\(self.directURL.absoluteString)") else {
                    completion(directResult.map { Optional($0) })
                    return
                }
                self.request(proxyURL) { proxyResult in
                    switch proxyResult {
                    case .success(let release): self.finish(release, completion: completion)
                    case .failure(let error): completion(.failure(error))
                    }
                }
            }
        }
    }

    private func finish(_ release: ReleaseInformation, completion: @escaping (Result<ReleaseInformation?, Error>) -> Void) {
        guard let current = SemanticVersion(InstallerConstants.version),
              let latest = SemanticVersion(release.tagName), latest > current else {
            completion(.success(nil))
            return
        }
        completion(.success(release))
    }

    private func request(_ url: URL, completion: @escaping (Result<ReleaseInformation, Error>) -> Void) {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("TTS-Mod-Installer-macOS/\(InstallerConstants.version)", forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request) { data, response, error in
            if let error { completion(.failure(error)); return }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), let data else {
                completion(.failure(InstallerError.dependency("更新检查返回了无效响应。")))
                return
            }
            do { completion(.success(try JSONDecoder().decode(ReleaseInformation.self, from: data))) }
            catch { completion(.failure(error)) }
        }.resume()
    }
}
