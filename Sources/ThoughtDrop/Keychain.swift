import Foundation
import Security
import ThoughtCore

enum Keychain {
    static let openAI = "local.thoughtdrop.openai"
    static let gemini = "local.thoughtdrop.gemini"
    private static func baseQuery(_ service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "api-key"]
    }
    static func read(service: String = openAI) throws -> String {
        var query = baseQuery(service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = item as? Data else {
            throw ThoughtError.message("無法讀取鑰匙圈（\(status)）。")
        }
        return String(decoding: data, as: UTF8.self)
    }
    static func save(_ key: String, service: String = openAI) throws {
        let query = baseQuery(service)
        if key.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw ThoughtError.message("無法刪除金鑰（\(status)）。") }
            return
        }
        let data = Data(key.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw ThoughtError.message("無法儲存金鑰（\(status)）。") }
    }
}
