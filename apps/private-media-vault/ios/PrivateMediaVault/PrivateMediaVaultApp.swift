import SwiftUI

@main
struct PrivateMediaVaultApp: App {
    @State private var model = VaultModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .onAppear { AssistantRuntime.attach(model) }
        }
    }
}
