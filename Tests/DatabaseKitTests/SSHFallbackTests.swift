import DatabaseKit
import Foundation
import SSHTunnel
import Testing

/// A connection's SSH server is tried at its fallback addresses (`SSHSettings.fallbackHosts`) when its address doesn't
/// answer. Needs any sshd on 127.0.0.1: `SSH_FALLBACK_TEST_PORT` (skipped otherwise). The profile remembers another
/// host key, so the test stops at the server's key: reaching it at all shows the fallback answered.
struct SSHFallbackTests {
  static let port = ProcessInfo.processInfo.environment["SSH_FALLBACK_TEST_PORT"].flatMap(Int.init)

  @Test func decodesProfilesSavedBeforeFallbacks() throws {
    let json = #"{"enabled":true,"host":"bastion","port":22,"user":"me","auth":"key"}"#
    let settings = try JSONDecoder().decode(SSHSettings.self, from: Data(json.utf8))
    #expect(settings.fallbackHosts.isEmpty)
    let again = try JSONDecoder().decode(
      SSHSettings.self, from: JSONEncoder().encode(SSHSettings(host: "a", fallbackHosts: ["b"])))
    #expect(again.fallbackHosts == ["b"])
  }

  @Test(.enabled(if: port != nil, "needs SSH_FALLBACK_TEST_PORT"))
  func reachesTheServerAtAFallback() async throws {
    var profile = ConnectionProfile(engine: .redis, host: "127.0.0.1", port: 6379)
    profile.ssh = SSHSettings(
      enabled: true, host: "unreachable.invalid", fallbackHosts: ["127.0.0.1"], port: Self.port!,
      user: NSUserName(), auth: .password, hostKeyFingerprint: "SHA256:someone-else")
    await #expect {
      try await Connector.connect(profile, credentials: Credentials(sshPassword: "unused"))
    } throws: { error in
      if case SSHTunnelError.hostKeyChanged = error { return true }
      return false
    }

    profile.ssh.fallbackHosts = []
    await #expect {
      try await Connector.connect(profile, credentials: Credentials(sshPassword: "unused"))
    } throws: { error in
      if case SSHTunnelError.connectFailed = error { return true }
      return false
    }
  }
}
