import Foundation
import SQLiteKit
import Testing
import WireKit

@testable import DatabaseKit

/// The sample shop (Welcome ▸ Open the Sample Database) is made on the device: no server, no download.
struct SampleDatabaseTests {
  @Test func writesTheSameShopEveryTime() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sample-\(UUID().uuidString)/Samples")
    defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
    let url = folder.appendingPathComponent(SampleDatabase.fileName)
    try await SampleDatabase.write(to: url)
    #expect(SampleDatabase.isSample(url.path))
    #expect(!SampleDatabase.isSample(folder.appendingPathComponent("Shop.sqlite").path))

    let file = try SQLiteFile(path: url.path, readOnly: true, create: false)
    let counts = try await file.execute(
      """
      SELECT (SELECT count(*) FROM customers), (SELECT count(*) FROM products), (SELECT count(*) FROM orders),
             (SELECT count(*) FROM order_items) > 250, (SELECT count(*) FROM refunds) > 0,
             (SELECT count(*) FROM monthly_revenue) > 0
      """)
    #expect(counts.rows.first == [.int(40), .int(12), .int(250), .int(1), .int(1), .int(1)])
    let orphans = try await file.execute("PRAGMA foreign_key_check")
    #expect(orphans.rows.isEmpty)
    let first = try await file.execute("SELECT id, total, created_at FROM orders ORDER BY id LIMIT 1")
    await file.close()

    // Written again (another device, or a sample whose file went missing): the same rows, and no leftovers.
    try await SampleDatabase.write(to: url)
    let again = try SQLiteFile(path: url.path, readOnly: true, create: false)
    #expect(try await again.execute("SELECT id, total, created_at FROM orders ORDER BY id LIMIT 1").rows == first.rows)
    await again.close()
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == [SampleDatabase.fileName])
  }

  @Test func opensThroughTheConnector() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sample-\(UUID().uuidString)/Samples")
    defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
    let url = folder.appendingPathComponent(SampleDatabase.fileName)
    try await SampleDatabase.write(to: url)
    let profile = ConnectionProfile(name: SampleDatabase.connectionName, engine: .sqlite, filePath: url.path)
    let (session, _) = try await Connector.connect(profile, credentials: Credentials())
    let tree = try await session.children(of: nil)
    #expect(!tree.isEmpty)
    await session.close()
  }
}
