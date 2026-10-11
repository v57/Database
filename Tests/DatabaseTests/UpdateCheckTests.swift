import Foundation
import Testing

@testable import Database

@Suite struct UpdateCheckTests {
  @Test func comparesVersionsNumerically() {
    #expect(UpdateCheck.isVersion("1.10", newerThan: "1.9"))
    #expect(UpdateCheck.isVersion("2.0", newerThan: "1.99.9"))
    #expect(!UpdateCheck.isVersion("1.2", newerThan: "1.2.0"))
    #expect(!UpdateCheck.isVersion("1.1", newerThan: "1.2"))
    #expect(UpdateCheck.isVersion("1.2.1-beta", newerThan: "1.2"))
  }

  @Test func stripsTheTagPrefix() {
    #expect(UpdateCheck.version(fromTag: "v1.3") == "1.3")
    #expect(UpdateCheck.version(fromTag: "1.3") == "1.3")
  }

  @Test func decodesTheLatestRelease() throws {
    let json = """
      {"tag_name": "v1.1", "html_url": "https://github.com/v57/Database/releases/tag/v1.1",
       "draft": false, "prerelease": false,
       "assets": [{"name": "notes.txt", "browser_download_url": "https://example.com/notes.txt"},
                  {"name": "Database.zip", "browser_download_url": "https://github.com/v57/Database/releases/download/v1.1/Database.zip"}]}
      """
    let release = try #require(UpdateCheck.release(fromJSON: Data(json.utf8)))
    #expect(release.version == "1.1")
    #expect(release.download?.lastPathComponent == "Database.zip")
  }

  @Test func ignoresPrereleasesAndJunk() {
    let pre = #"{"tag_name": "v2.0", "html_url": "https://x.y/z", "prerelease": true}"#
    #expect(UpdateCheck.release(fromJSON: Data(pre.utf8)) == nil)
    #expect(UpdateCheck.release(fromJSON: Data(#"{"message": "Not Found"}"#.utf8)) == nil)
  }
}
