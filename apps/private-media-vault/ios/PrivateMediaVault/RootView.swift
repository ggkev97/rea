import SwiftUI

struct RootView: View {
    @Environment(VaultModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            if model.phase == .unlocked, !model.coverVisible {
                LibraryShell()
            } else {
                LockScreen()
            }
            if model.coverVisible, scenePhase != .active {
                NeutralCover()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            model.sceneChanged(phase)
        }
        .onOpenURL { url in
            guard model.phase == .unlocked else { return }
            model.importOpenIn(url)
        }
    }
}

struct NeutralCover: View {
    var body: some View {
        VaultScreen {
            VStack(spacing: 12) {
                Image(systemName: "lock.fill")
                    .font(.largeTitle)
                    .accessibilityHidden(true)
                Text(VaultIdentity.displayName)
                    .font(.title2.weight(.semibold))
            }
        }
        .accessibilityLabel("Private Media Vault is hidden")
    }
}

struct LockScreen: View {
    @Environment(VaultModel.self) private var model

    var body: some View {
        VaultScreen {
            VStack(spacing: 20) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 56))
                    .foregroundStyle(VaultTheme.accent)
                    .accessibilityHidden(true)
                Text(VaultIdentity.displayName)
                    .font(.largeTitle.weight(.semibold))
                Text("Face ID unlocks this vault, and the device passcode is the fallback. There is no separate vault password. Someone who knows the device passcode can open it.")
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 28)
                if case .failed(let message) = model.phase {
                    Text(message)
                        .font(.body)
                        .foregroundStyle(VaultTheme.warning)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                }
                if let statusMessage = model.statusMessage {
                    Text(statusMessage)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                }
                Button {
                    Task { await model.unlock() }
                } label: {
                    Text(model.phase == .unlocking ? "Waiting for Face ID or passcode" : "Unlock")
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(VaultTheme.accent)
                .disabled(model.phase == .unlocking)
                .padding(.horizontal, 28)
                .accessibilityHint("Uses Face ID or the device passcode")
            }
        }
    }
}
