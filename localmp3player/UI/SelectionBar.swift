import SwiftUI

/// The bar that appears under a list while a selection is being made.
///
/// Four screens grew their own copy of this, drifting apart in spacing and in
/// whether the count could wrap. Only the actions are ever different, so only
/// the actions are passed in.
struct SelectionBar<Actions: View>: View {
    @Environment(\.uiMode) private var uiMode
    @Environment(\.theme) private var theme

    let count: Int
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(spacing: 4) {
            Text("\(count) selected")
                .font(.subheadline)
                .lineLimit(1)
            Spacer(minLength: 8)
            actions
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .modePanelBackground(uiMode, theme: theme)
    }
}

/// One icon-only button in a bottom selection bar. Shared so the bars in the
/// library and inside a tag are the same size and read the same way.
struct SelectionAction: View {
    let title: String
    let systemImage: String
    var role: ButtonRole?
    let perform: () -> Void

    init(_ title: String, systemImage: String, role: ButtonRole? = nil, perform: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.role = role
        self.perform = perform
    }

    var body: some View {
        Button(role: role, action: perform) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .frame(width: 44, height: 30)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(title)
    }
}
