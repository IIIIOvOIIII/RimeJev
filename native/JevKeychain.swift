import Foundation
import Security

/// Synchronous Keychain operations: callers must run every method off the main thread.
enum JevKeychain {
    // Stable generic-password identity shared by settings and the runtime launcher.
    static let service = "RimeJev"
    static let account = "Jev API"
    // Matches credentials.py; leaves room for JSON escaping in the 4 KiB pipe payload.
    static let maxAPIKeyBytes = 2_000

    enum Failure: Error, LocalizedError {
        case security(OSStatus)
        case invalidValue

        var errorDescription: String? { "credential_unavailable" }
    }

    /// Instance injection keeps offline tests away from the user's actual Keychain.
    struct SecurityAPI {
        let copyMatching: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
        let add: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
        let update: (CFDictionary, CFDictionary) -> OSStatus
        let delete: (CFDictionary) -> OSStatus

        static let live = SecurityAPI(
            copyMatching: SecItemCopyMatching,
            add: SecItemAdd,
            update: SecItemUpdate,
            delete: SecItemDelete
        )
    }

    struct Store {
        let api: SecurityAPI

        private var query: [String: Any] {
            [kSecClass as String: kSecClassGenericPassword,
             kSecAttrService as String: service,
             kSecAttrAccount as String: account]
        }

        func hasKey() -> Bool {
            var attributes = query
            attributes[kSecMatchLimit as String] = kSecMatchLimitOne
            attributes[kSecReturnAttributes as String] = true
            return api.copyMatching(attributes as CFDictionary, nil) == errSecSuccess
        }

        func read() throws -> String {
            var attributes = query
            attributes[kSecMatchLimit as String] = kSecMatchLimitOne
            attributes[kSecReturnData as String] = true
            var result: CFTypeRef?
            let status = api.copyMatching(attributes as CFDictionary, &result)
            guard status == errSecSuccess else { throw Failure.security(status) }
            guard let data = result as? Data,
                  let value = String(data: data, encoding: .utf8),
                  Self.isValid(value) else { throw Failure.invalidValue }
            return value
        }

        func save(_ value: String) throws {
            guard Self.isValid(value) else { throw Failure.invalidValue }
            let update = [kSecValueData as String: Data(value.utf8)]
            var status = api.update(query as CFDictionary, update as CFDictionary)
            if status == errSecItemNotFound {
                let attributes = query.merging(update) { _, value in value }
                status = api.add(attributes as CFDictionary, nil)
                if status == errSecDuplicateItem {
                    status = api.update(query as CFDictionary, update as CFDictionary)
                }
            }
            guard status == errSecSuccess else { throw Failure.security(status) }
        }

        func delete() throws {
            let status = api.delete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw Failure.security(status)
            }
        }

        private static func isValid(_ value: String) -> Bool {
            !value.isEmpty && value.utf8.count <= maxAPIKeyBytes
                && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
                && !value.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
        }
    }

    private static let store = Store(api: .live)

    static func hasKey() -> Bool { store.hasKey() }
    static func read() throws -> String { try store.read() }
    static func save(_ value: String) throws { try store.save(value) }
    static func delete() throws { try store.delete() }
}
