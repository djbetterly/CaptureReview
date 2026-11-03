// Keychain.swift – Capture Review
// Keeps the Supabase SECRET key in the Mac's Keychain instead of in the app's code,
// so the built app no longer contains it. The app asks for it once per Mac.

import Foundation
import Security

nonisolated enum Keychain {
    private static let service = "com.dbcapture.CaptureReview"
    private static let account = "supabase-secret-key"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// The stored secret key, or nil if it hasn't been entered on this Mac yet.
    static func readSecretKey() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let key = String(data: data, encoding: .utf8),
              !key.isEmpty else { return nil }
        return key
    }

    /// Saves (or replaces) the secret key. Returns false if the Keychain refused.
    @discardableResult
    static func saveSecretKey(_ key: String) -> Bool {
        let data = Data(key.utf8)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func deleteSecretKey() {
        SecItemDelete(query as CFDictionary)
    }
}
