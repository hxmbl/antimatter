import Foundation
import Testing
@testable import antimatter

/// M1: variables, functions, and whole-note aggregation.
struct VariableTests {

    private func eval(_ input: String, _ vars: [String: Double] = [:]) -> Double? {
        ExpressionEvaluator.evaluate(input, variables: vars)
    }

    @Test func definitionsScanAndLaterOnesWin() {
        let table = VariableTable.scan("price = 4 * 12\ntotal = price * 2\nprice = 10")
        #expect(table["price"] == 10)
        #expect(table["total"] == 96) // evaluated before the redefinition landed
    }

    @Test func forwardAndSelfReferencesStayText() {
        let table = VariableTable.scan("a = b + 1\nb = 2")
        #expect(table["a"] == nil)
        #expect(table["b"] == 2)
        #expect(VariableTable.scan("x = x + 1")["x"] == nil)
    }

    @Test func nonDefinitionsAreIgnored() {
        let table = VariableTable.scan("hello world\n2026-08-22 = 3\ntimer 5\n_x9 = 4")
        #expect(table.count == 1)
        #expect(table["_x9"] == 4)
    }

    @Test func expressionsResolveVariables() {
        let vars = ["price": 48.0]
        #expect(eval("price / 2", vars) == 24)
        // Names are case-insensitive — friendlier in a scratchpad.
        #expect(eval("price * PRICE", vars) == 2304)
        #expect(eval("missing + 1", vars) == nil)
    }

    @Test func functionsWork() {
        #expect(eval("sqrt(144)") == 12)
        #expect(eval("abs(0 - 7)") == 7)
        #expect(eval("round(2.6)") == 3)
        #expect(eval("min(3, 1, 2)") == 1)
        #expect(eval("max(3, 1, 2)") == 3)
        #expect(eval("min(3)") == 3)
        #expect(eval("sqrt(0 - 1)")?.isFinite == false || eval("sqrt(0 - 1)") == nil)
        #expect(eval("pow(2, 3)") == nil) // unknown function stays text
    }

    @Test func mixedFunctionVariableExpression() {
        #expect(eval("round(price / 7)", ["price": 100.0]) == 14)
        #expect(eval("(min(4, 6) + max(4, 6)) * 2") == 20)
    }
}

struct AggregateTests {

    private func value(_ kind: IntentExecution.AggregateKind, _ note: String) -> Double? {
        kind.value(of: Aggregates.numbers(in: note))
    }

    private static let note = """
    groceries
    12
    34.5

    cost = 2 * 30
    cost = 60 = 60
    timer 90s laundry
    fix bug 42 later
    2026-08-22
    12 kg → lb
    """

    @Test func proseAndCommandsAreIgnoredNumbersAreNot() {
        // Contributes: 12, 34.5 (bare), 2, 30 (definition rhs), 60 (committed expr).
        // Skipped: "groceries", the timer, "fix bug 42" (prose), the date,
        // the unit line, and the committed result 60 (no double counting).
        let sum = value(.sum, Self.note)
        #expect(sum == 138.5)
        #expect(value(.count, Self.note) == 5)
        #expect(value(.avg, Self.note) == 27.7)
    }

    @Test func emptyNoteLeavesTheLineAlone() {
        for kind in [IntentExecution.AggregateKind.sum, .avg, .count] {
            #expect(kind.value(of: []) == nil)
            #expect(IntentExecution.aggregateCommit(kind, keyword: "sum", in: "", at: NSRange(location: 0, length: 3)) == nil)
        }
    }
}

struct ReactiveResultTests {

    private func commits(_ text: String) -> [IntentExecution.Commit] {
        IntentExecution.staleResultCommits(in: text)
    }

    @Test func editingADefinitionRecomputesItsStoredLine() throws {
        let result = try #require(commits("price = 4 * 5 = 48").first)
        #expect(result.replacement.hasSuffix("= 20"))
    }

    @Test func dependentLinesRecomputeToo() {
        let text = "price = 40\nprice / 2 = 12"
        let all = commits(text)
        #expect(all.count == 1)
        #expect(all[0].replacement.hasSuffix("= 20"))
    }

    @Test func freshLinesProduceNoCommits() {
        #expect(commits("384 * 27 = 10368\nprice = 4 * 12 = 48\ntotal = price * 2 = 96").isEmpty)
    }

    @Test func proseDatesUnitsAndPendingLinesAreUntouched() {
        #expect(commits("""
        days until 2026-09-01 = 8
        12 kg → lb = 26.46
        hello = world
        384 * 27 =
        """).isEmpty)
    }

    @Test func normalizationRewritesOnceThenIsStable() {
        let first = commits("2 + 2 = 5")
        #expect(first.first?.replacement == "2 + 2 = 4")
        #expect(commits("2 + 2 = 4").isEmpty)
    }
}

/// M2: dates and units.
struct DateIntentTests {

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func commit(_ line: String, now: Date) -> String? {
        DateIntent.commit(line, now: now, calendar: utcCalendar)
    }

    private var fixedNow: Date { Date(timeIntervalSince1970: 1_789_000_000) } // 2026-08 UTC

    @Test func bareDateGainsWeekday() {
        let out = commit("2026-08-22", now: fixedNow)
        #expect(out != nil && out!.contains("·"))
        #expect(commit("  2026-08-22", now: fixedNow)?.hasPrefix("  ") == true) // indent kept
        #expect(out!.contains("2026-08-22 · "))
    }

    @Test func daysUntilCountsFromToday() {
        let today = utcCalendar.startOfDay(for: fixedNow)
        let target = utcCalendar.date(byAdding: .day, value: 8, to: today)!
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        let out = commit("days until \(formatter.string(from: target))", now: fixedNow)
        #expect(out?.hasSuffix(" = 8") == true)
    }

    @Test func looseShapesStayText() {
        #expect(DateIntent.commit("12-31") == nil)
        #expect(DateIntent.commit("2026-8-22") == nil)
        #expect(DateIntent.commit("days until someday") == nil)
        #expect(DateIntent.commit("hello world") == nil)
    }
}

struct UnitConverterTests {

    private func convert(_ v: Double, _ f: String, _ t: String) -> Double? {
        UnitConverter.convert(value: v, from: f, to: t)
    }

    @Test func linearConversions() {
        #expect(abs(convert(12, "kg", "lb")! - 26.45547146) < 0.001)
        #expect(abs(convert(3, "mi", "km")! - 4.828032) < 0.00001)
        #expect(convert(100, "cm", "m") == 1)
        #expect(abs(convert(1, "ft", "in")! - 12) < 0.0001)
    }

    @Test func temperatureNeedsFormulasNotFactors() {
        #expect(abs(convert(100, "°C", "f")! - 212) < 0.0001)
        #expect(abs(convert(32, "f", "c")!) < 0.0001)
        #expect(abs(convert(0, "c", "K")! - 273.15) < 0.0001)
    }

    @Test func incompatibleDimensionsStayText() {
        #expect(convert(1, "kg", "km") == nil)
        #expect(convert(1, "kg", "zz") == nil)
        #expect(UnitConverter.commit("some kg → lb") == nil)
    }

    @Test func commitRewritesWithAnswer() {
        #expect(UnitConverter.commit("12 kg → lb")?.hasSuffix(" = 26.4555") == true)
        #expect(UnitConverter.commit("3 mi -> km") != nil)
        #expect(UnitConverter.commit("   100 °F -> c")?.hasPrefix("   ") == true)
    }
}
