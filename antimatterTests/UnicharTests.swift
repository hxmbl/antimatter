import AppKit
import Foundation
import Testing
@testable import antimatter

/// `unichar` takes a *number*. Written as `unichar(".")` it falls through to
/// `LosslessStringConvertible`, cannot parse a non-numeric character, and
/// yields `nil`.
///
/// That is silent: `ns.character(at: i) == unichar(".")` compares a real
/// character against `nil`, which is false for every possible input. No
/// compiler warning, no crash — the comparison just never matches. It is what
/// made AutoReact's command detection return `false` for every input, so the
/// completion panel never opened at all.
///
/// These tests pin the two facts the fix depends on: the trap itself, and that
/// the marker comparisons now work.
struct UnicharTests {

    @Test func unicharFromACharacterStringIsNil() {
        // The trap, stated plainly so a future edit does not reintroduce it.
        #expect(unichar(".") == nil)
        #expect(unichar(":") == nil)
        #expect(unichar("$") == nil)
        #expect(unichar("(") == nil)
        #expect(unichar("-") == nil)
        #expect(unichar(" ") == nil)
        #expect(unichar("\n") == nil)
    }

    @Test func comparingACharacterAgainstThatNilIsAlwaysFalse() {
        let ns = ".:-$( " as NSString
        for index in 0..<ns.length {
            let matches = ns.character(at: index) == unichar(".")
            #expect(!matches, "index \(index) must not match")
        }
    }

    @Test func unicharFromANumberWorks() {
        #expect(unichar(46) == 46)
        #expect(unichar(58) == 58)
    }

    @Test func theRealComparisonsNowMatch() {
        let ns = ".sum" as NSString
        #expect(ns.character(at: 0) == 46)
        let dollar = "$(" as NSString
        #expect(dollar.character(at: 0) == 36)
        #expect(dollar.character(at: 1) == 40)
    }

    /// The user-visible consequence, checked through the real render path: a
    /// bullet marker is tinted with the accent colour, a numbered marker and a
    /// table divider keep the dim tint.
    @Test func listBulletsAreTintedAsBullets() {
        for bullet in ["- item", "* item", "+ item"] {
            #expect(isBulletMarkerTinted(bullet),
                    "\(bullet.debugDescription) should render as a bullet")
        }
        for notBullet in ["1. item", "-nospace"] {
            #expect(!isBulletMarkerTinted(notBullet),
                    "\(notBullet.debugDescription) should not render as a bullet")
        }
    }

    /// Renders `text` and reports whether its `.marker` element picked up the
    /// bullet tint rather than the dim one, so this fails if either side of
    /// `isListBulletMarker`'s `if` is wrong.
    private func isBulletMarkerTinted(_ text: String) -> Bool {
        let textView = NSTextView()
        textView.string = text
        Markdown.highlight(textView)
        guard let storage = textView.textStorage, storage.length > 0 else { return false }
        let color = storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        guard let color else { return false }
        return color == PaneStyle.accentNSColor.withAlphaComponent(0.85)
            && color != PaneStyle.secondaryTextNSColor
    }
}
