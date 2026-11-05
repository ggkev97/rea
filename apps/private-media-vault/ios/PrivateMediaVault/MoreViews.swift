import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct MoreView: View {
    @Environment(VaultModel.self) private var model

    var body: some View {
        List {
            NavigationLink("Search") { SearchView() }
            NavigationLink("Trash") { TrashView() }
            NavigationLink("Backup and restore") { BackupView() }
            NavigationLink("Assistant session") { AssistantView() }
            NavigationLink("Lock and privacy") { PrivacySettingsView() }
        }
        .scrollContentBackground(.hidden)
        .background(VaultTheme.background)
        .navigationTitle("More")
    }
}

struct SearchView: View {
    @Environment(VaultModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(model.searchResults()) { item in
            VStack(alignment: .leading) {
                Text(item.originalFilename)
                if !item.caption.isEmpty {
                    Text(item.caption).font(.caption).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
        }
        .searchable(text: $model.searchText, prompt: "Filename, caption, or album")
        .scrollContentBackground(.hidden)
        .background(VaultTheme.background)
        .navigationTitle("Search")
        .overlay {
            if model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView("Search encrypted captions", systemImage: "magnifyingglass", description: Text("Search runs after unlock, against metadata that stays encrypted on disk."))
            }
        }
    }
}

struct TrashView: View {
    @Environment(VaultModel.self) private var model

    var body: some View {
        List(model.trashedItems()) { item in
            HStack {
                Text(item.originalFilename)
                Spacer()
                Button("Restore") { model.restore([item.id]) }
                    .frame(minHeight: 44)
                Button("Delete") { model.purge([item.id]) }
                    .frame(minHeight: 44)
            }
        }
        .scrollContentBackground(.hidden)
        .background(VaultTheme.background)
        .navigationTitle("Trash")
        .toolbar {
            if !model.trashedItems().isEmpty {
                Button("Empty") { model.purge(model.trashedItems().map(\.id)) }
            }
        }
    }
}

struct BackupView: View {
    @Environment(VaultModel.self) private var model
    @State private var showExporter = false
    @State private var showImporter = false
    @State private var recoveryText = ""
    @State private var confirmed = false

    var body: some View {
        Form {
            Section("Portable backup") {
                Text("The backup file does not contain the recovery key. Write the key down outside the phone. It is not copied into logs. A device backup cannot restore the vault key, because that key is stored as a this-device Keychain item.")
                Button("Create backup") {
                    do { try model.prepareBackup() }
                    catch { model.statusMessage = publicMessage(error) }
                }
                .frame(minHeight: 44)
            }
            if let display = model.recoveryKeyDisplay {
                Section("Recovery key") {
                    Text(display)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .accessibilityLabel("Recovery key")
                        .accessibilityHint("Write this down outside the phone. Copying it places it on the system pasteboard. It is not stored in the backup and it is not written to the vault log.")
                    Toggle("I wrote this key down outside the phone", isOn: $confirmed)
                    Button("Save the backup file") { showExporter = true }
                        .disabled(!confirmed)
                        .frame(minHeight: 44)
                    Button("Discard") { model.discardUnsavedBackup(); confirmed = false }
                        .frame(minHeight: 44)
                }
            }
            Section("Restore onto this phone") {
                Text("Restoring replaces the current vault and keeps the old folder until you delete it. Type the recovery key. A wrong key does not change the current vault.")
                SecureField("Recovery key", text: $recoveryText)
                Button("Choose backup file") { showImporter = true }
                    .frame(minHeight: 44)
            }
            if FileManager.default.fileExists(atPath: model.previousVaultDirectory.path) {
                Section("Previous copy") {
                    Button("Delete the previous vault copy") {
                        try? model.deletePreviousCopy()
                    }
                    .frame(minHeight: 44)
                }
            }
            if let statusMessage = model.statusMessage {
                Section { Text(statusMessage) }
            }
        }
        .scrollContentBackground(.hidden)
        .background(VaultTheme.background)
        .navigationTitle("Backup")
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.data]) { result in
            guard case .success(let url) = result else { return }
            let text = recoveryText
            Task {
                do {
                    try await model.restoreBackup(from: url, keyText: text)
                    recoveryText = ""
                } catch {
                    model.statusMessage = publicMessage(error)
                }
            }
        }
        .sheet(isPresented: $showExporter) {
            if let backupFile = model.backupFile {
                ExportBackupView(url: backupFile) {
                    shredFile(backupFile)
                    model.backupFile = nil
                    model.clearRecoveryDisplay()
                    showExporter = false
                    confirmed = false
                } cancelled: {
                    showExporter = false
                }
            }
        }
    }
}

