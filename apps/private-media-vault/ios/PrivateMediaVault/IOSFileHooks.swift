import Foundation
import VaultCore

struct IOSFileHooks: VaultFileHooks {
    func didCreate(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var copy = url
        try copy.setResourceValues(values)
    }
}
