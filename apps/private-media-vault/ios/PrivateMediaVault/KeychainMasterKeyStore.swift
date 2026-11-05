import Foundation
import LocalAuthentication
import Security
import VaultCore

enum KeychainVaultError: Error, Equatable {
    case passcodeRequired
    case authenticationFailed
    case keychainFailed
    case malformedKey
}

struct KeychainMasterKeyStore {
    var service: String = VaultIdentity.keychainService
    var account: String = VaultIdentity.keychainAccount

    func loadOrCreate() async throws -> MasterKey {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        context.touchIDAuthenticationAllowableReuseDuration = 10
        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
            throw KeychainVaultError.passcodeRequired
        }
        do {
            try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Unlock your private media vault"
            )
        } catch {
            throw KeychainVaultError.authenticationFailed
        }
        if let existing = try read(context: context) {
            return existing
        }
        let created = MasterKey.generate()
        try save(created, context: context)
        return created
    }

    func replace(_ key: MasterKey) async throws {
        try delete()
        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = 10
        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
            throw KeychainVaultError.passcodeRequired
        }
        do {
            try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Save the restored vault key on this device"
            )
        } catch {
            throw KeychainVaultError.authenticationFailed
        }
        try save(key, context: context)
    }

    func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainVaultError.keychainFailed
        }
    }

    private func read(context: LAContext) throws -> MasterKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainVaultError.keychainFailed }
        guard let data = item as? Data, data.count == 32 else { throw KeychainVaultError.malformedKey }
        return MasterKey(data: data)
    }

    private func save(_ key: MasterKey, context: LAContext) throws {
        var accessError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
            [.userPresence],
            &accessError
        ) else {
            throw KeychainVaultError.passcodeRequired
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessControl as String: access,
            kSecUseAuthenticationContext as String: context,
            kSecValueData as String: Data(key.copyBytes()),
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainVaultError.keychainFailed }
    }
}
