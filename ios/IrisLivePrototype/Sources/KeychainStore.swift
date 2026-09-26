//
//  KeychainStore.swift
//  IrisLivePrototype
//
//  Keeps two secrets across launches: the developer-fallback Gemini API key,
//  and the Iris Link pairing (host, port, device id, device credential).
//  Both live in the Keychain, readable only while the device is unlocked, and
//  never included in backups or iCloud Keychain sync (…ThisDeviceOnly).
//  Neither is ever logged, printed, or put in an error message.
//

import Foundation
import Security

enum KeychainStore {
    private static let service = "app.iris.liveprototype"
    private static let account = "gemini-api-key"
    private static let pairingAccount = "iris-link-pairing"

    private static func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static var baseQuery: [String: Any] { query(account: account) }

    private static func loadData(account: String) -> Data? {
        var q = query(account: account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return data
    }

    @discardableResult
    private static func saveData(_ data: Data, account: String) -> Bool {
        SecItemDelete(query(account: account) as CFDictionary)
        var attributes = query(account: account)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    // MARK: Iris Link pairing

    static func loadPairing() -> PairedDesktop? {
        guard let data = loadData(account: pairingAccount) else { return nil }
        return try? JSONDecoder().decode(PairedDesktop.self, from: data)
    }

    @discardableResult
    static func savePairing(_ pairing: PairedDesktop) -> Bool {
        guard let data = try? JSONEncoder().encode(pairing) else { return false }
        return saveData(data, account: pairingAccount)
    }

    static func deletePairing() {
        SecItemDelete(query(account: pairingAccount) as CFDictionary)
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
