import Foundation
import Security
import SwiftUI

/// A saved Frigate server. The password lives in the Keychain.
struct ServerConfig: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var url: String
    var remoteURL: String?
    var username: String?
    var tintIndex: Int = 0

    var initial: String { String(name.trimmingCharacters(in: .whitespaces).first ?? "F").uppercased() }
    var tint: Color { Theme.tint(tintIndex) }

    var password: String? {
        get { Keychain.read(account: id.uuidString) }
        nonmutating set {
            if let newValue, !newValue.isEmpty { Keychain.write(newValue, account: id.uuidString) }
            else { Keychain.delete(account: id.uuidString) }
        }
    }

    /// Display form of the URL without scheme.
    static func displayAddress(_ raw: String) -> String {
        raw.replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// Accepts "host:port" or a full URL and returns a URL.
    static func normalizedURL(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") {
            // Port 8971 uses TLS by default on Frigate, but many installs serve it plain.
            s = "http://" + s
        }
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s), url.host != nil else { return nil }
        return url
    }
}

enum Keychain {
    private static let service = "nl.wiebenieuwenhuis.frigate.servers"

    static func write(_ value: String, account: String) {
        delete(account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
