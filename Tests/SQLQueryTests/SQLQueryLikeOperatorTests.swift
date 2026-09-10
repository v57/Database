import Foundation
import Testing

@testable import SQLQuery

/// Unit tests for the LIKE operators the UI filter builder emits:
/// `$contains`, `$notContains`, `$startsWith`, `$endsWith`. No server.
@Suite struct SQLQueryLikeOperatorTests {
  private func whereBody(_ filter: String) throws -> String {
    try #require(try SQLQueryCompiler.compile(filter: filter, sort: nil, projection: nil).whereBody)
  }

  @Test func containsBecomesLikeWithEscapedWildcards() throws {
    #expect(try whereBody(#"{"name": {"$contains": "ann"}}"#) == "\"name\" LIKE '%ann%' ESCAPE '\\'")
  }

  @Test func startsAndEndsAnchorThePattern() throws {
    #expect(try whereBody(#"{"name": {"$startsWith": "an"}}"#) == "\"name\" LIKE 'an%' ESCAPE '\\'")
    #expect(try whereBody(#"{"name": {"$endsWith": "nn"}}"#) == "\"name\" LIKE '%nn' ESCAPE '\\'")
  }

  @Test func notContainsBecomesNotLike() throws {
    #expect(try whereBody(#"{"name": {"$notContains": "ann"}}"#)
      == "\"name\" NOT LIKE '%ann%' ESCAPE '\\'")
  }

  @Test func userPercentUnderscoreAndBackslashAreLiteral() throws {
    #expect(try whereBody(#"{"name": {"$contains": "50%"}}"#)
      == "\"name\" LIKE '%50\\%%' ESCAPE '\\'")
    #expect(try whereBody(#"{"name": {"$contains": "a_b"}}"#)
      == "\"name\" LIKE '%a\\_b%' ESCAPE '\\'")
    #expect(try whereBody(#"{"name": {"$contains": "a\\b"}}"#)
      == "\"name\" LIKE '%a\\\\b%' ESCAPE '\\'")
  }

  @Test func likeOperatorsAndWithOtherConditions() throws {
    #expect(try whereBody(#"{"name": {"$contains": "ann"}, "age": {"$gt": 30}}"#)
      == "\"name\" LIKE '%ann%' ESCAPE '\\' AND \"age\" > 30")
  }

  @Test func nonStringValueThrows() {
    #expect(throws: SQLQueryError.self) {
      _ = try SQLQueryCompiler.compile(filter: #"{"name": {"$contains": 5}}"#, sort: nil,
        projection: nil)
    }
  }

  @Test func unsupportedOperatorMessageListsTheLikeOperators() {
    do {
      _ = try SQLQueryCompiler.compile(filter: #"{"name": {"$weird": 1}}"#, sort: nil,
        projection: nil)
      Issue.record("expected a throw")
    } catch let error as SQLQueryError {
      let message = error.errorDescription ?? ""
      #expect(message.contains("$contains"))
      #expect(message.contains("$startsWith"))
    } catch { Issue.record("unexpected error \(error)") }
  }
}
