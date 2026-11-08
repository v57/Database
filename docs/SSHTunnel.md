# SSHTunnel and Libssh2

`SSHTunnel` carries database connections over one SSH login: what `ssh -L` does, without the local port. Every
connection an engine makes is a `direct-tcpip` channel of that login, and the client talks to it inside this process.
Nothing listens on the device, so other apps and users can't reach the database through the tunnel.

The library re-exports **SSHKit** from the [SSH repository](https://github.com/v57/SSH): `SSHServer`, `SSHKey`,
`SSHHostTrust`, `SSHLogin`, `SSHJump`, `SFTPClient`, `SSHCommand` and the socket layer. An app that imports
`SSHTunnel` gets all of them. They are documented in SSH's [SSHKit page](https://github.com/v57/SSH/blob/main/docs/SSHKit.md);
this page covers only the tunnel.

`Libssh2` is a second product: libssh2 with Mbed TLS (the C module `CLibssh2`), re-exported from the SSH repository, for
apps that drive their own libssh2 sessions. Shell links it for its terminals so the app has one copy of libssh2.

## Getting started

```swift
// Package.swift
dependencies: [
  .package(url: "https://github.com/v57/Database.git", branch: "main"),
],
targets: [
  .target(
    name: "MyApp",
    dependencies: [
      .product(name: "SSHTunnel", package: "Database"),
      .product(name: "WireKit", package: "Database"),
    ]),
]
```

Open a tunnel and talk to a service the SSH server can reach. `host` is as the SSH server sees it, so `127.0.0.1` is
the server itself:

```swift
import SSHTunnel
import WireKit

let privateKeyText = try String(contentsOfFile: "/path/to/id_ecdsa", encoding: .utf8)
let savedFingerprint = "SHA256:…"  // the key you accepted the first time
let server = SSHServer(
  host: "bastion.example.com", user: "user", key: try SSHKey(importing: privateKeyText),
  trust: .pinned(savedFingerprint))
let tunnel = try await SSHTunnel.open(server: server)
tunnel.onClosed { reason in print("Tunnel closed:", reason ?? "by the app") }

let connection = try await tunnel.dialer.connect(host: "127.0.0.1", port: 6379)
try await connection.send(Array("PING\r\n".utf8))
print(try await connection.readLine())  // "+PONG"
connection.close()
tunnel.close()
```

To run one of Database's engines through it, pass `tunnel.dialer` as the `dialer` of the engine's configuration.
[DatabaseKit](DatabaseKit.md)'s `Connector` does this for you when a `ConnectionProfile` has SSH turned on.

For Libssh2, add `.product(name: "Libssh2", package: "Database")` and `import CLibssh2`.

## Main API

- `SSHTunnel.open(server:through:timeout:)`: logs in, through a jump host first when `through` is given (`ssh -J`:
  the jump host's login, then a channel from it to `server`, which checks the server's host key and logs in end to
  end).
- `dialer`: a [WireKit](WireKit.md) `WireDialer` whose connections are channels of this login. TLS goes on top of the
  channel when a client asks for it.
- `open(host:port:timeout:)`: one stream (a `WireChannel`) to `host:port` through the tunnel.
- `hostKeyFingerprint`, `hostKeyType`, `jumpHostKeyFingerprint`: the keys the login accepted.
- `isAlive`, `onClosed(_:)` (called once, on any thread, with a reason when the connection broke), `close()`.
- `SSHChannelStreams`: the channel layer on its own, for an app that owns its libssh2 session. Any thread asks for a
  stream (`open(host:port:timeout:)`, `dialer`); the thread that owns the session calls `pump(session:)` whenever the
  `onActivity` closure asks and on its own ticks, polls the socket for writing while `wantsSocketOut`, and calls
  `closeAll(reason:)` at the end. Shell runs Database's engines over its own SSH logins this way.

libssh2 isn't thread-safe per session, so each tunnel runs one thread that owns the session and every channel. It
sends a keepalive every few seconds and reports a dropped connection through `onClosed`.

The host key check is the `SSHServer`'s `trust`: a pinned fingerprint, a question to the user, or refusal of unknown
keys. There is no default that accepts any key.

## Platform notes

- **macOS, iOS:** the prebuilt libssh2 + Mbed TLS framework from the SSH repository.
- **Linux:** builds, with libssh2 built from source.
- **Windows:** libssh2 builds from source on WinCNG with ECDSA, and the tunnel polls Winsock sockets. TLS through a
  tunnel runs SChannel over the channel. Jump hosts aren't supported on Windows yet.
- **Android:** not yet.

libssh2 here uses Mbed TLS, so it can't verify an Ed25519 host key: the SSH server needs an ECDSA or RSA host key.
Ed25519 client keys work.

## Testing

The tunnel tests need an SSH server that reaches Redis and PostgreSQL. The repository's `docker-compose.yml` has one
(the `sshd` bastion on `127.0.0.1:2222`, user `tunnel`); [Engines](Engines.md#test-servers) explains how to start it.

```bash
Scripts/test-servers.sh
swift test --filter SSHTunnelTests
```

Without Docker, any sshd that accepts `.testing/ssh/id_ed25519` and reaches the services on its own `127.0.0.1`
works:

```bash
SSH_TEST_PORT=2200 SSH_TEST_USER=user SSH_TEST_SERVICES=local swift test --filter SSHTunnelTests
```

One test forwards through this Mac: it needs Remote Login on and the test key's public half in
`~/.ssh/authorized_keys`, and is skipped otherwise. Key handling, SFTP, commands and jump hosts are tested in the SSH
repository (`SSHKitTests`).
