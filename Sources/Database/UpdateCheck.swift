import Foundation

/// The direct-download app's update check: GitHub's "latest release" for the
/// repo, compared with the running version. Deliberately tiny — it tells the
/// user and opens the download; it never replaces the app by itself (that
/// would mean shipping an updater framework several times the app's size).
public enum UpdateCheck {
  /// What the check found.
  public struct Release: Equatable, Sendable {
    /// "1.2" (the tag without its "v").
    public let version: String
    /// The release page, for the notes and the download.
    public let page: URL
    /// The first .zip/.dmg asset, if any — a direct download link.
    public let download: URL?
  }

  /// `https://api.github.com/repos/<repo>/releases/latest`.
  public static func latestReleaseURL(repository: String) -> URL {
    URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
  }

  /// Decodes GitHub's release JSON; nil for drafts, prereleases or JSON
  /// without a tag.
  public static func release(fromJSON data: Data) -> Release? {
    struct Payload: Decodable {
      struct Asset: Decodable {
        let name: String
        let browser_download_url: URL
      }
      let tag_name: String?
      let html_url: URL?
      let draft: Bool?
      let prerelease: Bool?
      let assets: [Asset]?
    }
    guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
      let tag = payload.tag_name, let page = payload.html_url,
      payload.draft != true, payload.prerelease != true
    else { return nil }
    let download = payload.assets?.first {
      $0.name.hasSuffix(".zip") || $0.name.hasSuffix(".dmg")
    }?.browser_download_url
    return Release(version: version(fromTag: tag), page: page, download: download)
  }

  /// "v1.2.0" → "1.2.0".
  public static func version(fromTag tag: String) -> String {
    let trimmed = tag.trimmingCharacters(in: .whitespaces)
    return trimmed.lowercased().hasPrefix("v") ? String(trimmed.dropFirst()) : trimmed
  }

  /// Numeric, component-wise comparison: "1.10" is newer than "1.9", and
  /// "1.2" equals "1.2.0". Non-numeric parts (a "-beta" suffix) are ignored.
  public static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
    func parts(_ version: String) -> [Int] {
      version.split(separator: ".").map { part in Int(part.prefix { $0.isNumber }) ?? 0 }
    }
    let a = parts(candidate)
    let b = parts(current)
    for i in 0..<max(a.count, b.count) {
      let x = i < a.count ? a[i] : 0
      let y = i < b.count ? b[i] : 0
      if x != y { return x > y }
    }
    return false
  }
}
