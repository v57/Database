import Testing

@testable import DatabaseKit

/// Messages below are what the drivers really return (collected against
/// closed ports, unknown hosts and a scratch SQLite file).
@Suite struct FriendlyErrorTests {
  @Test func unreachableServers() {
    let mongo = FriendlyError(
      "MongoDB error: No suitable servers found (`serverSelectionTryOnce` set): [connection refused calling hello on 'localhost:1']. Topology type: Single",
      while: .connecting)
    #expect(mongo.title == "Can’t reach the server")
    #expect(mongo.details.hasPrefix("No suitable servers found"))

    let postgres = FriendlyError(
      "PostgreSQL error: connection to server at \"localhost\" (::1), port 1 failed: Connection refused\n\tIs the server running on that host and accepting TCP/IP connections?",
      while: .connecting)
    #expect(postgres.title == "Can’t reach the server")
    #expect(!postgres.details.contains("\n"))

    // hiredis reports a refused connect as a socket-option failure.
    let redis = FriendlyError(
      "Redis error: Redis: setsockopt(TCP_NODELAY): Invalid argument", while: .connecting)
    #expect(redis.title == "Can’t reach the server")
    #expect(redis.details == "setsockopt(TCP_NODELAY): Invalid argument")
    #expect(
      FriendlyError("Redis error: Redis: connection failed", while: .connecting).title
        == "Can’t reach the server")
  }

  @Test func unknownHosts() {
    for message in [
      "MongoDB error: No suitable servers found (`serverSelectionTryOnce` set): [Failed to resolve 'no-such-host.invalid']. Topology type: Single",
      "PostgreSQL error: could not translate host name \"no-such-host.invalid\" to address: nodename nor servname provided, or not known",
      "Redis error: Redis: nodename nor servname provided, or not known",
    ] {
      #expect(FriendlyError(message, while: .connecting).title == "Server not found")
    }
  }

  @Test func credentials() {
    #expect(
      FriendlyError(
        "PostgreSQL error: connection to server at \"localhost\" (127.0.0.1), port 5432 failed: FATAL:  password authentication failed for user \"bob\"",
        while: .connecting
      ).title == "Wrong username or password")
    #expect(
      FriendlyError("Redis error: NOAUTH Authentication required.", while: .connecting).title
        == "This server needs a password")
    #expect(
      FriendlyError(
        "PostgreSQL error: connection to server at \"h\", port 5432 failed: FATAL:  role \"bob\" does not exist",
        while: .connecting
      ).title == "There’s no user called “bob”")
    #expect(
      FriendlyError(
        "PostgreSQL error: connection to server failed: FATAL:  database \"shop\" does not exist",
        while: .connecting
      ).title == "There’s no database called “shop”")
  }

  @Test func encryptionRequired() {
    let error = FriendlyError(
      "PostgreSQL error: FATAL:  no pg_hba.conf entry for host \"1.2.3.4\", user \"u\", database \"d\", no encryption",
      while: .connecting)
    #expect(error.title == EncryptionNotice.title)
    #expect(error.requiresEncryption)
  }

  @Test func cloudHostFailuresAreExplainedAsEncryption() {
    // Atlas without TLS just times out; the host says why.
    let atlas = FriendlyError(
      "MongoDB error: No suitable servers found: [socket timeout calling hello on 'ac-x.abc.mongodb.net:27017']",
      while: .connecting, host: "cluster0-shard-00-00.abc.mongodb.net")
    #expect(atlas.requiresEncryption)
    #expect(atlas.details.contains("socket timeout"))
    // The same failure on a local server stays a plain timeout.
    let local = FriendlyError(
      "MongoDB error: No suitable servers found: [socket timeout calling hello on 'db.local:27017']",
      while: .connecting, host: "db.local")
    #expect(!local.requiresEncryption)
    #expect(local.title == "The server didn’t answer in time")
    // Only while connecting: a query error on a cloud host is about the query.
    #expect(
      !FriendlyError("Invalid query: no such column: x", while: .loading, host: "x.neon.tech")
        .requiresEncryption)
  }

  @Test func encryptedOnlyHosts() {
    #expect(EncryptionNotice.isEncryptedOnly(host: "cluster0.abc.mongodb.net"))
    #expect(EncryptionNotice.isEncryptedOnly(host: "DB.PROJECT.SUPABASE.CO."))
    #expect(!EncryptionNotice.isEncryptedOnly(host: "mongodb.net.example.com"))
    #expect(!EncryptionNotice.isEncryptedOnly(host: "localhost"))
    // No upgrade yet: the message points at local databases, not Pro.
    #expect(EncryptionNotice.upgradeURL == nil)
    #expect(!EncryptionNotice.message.contains(EncryptionNotice.upgradeName))
  }

  @Test func sqliteFiles() {
    #expect(
      FriendlyError("SQLite database file not found: /tmp/nope.sqlite", while: .connecting).title
        == "The database file is missing")
    #expect(
      FriendlyError("Not a SQLite database: /tmp/notdb.sqlite", while: .connecting).title
        == "This file isn’t a SQLite database")
  }

  @Test func queryProblemsNameTheField() {
    #expect(
      FriendlyError("Invalid query: no such column: nope", while: .loading).title
        == "There’s no field called “nope”")
    #expect(
      FriendlyError("PostgreSQL error: ERROR:  column \"agee\" does not exist", while: .loading)
        .title == "There’s no field called “agee”")
    #expect(
      FriendlyError("Invalid query: no such table: nope", while: .loading).title
        == "There’s no table called “nope”")
    let parse = FriendlyError(
      "Invalid query: expected ':' after key \"age\" at column 5", while: .loading)
    #expect(parse.title == "The query couldn’t be understood")
    #expect(parse.message == "expected ':' after key \"age\" at column 5")
  }

  @Test func saveConstraints() {
    #expect(
      FriendlyError("Invalid query: NOT NULL constraint failed: t.name", while: .saving).title
        == "“name” can’t be empty")
    #expect(
      FriendlyError("Invalid query: UNIQUE constraint failed: t.name", while: .saving).title
        == "That value is already used")
    #expect(
      FriendlyError(
        "MongoDB error: E11000 duplicate key error collection: shop.users index: email_1",
        while: .saving
      ).title == "That value is already used")
    #expect(
      FriendlyError("Invalid query: cannot store TEXT value in INTEGER column s.n", while: .saving)
        .title == "That value doesn’t fit this field")
  }

  @Test func unknownErrorsKeepTheirText() {
    let error = FriendlyError("MongoDB error: something odd", while: .saving)
    #expect(error.title == "Couldn’t save the change")
    #expect(error.message == "something odd")
    #expect(error.detailsRepeatMessage)
    // Syntax-looking text only reads as a query problem while loading.
    #expect(
      FriendlyError("expected value at column 8", while: .connecting).title == "Couldn’t connect")
  }
}
