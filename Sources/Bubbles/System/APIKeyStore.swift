import BubblesCore
import Foundation
import Security

/// The AI keys (Claude, ChatGPT), each stored only in the macOS Keychain as its own generic password
/// (services «Bubbles.ClaudeAPIKey» / «Bubbles.OpenAIAPIKey»). Never logged, never written to disk or
/// UserDefaults, never shown back.
enum APIKeyStore {
    static let account = "default"

    enum StoreError: Error, Equatable {
        case empty
        case keychain(OSStatus)
    }

    private static func baseQuery(_ provider: ParserProvider) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: provider.keychainService,
         kSecAttrAccount as String: account]
    }

    /// The stored key, or nil when there is none (or the Keychain refused).
    static func load(_ provider: ParserProvider = .claude) -> String? {
        var query = baseQuery(provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty
        else { return nil }
        return key
    }

    /// True when a key is stored, without reading its value into memory.
    static func hasKey(_ provider: ParserProvider = .claude) -> Bool {
        var query = baseQuery(provider)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// Providers with a stored key.
    static var storedProviders: Set<ParserProvider> { Set(ParserProvider.allCases.filter { hasKey($0) }) }

    /// Who parses the dictation now (nil: the selected provider has no key — the plain tracker).
    static func activeProvider(selected: ParserProvider) -> ParserProvider? {
        ParserProvider.active(selected: selected, hasKey: { hasKey($0) })
    }

    /// The selected provider when it has no key but the other one has (the banner asks to connect it).
    static func missingProvider(selected: ParserProvider) -> ParserProvider? {
        ParserProvider.missingKey(selected: selected, hasKey: { hasKey($0) })
    }

    /// Replaces the stored key. Surrounding whitespace is trimmed; an empty key is refused.
    static func save(_ key: String, for provider: ParserProvider = .claude) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw StoreError.empty }
        let data = Data(trimmed.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(baseQuery(provider) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery(provider)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            add[kSecAttrLabel as String] = "Bubbles — \(provider.label) API key"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw StoreError.keychain(status) }
    }

    static func delete(_ provider: ParserProvider = .claude) {
        SecItemDelete(baseQuery(provider) as CFDictionary)
    }

    /// "Check" a typed key: the provider is asked; a key it does not refuse is saved (also when it could
    /// not be reached), a wrong one never is.
    static func checkAndSave(_ key: String, for provider: ParserProvider) async -> ClaudeKeyStatus {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let status = await ProviderKeyCheck.verify(provider, apiKey: trimmed)
        guard status != .invalid else { return status }
        do {
            try save(trimmed, for: provider)
        } catch {
            return .unavailable("Couldn't save the key to the Keychain")
        }
        return status
    }

    /// "Check" the stored key.
    static func checkStored(_ provider: ParserProvider) async -> ClaudeKeyStatus {
        guard let key = load(provider) else {
            return .unavailable("Can't read the key from the Keychain (this happens after a rebuild) — enter it again")
        }
        return await ProviderKeyCheck.verify(provider, apiKey: key)
    }
}
