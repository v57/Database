# WireKit

WireKit is the transport layer under Database's engines. It holds the byte streams a wire client talks over, the
dialer that decides how a client reaches its server (a TCP connection of its own, or a stream something else opens,
such as an SSH channel), the value types every engine returns (`DBValue`, `DBResult`), and the buffers, hashes and
SCRAM login the protocols share.

Use it when you bring your own transport (Shell feeds its own SSH channels to Database's engines through a
`WireDialer`), or when you want `DBValue` and `DBResult` from [SQLiteKit](SQLiteKit.md) or an engine. It is not a
database client by itself: the engines are in [DatabaseKit](DatabaseKit.md).

## Getting started

```swift
// Package.swift
dependencies: [
  .package(url: "https://github.com/v57/Database.git", branch: "main"),
],
targets: [
  .target(name: "MyApp", dependencies: [.product(name: "WireKit", package: "Database")]),
]
```

A line-based exchange over TCP:

```swift
import WireKit

let connection = try await WireDialer.direct.connect(host: "127.0.0.1", port: 6379)
try await connection.send(Array("PING\r\n".utf8))
let reply = try await connection.readLine()  // "+PONG"
connection.close()
```

## Main API

### Streams and dialers

- `WireStream`: the protocol a client talks over: `send(_:)`, `receive()`, `isOpen`, `close()`.
- `WireConnection`: a buffered reader and writer over any `WireStream`: `send(_:)`, `read(exactly:)`,
  `readAvailable()`, `readLine()`, `close()`. `WireConnection.connect(host:port:tls:timeout:)` opens TCP;
  `WireConnection.connect(over:serverName:tls:timeout:)` puts TLS on top of a stream it didn't open.
- `WireDialer`: how a client reaches `host:port`. `WireDialer.direct` is TCP from this device;
  `WireDialer.streams { host, port, timeout in … }` uses streams you open (an SSH channel), adding TLS when the client
  asks for it. `isTunnel` is true for the latter.
- `WireDialer.protects(host:tls:)`: whether a login may send a password the server asks for in readable form
  (cleartext or MD5): only through a tunnel, over TLS, or to this device (`isLoopback(_:)`). Otherwise the engines
  refuse such a login with `WireError.insecureLogin` unless the connection allows it.
- `WireChannel`: a `WireStream` that another thread carries. The app side reads and writes it as usual; the thread that
  owns the real transport calls `takeOutbound()`, `deliver(_:)` and `finish(_:)`, checks `wantsInbound` and
  `isClosedByApp`, and is woken by the `onActivity` closure. `WireChannel.inboundLimit` (1 MiB) bounds what the app
  may leave unread, so the transport's flow control holds the sender back. [SSHTunnel](SSHTunnel.md)'s
  `SSHChannelStreams` is built on it.
- `TLSSettings`: `enabled`, `allowUntrusted`, `alpn`; `TLSSettings.off`. Only TLS from the first byte is supported;
  protocols that upgrade to TLS in the middle of a connection (MySQL, MariaDB, SQL Server) go through SSH instead.

### Values

- `DBValue`: one cell: `null`, `bool`, `int`, `double`, `decimal` (exact numbers as text), `text`, `bytes`, `uuid`,
  `json`, `list`, `map`. Dates and times stay in the server's text form. `displayText`, `literalText`,
  `stringValue`, `intValue`, `doubleValue`.
- `DBColumn` (`name`, `typeName`, `table`), `DBPair`.
- `DBResult`: what one statement produced: `columns`, `rows`, `affectedRows`, `messages`, `commandTag`; `hasRows`,
  `column(_:)`, `records` (rows as dictionaries).
- `DBServerError`: an error from the server with the engine's own code and message.
- `WireError`: transport failures: `truncated`, `connectionFailed`, `timedOut`, `closed`, `protocolViolation`,
  `authenticationFailed`, `unsupported`, `insecureLogin`.

### Helpers for protocol code

- `ByteWriter`, `ByteReader`: big- and little-endian integers, floats, C strings, UTF-8.
- `Digest`: SHA-1, SHA-256, MD5, HMAC, PBKDF2, random bytes. `SCRAMClient`: SCRAM-SHA-1 and SCRAM-SHA-256 logins.
- `AsyncMutex`: runs async closures one at a time.

## Platform notes

- **macOS, iOS:** TCP and TLS through Network.framework. TLS over a stream it didn't open (an SSH channel) goes
  through a one-shot Unix socket in a private temporary folder that accepts one connection, only from this process,
  and is deleted once that arrives: no port, nothing another app or user can reach.
- **Linux, Windows:** builds on v57/SwiftUI's stand-ins for CryptoKit and Network. TLS over a stream runs the
  stand-in's TLS session over the stream itself (OpenSSL on Linux, SChannel on Windows).
- **Other systems:** a dialer asked for TLS over a stream throws `WireError.unsupported`.
- **Android:** not yet.

## Testing

```bash
swift test --filter WireKitTests
```

These tests need no servers. The TLS test needs `openssl` on the `PATH` and is skipped without it.
