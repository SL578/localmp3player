import SwiftUI

extension View {
    /// Confirm-before-destroying prompt, driven by whichever item is waiting to
    /// be deleted.
    ///
    /// Deleting is the one thing in the app that can't be taken back — the
    /// imported file goes with the row — and a swipe is easy to perform by
    /// accident, so nothing deletes straight off the gesture. Callers set the
    /// binding from their swipe action and do the actual work in `perform`.
    ///
    /// **The swipe action that sets the binding must not carry
    /// `role: .destructive`.** The role is what tells UIKit the row is going
    /// away, and UIKit plays its row-removal animation the moment the action
    /// fires — before this dialog is even on screen. The row slides out and
    /// then pops back in behind the prompt, which reads as a delete that got
    /// undone. Setting the binding destroys nothing, so the row stays put and
    /// `.tint(.red)` carries the meaning on its own. A full swipe still fires
    /// the action; only the removal animation goes.
    ///
    /// Actions that *do* remove their row on the spot — detaching a song from
    /// a playlist or a tag — keep the role, because there the animation is
    /// telling the truth.
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
