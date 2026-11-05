import AppIntents

struct VaultStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Vault Status"
    static var description = IntentDescription("Reports whether the vault is unlocked and a session is on. It cannot unlock the vault or return media.")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let text = AssistantRuntime.model?.assistantStatusText()
            ?? "The vault app is not running. This does not unlock it."
        return .result(value: text)
    }
}

struct ListVaultAlbumsIntent: AppIntent {
    static var title: LocalizedStringResource = "List Vault Albums"
    static var description = IntentDescription("Returns album names while an assistant session is enabled. It does not return media.")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let text = AssistantRuntime.model?.assistantAlbumsText()
            ?? "The vault app is not running."
        return .result(value: text)
    }
}

struct SearchVaultMetadataIntent: AppIntent {
    static var title: LocalizedStringResource = "Search Vault Metadata"
    static var description = IntentDescription("Searches filenames and captions while a session is enabled. It does not return media bytes.")
    static var openAppWhenRun = false

    @Parameter(title: "Query")
    var query: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let model = AssistantRuntime.model else {
            return .result(value: "The vault app is not running.")
        }
        guard let names = model.sessionMetadata(query: query) else {
            return .result(value: "Metadata search is available only while the vault is unlocked and an assistant session is enabled.")
        }
        return .result(value: names.isEmpty ? "No metadata matches." : names.joined(separator: ", "))
    }
}

struct VaultShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: VaultStatusIntent(),
            phrases: ["Vault status in \(.applicationName)"]
        )
    }
}
