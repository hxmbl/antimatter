import SwiftUI

struct SidebarView: View {
    @ObservedObject private var store = NoteStore.shared
    @Binding var isOpen: Bool

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(store.notes) { note in
                    Button(action: {
                        store.activeNoteID = note.id
                        isOpen = false
                    }) {
                        Text(note.title)
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .foregroundStyle(note.id == store.activeNoteID ? Color.accentColor : .secondary)
                            .padding(.vertical, 4)
                            .padding(.horizontal, 10)
                    }
                    .buttonStyle(.plain)
                    Divider()
                        .background(.separator)
                        .opacity(0.3)
                }
            }
            .frame(width: 140)
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
