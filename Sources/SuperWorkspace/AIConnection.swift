import Foundation
import Security

struct AIEndpoint: Sendable {
    let url: URL
    let isLoopback: Bool
    var baseURL: URL { url.deletingLastPathComponent().deletingLastPathComponent() }

    init(_ baseURL: String) throws {
        guard var parts = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else {
            throw AIConnectionError.invalidURL
        }
        let ipv4Loopback = [127, 0, 0, 1].map(String.init).joined(separator: ".")
        let local = ["localhost", ipv4Loopback, "::1", "[::1]"].contains(host)
        guard parts.scheme?.lowercased() == "https" || (local && parts.scheme?.lowercased() == "http") else {
            throw AIConnectionError.invalidURL
        }
        parts.scheme = parts.scheme?.lowercased()
        parts.host = host
        while parts.percentEncodedPath.hasSuffix("/") { parts.percentEncodedPath.removeLast() }
        if !parts.percentEncodedPath.hasSuffix("/chat/completions") {
            parts.percentEncodedPath += "/chat/completions"
        }
        guard let url = parts.url else { throw AIConnectionError.invalidURL }
        self.url = url
        isLoopback = local
    }
}

struct AIConnection: Sendable {
    let endpoint: AIEndpoint
    let model: String
    let key: String

    init(endpoint: AIEndpoint, model: String, key: String) throws {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { throw AIConnectionError.missingModel }
        guard (endpoint.isLoopback || !key.isEmpty), key.rangeOfCharacter(from: .newlines) == nil else {
            throw AIConnectionError.missingKey
        }
        self.endpoint = endpoint
        self.model = model
        self.key = key
    }
}

enum AIConnectionError: LocalizedError {
    case invalidURL, missingModel, missingKey, keychain

    var errorDescription: String? {
        switch self {
        case .invalidURL: "请输入有效的 HTTPS API 地址。本机地址可使用 HTTP。"
        case .missingModel: "请输入模型名称。"
        case .missingKey: "请输入有效的 API 密钥。"
        case .keychain: "无法访问钥匙串中的 API 密钥。"
        }
    }
}

enum AIKeychain {
    private static func query(_ endpoint: AIEndpoint) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.superworkspace.app.ai-api",
         kSecAttrAccount as String: endpoint.url.absoluteString]
    }

    static func read(_ endpoint: AIEndpoint) throws -> String? {
        var attributes = query(endpoint)
        attributes[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else { throw AIConnectionError.keychain }
        return key
    }

    static func save(_ key: String, for endpoint: AIEndpoint) throws {
        var attributes = query(endpoint)
        let data = Data(key.utf8)
        let status = SecItemUpdate(attributes as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            attributes[kSecValueData as String] = data
            guard SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess else { throw AIConnectionError.keychain }
        } else if status != errSecSuccess {
            throw AIConnectionError.keychain
        }
    }

    static func remove(_ endpoint: AIEndpoint) throws {
        let status = SecItemDelete(query(endpoint) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AIConnectionError.keychain }
    }
}
