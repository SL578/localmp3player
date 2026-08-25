import SwiftUI

extension View {
    /// Confirm-before-destroying prompt, driven by whichever item is waiting to
    /// be deleted.
    ///
    /// Deleting is the one thing in the app that can't be taken back — the
    /// imported file goes with the row — and a swipe is easy to perform by
    /// accident, so nothing deletes straight off the gesture. Callers set the
    /// binding from their swipe action and do the actual work in `perform`.
    func confirmDelete<Item>(
        _ item: Binding<Item?>,
        title: (Item) -> String,
        message: String,
        confirmLabel: String = "Delete",
        perform: @escaping (Item) -> Void
    ) -> some View {
        confirmationDialog(
            item.wrappedValue.map(title) ?? "",
            isPresented: Binding(
                get: { item.wrappedValue != nil },
                set: { if !$0 { item.wrappedValue = nil } }
            ),
            titleVisibility: .visible,
            presenting: item.wrappedValue
        ) { target in
            Button(confirmLabel, role: .destructive) { perform(target) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(message)
        }
    }
}
