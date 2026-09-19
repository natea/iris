//
//  KeychainStore.swift
//  IrisLivePrototype
//
//  Keeps the prototype's Gemini API key across launches. Stored in the
//  Keychain, readable only while the device is unlocked, and never included in
//  backups or iCloud Keychain sync (…ThisDeviceOnly). Never logged.
//

import Foundation
import Security

enum KeychainStore {
    private static let service = "app.iris.liveprototype"
    private static let account = "gemini-api-key"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func loadKey() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func saveKey(_ key: String) -> Bool {
        SecItemDelete(baseQuery as CFDictionary)
        var attributes = baseQuery
        attributes[kSecValueData as String] = Data(key.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    static func deleteKey() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
