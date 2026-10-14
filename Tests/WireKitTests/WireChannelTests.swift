import Foundation
import Testing
import WireKit

/// A transport for a `WireChannel` that answers every line it's sent with the line reversed, on its own thread,
/// the way an SSH session's thread carries a channel.
private final class ReversingTransport: @unchecked Sendable {
  let channel: WireChannel
  private let woken = DispatchSemaphore(value: 0)
  private var pending: [UInt8] = []

  init() {
    let woken = self.woken
    channel = WireChannel { woken.signal() }
    Thread.detachNewThread { [self] in run() }
  }

  private func run() {
    while !channel.isClosedByApp {
      _ = woken.wait(timeout: .now() + 0.1)
      pending += channel.takeOutbound()
      while let newline = pending.firstIndex(of: 10) {
        let line = pending[..<newline]
        pending.removeFirst(newline + 1)
        if line.elementsEqual("quit".utf8) {
          channel.finish()
          return
        }
        channel.deliver(Array(line.reversed()) + [13, 10])
      }
    }
  }
}

struct WireChannelTests {
  @Test func carriesBytesBothWays() async throws {
    let transport = ReversingTransport()
    let wire = WireConnection(stream: transport.channel)
    try await wire.send(Array("hello\nwire\n".utf8))
    #expect(try await wire.readLine() == "olleh")
    #expect(try await wire.readLine() == "eriw")
    let long = String(repeating: "abc", count: 100_000)
    try await wire.send(Array((long + "\n").utf8))
    #expect(try await wire.readLine() == String(long.reversed()))
    wire.close()
    #expect(!wire.isOpen)
    await #expect(throws: WireError.closed) { try await wire.send([1]) }
  }

  @Test func theAppReadsWhatArrivedBeforeTheEnd() async throws {
    let transport = ReversingTransport()
    let wire = WireConnection(stream: transport.channel)
    try await wire.send(Array("one\nquit\n".utf8))
    #expect(try await wire.readLine() == "eno")
    await #expect(throws: WireError.closed) { try await wire.readLine() }
  }

  @Test func aBrokenTransportReportsWhy() async throws {
    let channel = WireChannel {}
    channel.deliver(Array("last".utf8))
    channel.finish(.connectionFailed("the SSH connection dropped"))
    let wire = WireConnection(stream: channel)
    #expect(try await wire.read(exactly: 4) == Array("last".utf8))
    await #expect(throws: WireError.connectionFailed("the SSH connection dropped")) { try await wire.read(exactly: 1) }
  }

  @Test func stopsAskingForMoreWhileTheAppIsBehind() async throws {
    let channel = WireChannel {}
    channel.deliver([UInt8](repeating: 1, count: WireChannel.inboundLimit))
    #expect(!channel.wantsInbound)
    _ = try await channel.receive()
    #expect(channel.wantsInbound)
  }
}
