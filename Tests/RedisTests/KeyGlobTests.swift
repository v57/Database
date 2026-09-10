import Foundation
import Testing

@testable import Redis

/// Pure unit tests for the Redis key glob builder used by the UI filter: typed
/// text + a match mode -> a SCAN MATCH pattern. No server.
@Suite struct KeyGlobTests {
  @Test func matchModesWrapTheText() {
    #expect(KeyGlob.pattern("user", match: .contains) == "*user*")
    #expect(KeyGlob.pattern("user:", match: .startsWith) == "user:*")
    #expect(KeyGlob.pattern(":1", match: .endsWith) == "*:1")
    #expect(KeyGlob.pattern("user:1", match: .exact) == "user:1")
  }

  @Test func emptyTextMeansNoFilter() {
    #expect(KeyGlob.pattern("   ", match: .contains) == nil)
  }

  @Test func typedGlobMetacharactersAreEscaped() {
    #expect(KeyGlob.pattern("a*b", match: .exact) == #"a\*b"#)
    #expect(KeyGlob.pattern("a?b", match: .contains) == #"*a\?b*"#)
    #expect(KeyGlob.pattern("a[b]", match: .exact) == #"a\[b\]"#)
    #expect(KeyGlob.pattern(#"a\b"#, match: .exact) == #"a\\b"#)
  }

  @Test func explicitGlobsAreDetected() {
    #expect(KeyGlob.isPattern("user:*"))
    #expect(KeyGlob.isPattern("*user*"))
    #expect(KeyGlob.isPattern("us?r"))
    #expect(!KeyGlob.isPattern("user"))
    #expect(!KeyGlob.isPattern(""))
  }
}
