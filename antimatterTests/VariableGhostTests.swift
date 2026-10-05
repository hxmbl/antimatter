import AppKit
import Foundation
import Testing
@testable import antimatter

/// The live ghost values drawn beside a `:name = $(...)` line.
///
/// These are resolved from the whole note — a `VariableTable.scan` plus one
/// `evaluateValue` per interpolation. `draw(_:)` runs on every `CADisplayLink`
/// frame of a caret hop and on every blink tick, and `60ceb2c` made typing
/// animate again, so resolving unconditionally turned each keystroke into
/// several full-note resolves. The cache is what prevents that.
struct VariableGhostTests {

    private func laidOutView(text: String) -> PaneTextView {
        let view = PaneTextView()
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 4000)
        view.font = .systemFont(ofSize: 13)
        view.textContainerInset = NSSize(width: 0, height: 0)
        view.isHorizontallyResizable = false
        if let container = view.textContainer {
            container.widthTracksTextView = true
            container.containerSize = NSSize(width: view.frame.width, height: 0)
            container.lineFragmentPadding = 0
        }
        view.string = text
        if let container = view.textContainer {
            view.layoutManager?.ensureLayout(for: container)
        }
        return view
    }

    /// Ghosts come from `$()` interpolations on `:name = …` definition lines.
    private let note = """
    :plain = 4 * 12
    :total = $(.sum 10 20 30)
    :broken = $(1 / 0)
    :doubled = $(2 + 2)
    prose with $(1 + 1) in it
    """

    // MARK: Resolution

    @Test func interpolationValuesBecomeGhosts() {
        let view = laidOutView(text: note)
        let texts = view.resolveGhostsForTesting().map(\.text)
        #expect(texts.contains("60"), "`:total` should ghost the aggregate")
        #expect(texts.contains("4"), "`:doubled` should ghost its value")
    }

    /// Only `:name = …` definition lines get a ghost. A bare `$()` in prose,
    /// and a definition whose value is not finite, do not. `:plain` has no
    /// interpolation at all, so it has nothing to draw.
    @Test func onlyDefinitionLinesWithFiniteValuesGhost() {
        let view = laidOutView(text: note)
        let ghosts = view.resolveGhostsForTesting()
        let lines = ghosts.map { ((note as NSString).substring(with: $0.lineRange) as NSString)
            .trimmingCharacters(in: .whitespacesAndNewlines) }
        for line in lines {
            #expect(line.hasPrefix(":"), "ghosted a non-definition line: \(line)")
            #expect(line.contains(" = "), "ghosted a line with no definition: \(line)")
        }
        #expect(!ghosts.contains { $0.text.lowercased().contains("inf")
                                || $0.text.lowercased().contains("nan") },
                "a non-finite value must not ghost")
        // Four interpolations exist; the prose one and the 1/0 one drop out.
        #expect(ghosts.count == 2, "got \(lines)")
    }

    @Test func aNoteWithNoInterpolationsHasNoGhosts() {
        let view = laidOutView(text: ":price = 4 * 12\njust prose")
        #expect(view.resolveGhostsForTesting().isEmpty)
    }

    // MARK: Caching

    /// The point of the cache: repeated draws over unchanged text resolve once.
    @Test func repeatedResolvesOverUnchangedTextHitTheCache() {
        let view = laidOutView(text: note)
        view.resolveGhostsForTesting()
        let afterFirst = view.ghostResolveCountForTesting
        for _ in 0..<50 { view.resolveGhostsForTesting() }
        #expect(view.ghostResolveCountForTesting == afterFirst,
                "50 resolves of identical text must not re-scan the note")
    }

    /// Editing invalidates: the new text must be resolved, and the values must
    /// be the new ones.
    @Test func anEditInvalidatesTheCache() {
        let view = laidOutView(text: ":total = $(.sum 10 20 30)")
        #expect(view.resolveGhostsForTesting().map(\.text).contains("60"))

        view.string = ":total = $(.sum 1 2 3)"
        view.didChangeText()
        let texts = view.resolveGhostsForTesting().map(\.text)
        #expect(texts.contains("6"), "the edited definition should ghost 6")
        #expect(!texts.contains("60"), "the stale 60 should be gone")
    }

    /// A reload assigns `.string =`, which does not post `didChangeText`, so
    /// the key comparison is the backstop that keeps the cache honest.
    @Test func aDirectStringAssignmentStillInvalidates() {
        let view = laidOutView(text: ":total = $(.sum 10 20 30)")
        view.resolveGhostsForTesting()
        view.string = ":total = $(.sum 100 200 300)"
        let texts = view.resolveGhostsForTesting().map(\.text)
        #expect(texts.contains("600"))
        #expect(!texts.contains("60"))
    }

    @Test func theCacheIsEmptyBeforeAnythingIsDrawn() {
        let view = laidOutView(text: note)
        #expect(view.ghostCacheForTesting.isEmpty)
        #expect(view.ghostResolveCountForTesting == 0)
    }
}
