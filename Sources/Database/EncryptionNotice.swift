import Foundation

/// The one place that explains the missing TLS support. The bundled C drivers
/// are built without encryption, so servers that require it — most cloud
/// database services — can't be opened. Every surface (pasted links, the
/// connection form, connect errors) shows this text, and once Database Pro
/// exists, setting `upgradeURL` adds the way there to all of them.
public enum EncryptionNotice {
  /// Where to get a version with encrypted connections; nil until there is
  /// one, which hides every "Get Database Pro" button and sentence.
  public static let upgradeURL: URL? = nil
  public static let upgradeName = "Database Pro"

  public static let title = "This server needs an encrypted connection"

  /// What happened and what works instead (plus the upgrade, once it exists).
  public static var message: String {
    let base =
      "Database connects without encryption (TLS), so it can’t open servers that require it. Most cloud database services do."
    guard upgradeURL != nil else {
      return base + " Servers on your own computer or local network work."
    }
    return base + " \(upgradeName) supports encrypted connections."
  }

  /// Hosted services that only accept encrypted connections. A failure
  /// talking to one of these is almost certainly the missing TLS, whatever
  /// the driver reports (often just a timeout or a closed connection).
  static let encryptedOnlyHostSuffixes = [
    ".mongodb.net",  // MongoDB Atlas
    ".supabase.co", ".supabase.com", ".pooler.supabase.com",
    ".neon.tech",
    ".upstash.io",
    ".redis-cloud.com", ".redislabs.com", ".redns.redis-cloud.com",
    ".rds.amazonaws.com", ".cache.amazonaws.com", ".docdb.amazonaws.com",
    ".postgres.database.azure.com", ".mongo.cosmos.azure.com", ".redis.cache.windows.net",
    ".aivencloud.com",
    ".render.com",
    ".railway.app", ".rlwy.net",
    ".cockroachlabs.cloud",
    ".ondigitalocean.com",
    ".timescale.com", ".tsdb.cloud.timescale.com",
    ".prisma.io",
    ".xata.sh",
  ]

  /// True for a host of a service known to require encryption.
  public static func isEncryptedOnly(host: String) -> Bool {
    let name = "." + host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      .trimmingCharacters(in: CharacterSet(charactersIn: "."))
    return encryptedOnlyHostSuffixes.contains { name.hasSuffix($0) }
  }
}
