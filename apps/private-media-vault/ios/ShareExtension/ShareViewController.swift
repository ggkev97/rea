import UIKit
import UniformTypeIdentifiers

/// Not part of the signed app. See README.md in this folder.
/// Copies only the files the user picked in the share sheet into an App Group
/// inbox. It does not read the vault, unlock it, delete anything, or export.
final class ShareViewController: UIViewController {
    private let groupID = "group.app.local.privatemediavault"

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let label = UILabel()
        label.numberOfLines = 0
        label.textAlignment = .center
        label.text = "Private Media Vault can only accept this share when an App Group is available. The free-team build does not include this extension."
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        copyAttachments()
    }

    private func copyAttachments() {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else {
            extensionContext?.cancelRequest(withError: ShareInboxError.appGroupUnavailable)
            return
        }
        let inbox = container.appendingPathComponent("InboxFromShare", isDirectory: true)
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let providers = (extensionContext?.inputItems as? [NSExtensionItem])?.flatMap { $0.attachments ?? [] } ?? []
        let group = DispatchGroup()
        for provider in providers {
            let type = provider.registeredTypeIdentifiers.first ?? UTType.data.identifier
            group.enter()
            provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                defer { group.leave() }
                guard let url else { return }
                let destination = inbox.appendingPathComponent(UUID().uuidString).appendingPathExtension(url.pathExtension)
                try? FileManager.default.copyItem(at: url, to: destination)
            }
        }
        group.notify(queue: .main) {
            self.extensionContext?.completeRequest(returningItems: nil)
        }
    }
}

enum ShareInboxError: Error {
    case appGroupUnavailable
}
