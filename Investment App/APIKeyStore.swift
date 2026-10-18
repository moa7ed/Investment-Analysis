//
//  APIKeyStore.swift
//  Investment App
//
//  Created by Mohammed Elrashidy on 10/10/2026.
//

import Foundation
import Security

/// Stores the Claude API key in the Keychain so it never ships inside the app bundle.
/// `nonisolated` because Keychain calls are thread-safe and the key is read from any context.
nonisolated enum APIKeyStore {
    private static let service = "Investment-App.ClaudeAPI"
    private static let account = "CLAUDE_API_KEY"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    /// The saved key, or nil if none has been entered.
    static var claudeKey: String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty
        else { return nil }
        return key
    }

    static var hasClaudeKey: Bool {
        claudeKey != nil
    }

    /// Saves (or replaces) the key. Returns false if the Keychain write failed.
    @discardableResult
    static func saveClaudeKey(_ key: String) -> Bool {
        let data = Data(key.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let addQuery = baseQuery.merging(attributes) { $1 }
            return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    static func deleteClaudeKey() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
