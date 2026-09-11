import SwiftUI

struct SidebarView: View {
    @ObservedObject var store: NoteStore
    @Binding var isOpen: Bool

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(store.notes) { note in
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
                            Spacer()
                            if store.notes.count > 1 {
                                Button(action: { withAnimation { store.delete(note) } }) {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(.tertiary)
                                }
                                .buttonStyle(.plain)
                                .opacity(note.id == store.activeNoteID ? 1 : 0)
                            }
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 10)
                    }
                    .buttonStyle(.plain)
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
}
