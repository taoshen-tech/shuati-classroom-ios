import Foundation
import Security

@MainActor
final class AppEnvironment {
    static let shared = AppEnvironment()

    private let defaults = UserDefaults.standard
    private let configurationKey = "app.server.configuration.v2"
    private let tokenAccount = "alist.token"
    private let passwordAccount = "alist.password"

    private(set) var configuration: ServerConfiguration
    lazy var studyStore = StudyStore(environment: self)

    private init() {
        if let data = defaults.data(forKey: configurationKey),
           let saved = try? JSONDecoder().decode(ServerConfiguration.self, from: data) {
            configuration = saved
        } else {
            configuration = ServerConfiguration()
        }
    }

    var token: String { Keychain.read(account: tokenAccount) ?? "" }
    var isLoggedIn: Bool { configuration.isValid && !token.isEmpty }
    var api: AlistAPIClient { AlistAPIClient(configuration: configuration, token: token) }

    func updateConfiguration(_ value: ServerConfiguration) {
        configuration = value
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: configurationKey)
        }
    }

    func completeLogin(configuration value: ServerConfiguration, password: String, token: String) {
        updateConfiguration(value)
        Keychain.save(token, account: tokenAccount)
        Keychain.save(password, account: passwordAccount)
    }

    func logout() {
        Keychain.delete(account: tokenAccount)
        Keychain.delete(account: passwordAccount)
    }
}

enum Keychain {
    private static let service = "com.nuownqyyy886.ct1218.credentials"

    static func save(_ value: String, account: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }

    static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
