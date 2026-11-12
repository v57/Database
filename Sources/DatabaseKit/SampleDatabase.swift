import Foundation
import SQLiteKit
import WireKit

/// A small shop in a SQLite file, made on the device, so Database can be tried with no server and no file of one's
/// own (App Review, TestFlight, a first look): customers, products, orders with their items, refunds and a monthly
/// revenue view, joined by foreign keys. The rows are made up and the same every time; the file is written only when
/// someone asks for it (Welcome ▸ Open the Sample Database) and nothing is downloaded.
public enum SampleDatabase {
  /// The file's name, which also tells a connection to the sample apart (`isSample(_:)`).
  public static let fileName = "Sample Shop.sqlite"
  /// The name the connection gets in the sidebar.
  public static let connectionName = "Sample Shop"

  /// Whether a SQLite path is a sample written by `write(to:)`, here or on another device (a connection syncs its
  /// path with the vault, and the sample is made again where it's missing).
  public static func isSample(_ path: String) -> Bool {
    let url = URL(fileURLWithPath: path)
    return url.lastPathComponent == fileName && url.deletingLastPathComponent().lastPathComponent == "Samples"
  }

  /// Writes the sample to `url`, replacing what's there.
  public static func write(to url: URL) async throws {
    let manager = FileManager.default
    try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    // Built beside the destination and moved in whole, so a failed run leaves no half-filled sample behind.
    let partial = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).sqlite")
    defer { try? manager.removeItem(at: partial) }
    let file = try SQLiteFile(path: partial.path)
    do {
      try await fill(file)
      await file.close()
    } catch {
      await file.close()
      throw error
    }
    if manager.fileExists(atPath: url.path) { try manager.removeItem(at: url) }
    try manager.moveItem(at: partial, to: url)
  }

  private static func fill(_ file: SQLiteFile) async throws {
    _ = try await file.query(schema)
    _ = try await file.execute("BEGIN")
    let shop = Shop()
    for customer in shop.customers {
      _ = try await file.execute(
        "INSERT INTO customers (id, name, email, city, joined_at) VALUES (?, ?, ?, ?, ?)",
        binds: [.int(customer.id), .text(customer.name), .text(customer.email), .text(customer.city), .text(customer.joined)])
    }
    for (index, product) in products.enumerated() {
      _ = try await file.execute(
        "INSERT INTO products (id, name, category, price, in_stock) VALUES (?, ?, ?, ?, ?)",
        binds: [.int(Int64(index + 1)), .text(product.name), .text(product.category), .double(product.price),
                .int(Int64((index * 17) % 60))])
    }
    for order in shop.orders {
      _ = try await file.execute(
        "INSERT INTO orders (id, customer_id, status, items, total, created_at, note) VALUES (?, ?, ?, ?, ?, ?, ?)",
        binds: [.int(order.id), .int(order.customer), .text(order.status), .int(order.lines), .double(order.total),
                .text(order.created), order.note.map { .text($0) } ?? .null])
    }
    for item in shop.items {
      _ = try await file.execute(
        "INSERT INTO order_items (id, order_id, product_id, quantity, price) VALUES (?, ?, ?, ?, ?)",
        binds: [.int(item.id), .int(item.order), .int(item.product), .int(item.quantity), .double(item.price)])
    }
    for (index, order) in shop.orders.filter({ $0.status == "refunded" }).enumerated() {
      _ = try await file.execute(
        "INSERT INTO refunds (id, order_id, amount, reason) VALUES (?, ?, ?, ?)",
        binds: [.int(Int64(index + 1)), .int(order.id), .double(order.total),
                .text(index % 2 == 0 ? "Changed mind" : "Arrived damaged")])
    }
    _ = try await file.execute("COMMIT")
  }

  private static let schema = """
    CREATE TABLE customers (
      id INTEGER PRIMARY KEY, name TEXT NOT NULL, email TEXT UNIQUE, city TEXT, joined_at TEXT);
    CREATE TABLE products (
      id INTEGER PRIMARY KEY, name TEXT NOT NULL, category TEXT, price REAL NOT NULL, in_stock INTEGER NOT NULL DEFAULT 0);
    CREATE TABLE orders (
      id INTEGER PRIMARY KEY, customer_id INTEGER NOT NULL REFERENCES customers(id),
      status TEXT NOT NULL CHECK (status IN ('pending', 'shipped', 'refunded', 'cancelled')),
      items INTEGER NOT NULL, total REAL NOT NULL, created_at TEXT NOT NULL, note TEXT);
    CREATE TABLE order_items (
      id INTEGER PRIMARY KEY, order_id INTEGER NOT NULL REFERENCES orders(id),
      product_id INTEGER NOT NULL REFERENCES products(id), quantity INTEGER NOT NULL, price REAL NOT NULL);
    CREATE TABLE refunds (
      id INTEGER PRIMARY KEY, order_id INTEGER NOT NULL REFERENCES orders(id), amount REAL NOT NULL, reason TEXT);
    CREATE INDEX orders_by_customer ON orders(customer_id);
    CREATE INDEX order_items_by_order ON order_items(order_id);
    CREATE VIEW monthly_revenue AS
      SELECT substr(created_at, 1, 7) AS month, count(*) AS orders, round(sum(total), 2) AS revenue
      FROM orders WHERE status = 'shipped' GROUP BY month ORDER BY month;
    """

  private static let products: [(name: String, category: String, price: Double)] = [
    ("Aurora Wireless Headphones", "Audio", 249), ("Lumen Desk Speaker", "Audio", 129), ("Drift Earbuds", "Audio", 89),
    ("Tidal Soundbar", "Audio", 399), ("Ember Turntable", "Audio", 319), ("Pocket Radio", "Audio", 59),
    ("Arc Desk Lamp", "Home", 79), ("Cove Kettle", "Home", 49), ("Slate Notebook", "Office", 19),
    ("Glide Pen", "Office", 9.5), ("Fern Planter", "Home", 29), ("Orbit Clock", "Home", 39),
  ]

  /// The made-up rows, from a fixed seed.
  private struct Shop {
    struct Customer { var id: Int64, name: String, email: String, city: String, joined: String }
    struct Order { var id: Int64, customer: Int64, status: String, lines: Int64, total: Double, created: String, note: String? }
    struct Item { var id: Int64, order: Int64, product: Int64, quantity: Int64, price: Double }

    var customers: [Customer] = []
    var orders: [Order] = []
    var items: [Item] = []

    init() {
      let first = ["Maya", "Liam", "Sofia", "Noah", "Aiko", "Omar", "Elena", "Lucas", "Grace", "Jonas", "Priya",
                   "Mateo", "Ines", "Tomasz", "Akosua", "Rafael", "Hana", "Diego", "Noor", "Lin"]
      let last = ["Okafor", "Chen", "Marino", "Fischer", "Tanaka", "Haddad", "Petrova", "Silva", "Mensah", "Berg",
                  "Nair", "Ruiz", "Costa", "Novak", "Boateng", "Moreau", "Kim", "Reyes", "Laine", "Wei"]
      let cities = ["Lisbon", "Oslo", "Milan", "Berlin", "Osaka", "Beirut", "Sofia", "Porto", "Accra", "Bergen"]
      let statuses = Array(repeating: "shipped", count: 6) + ["pending", "pending", "refunded", "cancelled"]
      let notes = ["Gift wrap, please", "Leave at the front desk", "Second delivery attempt"]
      var random = Random(seed: 57)
      let start = Date(timeIntervalSince1970: 1_767_225_600)  // 2026-01-01 00:00 UTC
      for index in 0..<40 {
        let firstName = first[index % first.count]
        customers.append(Customer(
          id: Int64(index + 1), name: "\(firstName) \(last[(index * 7) % last.count])",
          email: "\(firstName.lowercased())\(index)@example.com", city: cities[index % cities.count],
          joined: Self.date(start.addingTimeInterval(Double(index) * 86_400 * 2))))
      }
      for number in 0..<250 {
        let id = Int64(10_233 + number)
        let lines = random.next(1...4)
        var total = 0.0
        for _ in 0..<lines {
          let product = random.next(1...products.count)
          let quantity = random.next(1...3)
          let price = products[product - 1].price
          total += price * Double(quantity)
          items.append(Item(
            id: Int64(items.count + 1), order: id, product: Int64(product), quantity: Int64(quantity), price: price))
        }
        let created = start.addingTimeInterval(86_400 * 80 + Double(number) * 60 * 37 * 23)
        orders.append(Order(
          id: id, customer: Int64(random.next(1...40)), status: statuses[random.next(0...(statuses.count - 1))],
          lines: Int64(lines), total: (total * 100).rounded() / 100, created: Self.date(created),
          note: number % 23 == 5 ? notes[number % notes.count] : nil))
      }
    }

    static func date(_ date: Date) -> String {
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = TimeZone(identifier: "UTC")!
      let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
      return String(
        format: "%04d-%02d-%02d %02d:%02d:%02d", parts.year!, parts.month!, parts.day!, parts.hour!, parts.minute!,
        parts.second!)
    }
  }

  /// A small fixed-seed generator (SplitMix64), so the sample is the same on every device.
  private struct Random {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next(_ range: ClosedRange<Int>) -> Int {
      state &+= 0x9E37_79B9_7F4A_7C15
      var z = state
      z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
      z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
      z ^= z >> 31
      return range.lowerBound + Int(z % UInt64(range.count))
    }
  }
}
