import Foundation
import Testing
@testable import SQLite

@Suite struct SQLiteConfigTests {
  @Test func validationRequiresNameAndPath() {
    #expect(SQLiteConnectionConfig(name: "x", filePath: "/tmp/a.sqlite").isValid)
    #expect(!SQLiteConnectionConfig(name: "", filePath: "/tmp/a.sqlite").isValid)
    #expect(!SQLiteConnectionConfig(name: "x", filePath: "").isValid)
  }

  @Test func connectionStringShowsFilePath() {
    let c = SQLiteConnectionConfig(name: "x", filePath: "/tmp/a b.sqlite")
    #expect(c.connectionString == "sqlite:///tmp/a b.sqlite")
  }
}