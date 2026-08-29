import Foundation
import CMongoC

/// Bridge between the module's own BSON value type and libbson's `bson_t`.
///
/// libmongoc consumes and produces `bson_t` — the raw BSON wire format that
/// libbson owns. The module already has a spec-complete `BSON` value type with
/// a `BSONCodec` that encodes/decodes to/from that exact wire format. So the
/// bridge is pure serialization interchange: encode our `BSON` to the wire
/// bytes the codec emits, hand them to `bson_new_from_data`, and reverse the
/// process with `bson_get_data` / `BSONCodec.decode`. No element-by-element
/// libbson append/iterate is needed for the operations the facade performs.
enum BSONCMap {

  /// Encodes a `BSON` value into a newly allocated `bson_t`. The caller owns
  /// the pointer and must `bson_destroy` it. An empty document encodes as `{}`.
  static func encode(_ value: BSON) -> UnsafeMutablePointer<bson_t> {
    let data = BSONCodec.encode(value)
    if data.isEmpty { return bson_new()! }
    return data.withUnsafeBytes { raw in
      guard let base = raw.baseAddress else { return bson_new()! }
      return bson_new_from_data(base.assumingMemoryBound(to: UInt8.self), raw.count)
    }
  }

  /// Encodes a `Document` (the common case).
  static func encode(_ document: BSONDocument) -> UnsafeMutablePointer<bson_t> {
    encode(.document(document))
  }

  /// Decodes the wire bytes behind a `bson_t` back into a `BSON` value
  /// (a `.document` for the common case).
  static func decode(_ bson: UnsafeMutablePointer<bson_t>) throws -> BSON {
    let len = Int(bson.pointee.len)
    guard let bytes = bson_get_data(bson) else {
      throw BSONError.invalid("bson_t has no backing data")
    }
    let data = Data(bytes: bytes, count: len)
    return try BSONCodec.decode(data)
  }
}
