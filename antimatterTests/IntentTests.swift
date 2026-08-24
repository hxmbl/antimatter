import Foundation
import Testing
@testable import antimatter

struct IntentTimerTests {

    @Test func bareNumberMeansMinutes() {
        #expect(IntentParser.parseTimer(".timer 5") == IntentParser.Timer(duration: 300, label: ""))
    }

    @Test func unitsAreHonoured() {
        #expect(IntentParser.parseTimer(".timer 90s")?.duration == 90)
        #expect(IntentParser.parseTimer(".timer 1.5m")?.duration == 90)
        #expect(IntentParser.parseTimer(".timer 2h")?.duration == 7_200)
        #expect(IntentParser.parseTimer(".timer 2000ms")?.duration == 2)
        #expect(IntentParser.parseTimer(".timer 2d")?.duration == 172_800)
    }

    @Test func compoundDurationsAccumulate() {
        #expect(IntentParser.parseTimer(".timer 1h 20m")?.duration == 4_800)
    }

    @Test func remainderBecomesTheLabel() {
        #expect(IntentParser.parseTimer(".timer 5 laundry") == IntentParser.Timer(duration: 300, label: "laundry"))
        #expect(IntentParser.parseTimer(".timer 1h 20m stand up") == IntentParser.Timer(duration: 4_800, label: "stand up"))
    }

    @Test func keywordIsCaseInsensitive() {
        #expect(IntentParser.parseTimer(".TIMER 5") != nil)
        #expect(IntentParser.parseTimer(".Timer 30s stretch") != nil)
    }

    @Test func nonTimersStayNil() {
        // A bare "timer" is just a word now; only the dot-command fires.
        for line in ["timer", "timer abc", "timer 0", "timers 5", "remind me at 5", "timer 5"] {
            #expect(IntentParser.parseTimer(line) == nil, "\(line) should not be a timer")
        }
    }
}

struct IntentCalculationTests {

    // MARK: Typed-equals commit form

    @Test func trailingEqualsCommits() {
        let pending = IntentParser.pendingCalculation("384 * 27 =")
        #expect(pending?.expression == "384 * 27")
        #expect(pending?.result == 10_368)
    }

    @Test func explicitEqualsOverridesTheDateHeuristic() {
        // The user asked for the answer, so give it.
        #expect(IntentParser.pendingCalculation("2026-08-22 =")?.result == 1_996)
    }

    @Test func identityRewritesAreSkipped() {
        #expect(IntentParser.pendingCalculation("-5 =") == nil)
        #expect(IntentParser.pendingCalculation("=") == nil)
        #expect(IntentParser.pendingCalculation("hello =") == nil)
    }

    // MARK: Whole-line arithmetic on return

    @Test func plainArithmeticParses() {
        #expect(IntentParser.parseCalculation("(2+3)*4")?.result == 20)
        #expect(IntentParser.parseCalculation("384 * 27")?.result == 10_368)
        #expect(IntentParser.parseCalculation("10 / 4")?.result == 2.5)
        #expect(IntentParser.parseCalculation("2^3^2")?.result == 512)
        #expect(IntentParser.parseCalculation("7 % 3")?.result == 1)
        #expect(IntentParser.parseCalculation("5 − 3")?.result == 2)
        #expect(IntentParser.parseCalculation("3 × 4 ÷ 2")?.result == 6)
    }

    @Test func datesAndProseNeverCalculate() {
        #expect(IntentParser.parseCalculation("2026-08-22") == nil)
        #expect(IntentParser.parseCalculation("8-22") == nil)
        #expect(IntentParser.parseCalculation("hello world") == nil)
        #expect(IntentParser.parseCalculation("TODO: investigate this") == nil)
    }

    @Test func degenerateInputsStayText() {
        #expect(IntentParser.parseCalculation("42") == nil)          // identity rewrite
        #expect(IntentParser.parseCalculation("1 / 0") == nil)       // not finite
        #expect(IntentParser.parseCalculation("") == nil)
        #expect(IntentParser.parseCalculation("(2+3") == nil)        // unbalanced
        #expect(IntentParser.parseCalculation("2(3+4)") == nil)      // no implicit multiplication
        #expect(IntentParser.parseCalculation("1.2.3 + 1") == nil)
    }

    // MARK: Formatting

    @Test func resultsFormatCleanly() {
        #expect(IntentParser.format(10_368) == "10368")
        #expect(IntentParser.format(2.5) == "2.5")
        #expect(IntentParser.format(0.1 + 0.2) == "0.3")
        #expect(IntentParser.format(-7) == "-7")
        #expect(IntentParser.format(123_456.789) == "123456.789")
    }

    @Test func dateHeuristicShapes() {
        #expect(IntentParser.looksLikeDate("2026-08-22"))
        #expect(IntentParser.looksLikeDate("2026-8-22"))
        #expect(IntentParser.looksLikeDate("12-31"))
        #expect(!IntentParser.looksLikeDate("5 - 3"))
        #expect(!IntentParser.looksLikeDate("100 - 25 - 50"))
    }
}

struct ExpressionEvaluatorTests {

    private func eval(_ input: String) -> Double? {
        ExpressionEvaluator.evaluate(input)
    }

    @Test func precedenceAndAssociativity() {
        #expect(eval("2 + 3 * 4") == 14)
        #expect(eval("(2 + 3) * 4") == 20)
        #expect(eval("2 ^ 3 ^ 2") == 512)   // right-associative
        #expect(eval("-2 ^ 2") == 4)        // unary binds tighter than ^
        #expect(eval("10 - 4 - 3") == 3)    // left-associative
    }

    @Test func typographicOperatorsMapToAscii() {
        #expect(eval("5 – 3") == 2)
        #expect(eval("5 — 3") == 2)
        #expect(eval("6 ÷ 2") == 3)
        #expect(eval("6 × 2") == 12)
    }

    @Test func nonArithmeticReturnsNil() {
        for input in ["", "hello world", "384 * 27 more words", "()", "1 +", "$5 * 3"] {
            #expect(eval(input) == nil, "\(input) should not evaluate")
        }
    }
}
