import Foundation
import Security

/// Stores the session (server URL, email, access token) in the Keychain.
struct StoredSession: Codable, Equatable {
  var serverURL: URL
  var email: String
  var userName: String
  var accessToken: String
}

enum Keychain {
  private static let service = "ch.benn0r.immichmirror"
  private static let account = "session"

  static func load() -> StoredSession? {
    let q: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var out: CFTypeRef?
    guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data
    else { return nil }
    return try? JSONDecoder().decode(StoredSession.self, from: data)
  }

  static func save(_ s: StoredSession) {
    guard let data = try? JSONEncoder().encode(s) else { return }
    clear()
    let q: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      // Background sync must be able to read it while the phone is locked.
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
      kSecValueData as String: data,
    ]
    SecItemAdd(q as CFDictionary, nil)
  }

  static func clear() {
    let q: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    SecItemDelete(q as CFDictionary)
  }
}
