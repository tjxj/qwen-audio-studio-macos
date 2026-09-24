import Foundation
import Security

public struct NativeCredentials: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let apiKey: String
    public let workspaceID: String
    public init(apiKey: String, workspaceID: String) {
        self.apiKey = apiKey; self.workspaceID = workspaceID
    }
    public var description: String { "NativeCredentials(<redacted>)" }
    public var debugDescription: String { description }
}

public enum CredentialError: Error, LocalizedError, Sendable {
    case missing, invalidWorkspace, keychainFailure
    public var errorDescription: String? {
        switch self {
        case .missing: "请在设置中填写 API Key 和 Workspace ID。"
        case .invalidWorkspace: "Workspace ID 格式无效。"
        case .keychainFailure: "钥匙串操作失败；请检查本机权限。"
        }
    }
}

public protocol CredentialProviding: Sendable {
    func load() throws -> NativeCredentials
}

protocol KeychainItemAccess: Sendable {
    func read(service: String, account: String) throws -> String?
    func write(_ value: String, service: String, account: String) throws
}

private struct SystemKeychainItems: KeychainItemAccess {
    private func query(_ service: String, account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
    func read(service: String, account: String) throws -> String? {
        var q = query(service, account: account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { throw CredentialError.keychainFailure }
        return value
    }
    func write(_ value: String, service: String, account: String) throws {
        let data = Data(value.utf8)
        let status = SecItemUpdate(query(service, account: account) as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw CredentialError.keychainFailure }
        var q = query(service, account: account)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw CredentialError.keychainFailure }
    }
}

/// Native items are independent, so editing one field never removes the other.
public struct NativeCredentialStore: CredentialProviding {
    public static let apiKeyService = "QwenAudioStudio.Native.APIKey"
    public static let workspaceService = "QwenAudioStudio.Native.WorkspaceID"
    private static let legacyAPIKeyService = "QwenAudioStudio.DashScopeAPIKey"
    private static let legacyWorkspaceService = "QwenAudioStudio.WorkspaceID"
    private let account: String
    private let apiKeyService: String
    private let workspaceService: String
    private let items: any KeychainItemAccess

    public init(account: String = NSUserName()) {
        self.account = account; self.apiKeyService = Self.apiKeyService; self.workspaceService = Self.workspaceService
        self.items = SystemKeychainItems()
    }
    init(account: String, servicePrefix: String) {
        self.account = account; self.apiKeyService = servicePrefix + ".APIKey"; self.workspaceService = servicePrefix + ".WorkspaceID"
        self.items = SystemKeychainItems()
    }
    init(account: String, servicePrefix: String, items: any KeychainItemAccess) {
        self.account = account; self.apiKeyService = servicePrefix + ".APIKey"; self.workspaceService = servicePrefix + ".WorkspaceID"
        self.items = items
    }

    public func load() throws -> NativeCredentials {
        guard let apiKey = try read(apiKeyService), !apiKey.isEmpty,
              let workspaceID = try read(workspaceService), !workspaceID.isEmpty else { throw CredentialError.missing }
        guard Self.validWorkspaceID(workspaceID) else { throw CredentialError.invalidWorkspace }
        return NativeCredentials(apiKey: apiKey, workspaceID: workspaceID)
    }

    public func hasAPIKey() throws -> Bool { try read(apiKeyService) != nil }
    public func workspaceID() throws -> String? { try read(workspaceService) }

    public func saveAPIKey(_ value: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CredentialError.missing }
        try write(value, service: apiKeyService)
    }
    public func saveWorkspaceID(_ value: String) throws {
        guard Self.validWorkspaceID(value) else { throw CredentialError.invalidWorkspace }
        try write(value, service: workspaceService)
    }

    /// Called only from an explicit Settings action. Legacy items are read only.
    public func importLegacy() throws -> (apiKey: Bool, workspaceID: Bool, failed: Bool) {
        var importedKey = false, importedWorkspace = false, failed = false
        do {
            if let oldKey = try read(Self.legacyAPIKeyService) {
                if oldKey.isEmpty { failed = true }
                else { do { try saveAPIKey(oldKey); importedKey = true } catch { failed = true } }
            }
        } catch { failed = true }
        do {
            if let oldWorkspace = try read(Self.legacyWorkspaceService) {
                if !Self.validWorkspaceID(oldWorkspace) { failed = true }
                else { do { try saveWorkspaceID(oldWorkspace); importedWorkspace = true } catch { failed = true } }
            }
        } catch { failed = true }
        return (importedKey, importedWorkspace, failed)
    }

    public static func validWorkspaceID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 253 && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45
        } && value.first != "-" && value.last != "-"
    }

    private func read(_ service: String) throws -> String? {
        try items.read(service: service, account: account)
    }
    private func write(_ value: String, service: String) throws {
        try items.write(value, service: service, account: account)
    }
}
