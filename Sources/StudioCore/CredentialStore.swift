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
    
    // In-memory cache to completely eliminate repetitive macOS Keychain password prompts
    private nonisolated(unsafe) static var memoryCache: (apiKey: String?, workspaceID: String?) = (nil, nil)
    
    // Local application sandbox secure configuration fallback
    private static var secureConfigFile: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("QwenAudioStudioNative", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent(".secure_credentials.json")
    }

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
        // 1. Check memory cache first (instant, 0 prompts)
        if let key = Self.memoryCache.apiKey, !key.isEmpty,
           let ws = Self.memoryCache.workspaceID, !ws.isEmpty, Self.validWorkspaceID(ws) {
            return NativeCredentials(apiKey: key, workspaceID: ws)
        }

        // 2. Check local sandbox secure file
        if let local = Self.readLocalSecureFile(),
           let key = local["apiKey"], !key.isEmpty,
           let ws = local["workspaceID"], !ws.isEmpty, Self.validWorkspaceID(ws) {
            Self.memoryCache = (key, ws)
            return NativeCredentials(apiKey: key, workspaceID: ws)
        }

        throw CredentialError.missing
    }

    public func hasAPIKey() throws -> Bool {
        if let key = Self.memoryCache.apiKey, !key.isEmpty { return true }
        if let local = Self.readLocalSecureFile(), let key = local["apiKey"], !key.isEmpty {
            Self.memoryCache.apiKey = key
            return true
        }
        return false
    }

    public func workspaceID() throws -> String? {
        if let ws = Self.memoryCache.workspaceID, !ws.isEmpty { return ws }
        if let local = Self.readLocalSecureFile(), let ws = local["workspaceID"], !ws.isEmpty {
            Self.memoryCache.workspaceID = ws
            return ws
        }
        return nil
    }

    public func saveAPIKey(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CredentialError.missing }
        Self.memoryCache.apiKey = trimmed
        var current = Self.readLocalSecureFile() ?? [:]
        current["apiKey"] = trimmed
        Self.writeLocalSecureFile(apiKey: trimmed, workspaceID: current["workspaceID"])
    }

    public func saveWorkspaceID(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validWorkspaceID(trimmed) else { throw CredentialError.invalidWorkspace }
        Self.memoryCache.workspaceID = trimmed
        var current = Self.readLocalSecureFile() ?? [:]
        current["workspaceID"] = trimmed
        Self.writeLocalSecureFile(apiKey: current["apiKey"], workspaceID: trimmed)
    }

    private static func readLocalSecureFile() -> [String: String]? {
        guard let data = try? Data(contentsOf: secureConfigFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return nil }
        return json
    }

    private static func writeLocalSecureFile(apiKey: String?, workspaceID: String?) {
        var dict: [String: String] = [:]
        if let apiKey { dict["apiKey"] = apiKey }
        if let workspaceID { dict["workspaceID"] = workspaceID }
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return }
        try? data.write(to: secureConfigFile, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: secureConfigFile.path)
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
