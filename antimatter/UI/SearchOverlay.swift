import SwiftUI

struct SearchResult: Identifiable {
    let id = UUID()
    let noteID: UUID
    let noteTitle: String
    let lineNumber: Int
    let lineText: String
    let matchRange: Range<String.Index>?
}

extension Notification.Name {
    static let searchJumpToLine = Notification.Name("searchJumpToLine")
    static let toggleSearchOverlay = Notification.Name("toggleSearchOverlay")
}

struct SearchOverlay: View {
    @Binding var isPresented: Bool
    @State private var query = ""
    @State private var results: [SearchResult] = []
    @State private var selectedIndex = 0
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search all notes...", text: $query)
                    .textFieldStyle(.plain)
                    .focused($isSearchFocused)
                    .onSubmit { jumpToSelected() }

                if !query.isEmpty {
                    Button {
                        query = ""
                        results = []
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    isPresented = false
                } label: {
                    Text("Esc")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.secondary.opacity(0.15))
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)
            }
            .padding(12)

            Divider()

            if results.isEmpty && !query.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("No results")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                            Button {
                                jumpTo(result)
                            } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(result.noteTitle)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Text(result.lineText)
                                            .font(.system(.body, design: .rounded))
                                            .foregroundStyle(.primary)
                                            .lineLimit(2)
                                    }
                                    Spacer()
                                    Text("L\(result.lineNumber)")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(index == selectedIndex ? Color.accentColor.opacity(0.1) : Color.clear)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .frame(width: 400, height: 300)
        .background(.ultraThinMaterial)
        .cornerRadius(12)
        .onChange(of: query) { _, newQuery in
            performSearch(newQuery)
        }
        .onKeyPress(.escape) {
            isPresented = false
            return .handled
        }
        .onKeyPress(.upArrow) {
            selectedIndex = max(0, selectedIndex - 1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            selectedIndex = min(results.count - 1, selectedIndex + 1)
            return .handled
        }
        .onKeyPress(.return) {
            jumpToSelected()
            return .handled
        }
        .onAppear {
            isSearchFocused = true
        }
    }

    private func performSearch(_ query: String) {
        guard !query.isEmpty else {
            results = []
            return
        }
        let lowered = query.lowercased()
        var found: [SearchResult] = []

        for note in NoteStore.shared.notes {
            let lines = note.text.components(separatedBy: "\n")
            for (i, line) in lines.enumerated() {
                if line.lowercased().contains(lowered) {
                    found.append(SearchResult(
                        noteID: note.id,
                        noteTitle: note.title,
                        lineNumber: i + 1,
                        lineText: line.trimmingCharacters(in: .whitespaces),
                        matchRange: line.range(of: query, options: .caseInsensitive)
                    ))
                }
            }
        }

        results = found
        selectedIndex = 0
    }

    private func jumpTo(_ result: SearchResult) {
        NoteStore.shared.activeNoteID = result.noteID
        NotificationCenter.default.post(
            name: .searchJumpToLine,
            object: nil,
            userInfo: ["lineNumber": result.lineNumber]
        )
        isPresented = false
    }

    private func jumpToSelected() {
        guard selectedIndex < results.count else { return }
        jumpTo(results[selectedIndex])
    }
}