struct ExportBackupView: UIViewControllerRepresentable {
    let url: URL
    var saved: () -> Void
    var cancelled: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(saved: saved, cancelled: cancelled) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let saved: () -> Void
        let cancelled: () -> Void
        init(saved: @escaping () -> Void, cancelled: @escaping () -> Void) {
            self.saved = saved
            self.cancelled = cancelled
        }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { saved() }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { cancelled() }
    }
}

struct AssistantView: View {
    @Environment(VaultModel.self) private var model
    @State private var minutes = 15
    @State private var loopback = false

    var body: some View {
        Form {
            Section("What this is") {
                Text("An assistant session lets Shortcuts, the in-app status actions, and an optional loopback port on this iPhone read album names and search captions. It cannot unlock, delete, export, or fetch media bytes. This build does not connect to Grok. A connection exists only after you point a client at a session you enabled and you have tested that client.")
            }
            Section("Session") {
                Stepper("Minutes: \(minutes)", value: $minutes, in: 5 ... 120, step: 5)
                Button("Enable session") {
                    _ = try? model.enableAssistant(minutes: minutes)
                }
                .frame(minHeight: 44)
                if let token = model.assistantToken {
                    Text(token)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                    Text("This pairing token is shown here so you can give it to a client you chose. It is not written to the vault log.")
                }
                Button("Revoke") { model.revokeAssistant(); loopback = false }
                    .frame(minHeight: 44)
            }
            Section("Loopback") {
                Toggle("Listen on 127.0.0.1 while this session is on", isOn: $loopback)
                    .onChange(of: loopback) { _, enabled in
                        model.setLoopback(enabled: enabled)
                    }
                if let address = model.loopbackAddress {
                    Text(address).font(.system(.body, design: .monospaced))
                    Text("Only a program on this iPhone can connect. The listener is not opened on the local network.")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(VaultTheme.background)
        .navigationTitle("Assistant")
    }
}

struct PrivacySettingsView: View {
    @Environment(VaultModel.self) private var model
    @State private var confirmErase = false

    var body: some View {
        Form {
            Section("Autolock") {
                Picker("When leaving the app", selection: lockSelection) {
                    Text("Immediately").tag("immediate")
                    Text("After 1 minute").tag("60")
                    Text("After 5 minutes").tag("300")
                    Text("Manual only").tag("manual")
                }
                Text("The app switcher shows a neutral lock screen. That does not stop a person from taking a screenshot while the vault is open, and this app does not pretend that it can.")
            }
            Section("Erase") {
                Button("Erase vault on this device") { confirmErase = true }
                    .frame(minHeight: 44)
            }
        }
        .scrollContentBackground(.hidden)
        .background(VaultTheme.background)
        .navigationTitle("Privacy")
        .confirmationDialog("Erase the vault on this device?", isPresented: $confirmErase, titleVisibility: .visible) {
            Button("Erase", role: .destructive) {
                Task { try? await model.eraseEverything() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the encrypted files and the device key. Without a portable backup and its recovery key, the media cannot be opened again.")
        }
    }

    private var lockSelection: Binding<String> {
        Binding(
            get: {
                switch model.autoLock {
                case .immediate: return "immediate"
                case .manual: return "manual"
                case .after(let interval): return String(Int(interval))
                }
            },
            set: { value in
                switch value {
                case "manual": model.setAutoLock(.manual)
                case "60": model.setAutoLock(.after(60))
                case "300": model.setAutoLock(.after(300))
                default: model.setAutoLock(.immediate)
                }
            }
        )
    }
}

struct LinkImportView: View {
    @Environment(VaultModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                Text("Paste an https link to a media file. This download uses an empty ephemeral session. It does not read Brave tabs, cookies, or private windows, and it does not try to pass a paywall or a bot check.")
                TextField("https://", text: $text)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                if let message { Text(message) }
            }
            .navigationTitle("Import link")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }.frame(minHeight: 44)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        let link = text
                        Task { message = await model.importLink(link) }
                    }
                    .frame(minHeight: 44)
                }
            }
        }
    }
}
