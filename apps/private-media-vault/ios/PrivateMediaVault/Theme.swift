import SwiftUI

enum VaultTheme {
    static let background = Color(red: 0.043, green: 0.051, blue: 0.063)
    static let card = Color(red: 0.086, green: 0.102, blue: 0.125)
    static let accent = Color(red: 0.561, green: 0.722, blue: 0.839)
    static let warning = Color(red: 0.86, green: 0.55, blue: 0.42)
}

struct VaultScreen<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(VaultTheme.background.ignoresSafeArea())
            .foregroundStyle(.white)
    }
}
