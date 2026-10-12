import Testing

@testable import DatabaseKit

@Suite struct ConnectionLinkTests {
  @Test func mongoLinkWithCredentialsAndOptions() throws {
    let link = try ConnectionLink.parse(
      "mongodb://ann:p%40ss@db.example.com:27018/shop?authSource=admin&directConnection=true")
    #expect(link.engine == .mongodb)
    #expect(link.host == "db.example.com")
    #expect(link.port == 27018)
    #expect(link.username == "ann")
    #expect(link.password == "p@ss")
    #expect(link.database == "shop")
    #expect(link.authSource == "admin")
    #expect(link.directConnection)
    #expect(link.warning == nil)
  }

  @Test func unencodedAtAndSlashInPassword() throws {
    let link = try ConnectionLink.parse("postgres://bob:a@b/c@localhost/app")
    #expect(link.username == "bob")
    #expect(link.password == "a@b/c")
    #expect(link.host == "localhost")
    #expect(link.port == nil)
    #expect(link.database == "app")
  }

  @Test func postgresQueryParametersAndEncryption() throws {
    let link = try ConnectionLink.parse(
      "postgresql://db.local:5433?user=me&password=secret&dbname=orders&sslmode=require")
    #expect(link.engine == .postgresql)
    #expect(link.port == 5433)
    #expect(link.username == "me")
    #expect(link.password == "secret")
    #expect(link.database == "orders")
    #expect(link.warning == ConnectionLink.encryptionWarning)
  }

  @Test func postgresPreferredEncryptionIsNoWarning() throws {
    #expect(try ConnectionLink.parse("postgres://h/db?sslmode=prefer").warning == nil)
  }

  @Test func redisPasswordOnlyAndDatabaseNumber() throws {
    let link = try ConnectionLink.parse("redis://:hunter2@127.0.0.1:6380/3")
    #expect(link.engine == .redis)
    #expect(link.username == nil)
    #expect(link.password == "hunter2")
    #expect(link.port == 6380)
    #expect(link.database == "3")
  }

  @Test func encryptedSchemesWarn() throws {
    #expect(try ConnectionLink.parse("rediss://cache.cloud:6379").warning != nil)
    let srv = try ConnectionLink.parse("mongodb+srv://u:p@cluster0.abc.mongodb.net/test")
    #expect(srv.host == "cluster0.abc.mongodb.net")
    #expect(srv.requiresEncryption)
    #expect(srv.warning == EncryptionNotice.message)
    #expect(try ConnectionLink.parse("mongodb://h/?tls=true").warning != nil)
  }

  @Test func cloudHostsNeedEncryptionEvenWithoutSaying() throws {
    let neon = try ConnectionLink.parse("postgres://me:pw@ep-cool-name-123.eu-central-1.aws.neon.tech/app")
    #expect(neon.requiresEncryption)
    let local = try ConnectionLink.parse("postgres://me@192.168.1.20/app")
    #expect(!local.requiresEncryption)
    #expect(local.warning == nil)
  }

  @Test func severalHostsUseTheFirst() throws {
    let link = try ConnectionLink.parse("mongodb://a.local:27017,b.local:27017/?replicaSet=rs0")
    #expect(link.host == "a.local")
    #expect(link.directConnection)
    #expect(link.warning?.contains("a.local") == true)
  }

  @Test func ipv6Host() throws {
    let link = try ConnectionLink.parse("postgres://[::1]:5432/postgres")
    #expect(link.host == "::1")
    #expect(link.port == 5432)
  }

  @Test func sqliteLinksAndPaths() throws {
    #expect(try ConnectionLink.parse("sqlite:///tmp/a.db").host == "/tmp/a.db")
    #expect(try ConnectionLink.parse("file:///tmp/My%20Data.sqlite").host == "/tmp/My Data.sqlite")
    let bare = try ConnectionLink.parse("  \"/Users/me/app.sqlite\"  ")
    #expect(bare.engine == .sqlite)
    #expect(bare.host == "/Users/me/app.sqlite")
  }

  @Test func rejectsUnknownAndEmpty() {
    #expect(throws: ConnectionLink.ParseError.empty) { try ConnectionLink.parse("  ") }
    #expect(throws: ConnectionLink.ParseError.unknownScheme("mysql")) {
      try ConnectionLink.parse("mysql://root@localhost/db")
    }
    #expect(throws: ConnectionLink.ParseError.unknownScheme("localhost")) {
      try ConnectionLink.parse("localhost:5432")
    }
    #expect(throws: ConnectionLink.ParseError.missingHost) { try ConnectionLink.parse("redis://") }
  }
}
