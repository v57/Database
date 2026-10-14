import CryptoKit
import Foundation

/// Digests and key derivation used by the wire protocols' login handshakes.
public enum Digest {
  public static func sha1(_ data: [UInt8]) -> [UInt8] { Array(Insecure.SHA1.hash(data: data)) }
  public static func sha256(_ data: [UInt8]) -> [UInt8] { Array(SHA256.hash(data: data)) }
  public static func md5(_ data: [UInt8]) -> [UInt8] { Array(Insecure.MD5.hash(data: data)) }
  public static func md5Hex(_ data: [UInt8]) -> String { md5(data).hexString }

  public static func hmacSHA256(key: [UInt8], data: [UInt8]) -> [UInt8] {
    Array(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
  }

  public static func hmacSHA1(key: [UInt8], data: [UInt8]) -> [UInt8] {
    Array(HMAC<Insecure.SHA1>.authenticationCode(for: data, using: SymmetricKey(data: key)))
  }

  /// PBKDF2 with HMAC-SHA-256 or HMAC-SHA-1, one output block (the SCRAM "Hi" function).
  public static func pbkdf2(password: [UInt8], salt: [UInt8], iterations: Int, sha256: Bool) -> [UInt8] {
    let prf: ([UInt8], [UInt8]) -> [UInt8] = { key, data in
      sha256 ? hmacSHA256(key: key, data: data) : hmacSHA1(key: key, data: data)
    }
    var u = prf(password, salt + [0, 0, 0, 1])
    var result = u
    if iterations > 1 {
      for _ in 1..<iterations {
        u = prf(password, u)
        for i in 0..<result.count { result[i] ^= u[i] }
      }
    }
    return result
  }

  public static func xor(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] {
    zip(a, b).map { $0 ^ $1 }
  }

  public static func randomBytes(_ count: Int) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: count)
    for i in 0..<count { bytes[i] = UInt8.random(in: 0...255) }
    return bytes
  }
}

/// Client side of SCRAM (RFC 5802 / 7677), shared by PostgreSQL and MongoDB.
public struct SCRAMClient: Sendable {
  public enum Hash: Sendable { case sha1, sha256 }

  public let hash: Hash
  public let username: String
  /// The password as the protocol wants it hashed in (MongoDB SHA-1 pre-hashes it).
  private let password: String
  public let clientNonce: String
  private var clientFirstBare = ""
  private var serverSignature: [UInt8] = []

  public init(hash: Hash, username: String, password: String, nonce: String? = nil) {
    self.hash = hash
    self.username = username
    self.password = password
    self.clientNonce = nonce ?? Data(Digest.randomBytes(18)).base64EncodedString()
  }

  /// `n,,n=user,r=nonce`
  public mutating func clientFirstMessage() -> String {
    let escaped = username.replacingOccurrences(of: "=", with: "=3D").replacingOccurrences(of: ",", with: "=2C")
    clientFirstBare = "n=\(escaped),r=\(clientNonce)"
    return "n,," + clientFirstBare
  }

  /// Answers the server-first message with the client-final message.
  public mutating func clientFinalMessage(serverFirst: String) throws -> String {
    let fields = Self.parse(serverFirst)
    guard let nonce = fields["r"], nonce.hasPrefix(clientNonce),
      let saltText = fields["s"], let salt = Data(base64Encoded: saltText),
      let iterationsText = fields["i"], let iterations = Int(iterationsText)
    else { throw WireError.authenticationFailed("malformed SCRAM challenge") }

    let isSHA256 = hash == .sha256
    let saltedPassword = Digest.pbkdf2(
      password: Array(password.utf8), salt: [UInt8](salt), iterations: iterations, sha256: isSHA256)
    let hmac: ([UInt8], [UInt8]) -> [UInt8] = { key, data in
      isSHA256 ? Digest.hmacSHA256(key: key, data: data) : Digest.hmacSHA1(key: key, data: data)
    }
    let digest: ([UInt8]) -> [UInt8] = { isSHA256 ? Digest.sha256($0) : Digest.sha1($0) }

    let clientKey = hmac(saltedPassword, Array("Client Key".utf8))
    let storedKey = digest(clientKey)
    let withoutProof = "c=biws,r=\(nonce)"
    let authMessage = "\(clientFirstBare),\(serverFirst),\(withoutProof)"
    let clientSignature = hmac(storedKey, Array(authMessage.utf8))
    let proof = Digest.xor(clientKey, clientSignature)
    let serverKey = hmac(saltedPassword, Array("Server Key".utf8))
    serverSignature = hmac(serverKey, Array(authMessage.utf8))
    return "\(withoutProof),p=\(Data(proof).base64EncodedString())"
  }

  /// Checks the server's proof that it knows the password too.
  public func verify(serverFinal: String) throws {
    let fields = Self.parse(serverFinal)
    if let error = fields["e"] { throw WireError.authenticationFailed(error) }
    guard let v = fields["v"], let signature = Data(base64Encoded: v), [UInt8](signature) == serverSignature else {
      throw WireError.authenticationFailed("the server's SCRAM signature didn't match")
    }
  }

  static func parse(_ message: String) -> [String: String] {
    var out: [String: String] = [:]
    for part in message.split(separator: ",") {
      guard let eq = part.firstIndex(of: "=") else { continue }
      out[String(part[..<eq])] = String(part[part.index(after: eq)...])
    }
    return out
  }
}
