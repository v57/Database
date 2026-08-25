import Foundation
import Testing

@testable import PostgreSQL

@Suite struct PostgresConfigTests {
  @Test func plainUriUsesDefaultDatabase() {
    let c = PostgresConnectionConfig(name: "local", host: "127.0.0.1", port: 5432)
    #expect(c.connectionString == "postgres://127.0.0.1:5432/postgres")
  }

  @Test func uriWithCredentialsAndDatabase() {
    let c = PostgresConnectionConfig(
      name: "a", host: "db.example.com", port: 5433, username: "u ser", password: "p@ss:word",
      defaultDatabase: "appdb")
    #expect(c.connectionString.contains("u%20ser:"))
    #expect(c.connectionString.hasSuffix("@db.example.com:5433/appdb"))
  }

  @Test func validation() {
    #expect(PostgresConnectionConfig(name: "x", host: "localhost").isValid)
    #expect(!PostgresConnectionConfig(name: "x", host: "").isValid)
  }
}
