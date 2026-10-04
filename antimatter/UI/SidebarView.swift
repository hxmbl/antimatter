import SwiftUI

struct SidebarView: View {
    @ObservedObject var store: NoteStore
    @Binding var isOpen: Bool

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(store.notes) { note in
                    noteRow(note)
                    Divider()
                        .background(.separator)
                        .opacity(0.3)
                }
                if !store.trash.isEmpty {
                    Divider().background(.separator).padding(.vertical, 4)
                    Text("The Void")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 2)
                    ForEach(store.trash.prefix(5)) { note in
                        Button(action: {
                            withAnimation { store.restore(note) }
                            isOpen = false
                        }) {
                            HStack {
                                Text(note.title)
                                    .font(.system(size: 11))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .foregroundStyle(.quaternary)
                                Spacer()
                                Image(systemName: "arrow.uturn.backward")
                                    .font(.system(size: 8, weight: .medium))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 4)
                            .padding(.horizontal, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(width: 160)
            .background(.ultraThinMaterial)
            .overlay(
                Rectangle()
                    .strokeBorder(.separator.opacity(0.3), lineWidth: 0.5)
            )

            Spacer()
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .transition(.move(edge: .leading).combined(with: .opacity))
    }

    /// Selecting a note and deleting it are two sibling controls.
    ///
    /// They used to be nested — the delete `Button` sat inside the row's own
    /// `Button` — and SwiftUI does not define how a nested button routes a
    /// click, so pressing the right-hand end of a *non*-active row deleted that
    /// note instead of switching to it. On top of that the hidden button was
    /// only `opacity(0)`, which still hit-tests, so it swallowed the click on
    /// the active row too.
    private func noteRow(_ note: Note) -> some View {
        Button(action: {
            store.activeNoteID = note.id
            isOpen = false
        }) {
            HStack {
                Text(note.title)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(note.id == store.activeNoteID ? Color.accentColor : .secondary)
                Spacer(minLength: 14)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .trailing) {
            if store.notes.count > 1 {
                Button(action: { withAnimation { store.delete(note) } }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 9)
                .opacity(note.id == store.activeNoteID ? 1 : 0)
                // `opacity(0)` alone keeps receiving clicks; taking the control
                // out of hit testing lets the row underneath take over, so a
                // click anywhere on an inactive row selects it again.
                .allowsHitTesting(note.id == store.activeNoteID)
            }
        }
    }
}