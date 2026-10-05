import Foundation
import Testing
@testable import antimatter

/// Variables, functions, and whole-note aggregation.
struct VariableTests {

    private func eval(_ input: String, _ vars: [String: Double] = [:]) -> Double? {
        ExpressionEvaluator.evaluate(input, variables: vars)
    }

    private func num(_ name: String, _ table: [String: SparkValue]) -> Double? {
        table[name]?.number
    }

    @Test func definitionsScanAndLaterOnesWin() {
        let table = VariableTable.scan(":price = 4 * 12\n:total = :price * 2\n:price = 10")
        #expect(num("price", table) == 10)
        #expect(num("total", table) == 96) // evaluated before the redefinition landed
    }

    @Test func forwardReferencesResolveByAGraphPass() {
        let table = VariableTable.scan(":a = :b + 1\n:b = 2")
        #expect(num("a", table) == 3) // forward reference resolves
        #expect(num("b", table) == 2)
        // A genuinely unresolvable reference stays text, and says so.
        #expect(num("x", VariableTable.scan(":x = :x + 1")) == nil)
        // One pass isn't always enough: :c depends on :z, defined later than
        // :m. The multi-pass resolver keeps going until the graph settles.
        #expect(num("a", VariableTable.scan(":a = :b + 1\n:b = :c + 1\n:c = 1")) == 3)
    }

    @Test func unresolvedDefinitionsReportTheirReason() {
        #expect(VariableTable.unresolvedDefinitions(in: ":a = :b + 1\n:b = 2").isEmpty)
        #expect(VariableTable.unresolvedDefinitions(in: ":x = :x + 1").count == 1)
        #expect(VariableTable.circularDependencies(in: ":a = :b\n:b = :c\n:c = :a").sorted() == ["a", "b", "c"])
        // A pure self-reference is a self-reference, not a cycle.
        #expect(VariableTable.circularDependencies(in: ":x = :x + 1").isEmpty)
    }

    @Test func emptyDefinitionUnsets() {
        let table = VariableTable.scan(":price = 4 * 5\n:price = \n:total = :price + 1")
        #expect(num("price", table) == nil)
        // :total could never resolve (price is gone), so it stays text too.
        #expect(num("total", table) == nil)
        #expect(IntentExecution.definitionDiagnostic(for: ("price", "4 * 5"), in: "") == nil)
    }

    @Test func nonDefinitionsAreIgnored() {
        let table = VariableTable.scan("hello world\n2026-08-22 = 3\ntimer 5\n:_x9 = 4")
        #expect(table.count == 1)
        #expect(num("_x9", table) == 4)
    }

    @Test func expressionsResolveVariables() {
        let vars = ["price": 48.0]
        #expect(eval("price / 2", vars) == 24)
        // Names are case-insensitive — friendlier in a scratchpad.
        #expect(eval("price * PRICE", vars) == 2304)
        #expect(eval("missing + 1", vars) == nil)
    }

    @Test func explicitVariablesAndCommandSubstitutionAreNumeric() {
        let text = ":total = $(.sum 10 20 50 40)"
        #expect(num("total", VariableTable.scan(text)) == 120)
        #expect(num("total", VariableTable.scan("total = 100")) == nil)
        #expect(ExpressionEvaluator.evaluate("total", variables: ["total": 120]) == 120)
    }

    @Test func aggregateAutoReactCommandsWorkInline() {
        #expect(ExpressionEvaluator.evaluate("$(.sum)", buffer: "10\n20\n30") == 60)
        #expect(ExpressionEvaluator.evaluate("$(.avg)", buffer: "10\n20\n30") == 20)
        #expect(ExpressionEvaluator.evaluate("$(.count)", buffer: "10\n20\n30") == 3)
    }

    @Test func functionsWork() {
        #expect(eval("sqrt(144)") == 12)
        #expect(eval("abs(0 - 7)") == 7)
        #expect(eval("round(2.6)") == 3)
        #expect(eval("min(3, 1, 2)") == 1)
        #expect(eval("max(3, 1, 2)") == 3)
        #expect(eval("min(3)") == 3)
        #expect(eval("sqrt(0 - 1)") == nil)
        #expect(eval("pow(2, 3)") == nil) // unknown function stays text
    }

    @Test func mixedFunctionVariableExpression() {
        #expect(eval("round(price / 7)", ["price": 100.0]) == 14)
        #expect(eval("(min(4, 6) + max(4, 6)) * 2") == 20)
    }
}

/// Spark: scientific notation, implicit multiplication, comparisons, boolean
/// logic, strings, escapes, and parse diagnostics.
struct SparkSyntaxTests {

    private func value(_ input: String, _ vars: [String: SparkValue] = [:]) -> SparkValue? {
        ExpressionEvaluator.evaluateValue(input, variables: vars)
    }

    private func num(_ input: String, _ vars: [String: SparkValue] = [:]) -> Double? {
        value(input, vars)?.number
    }

    @Test func scientificNotation() {
        #expect(num("1e3") == 1000)
        #expect(num("1.5e2") == 150)
        #expect(num("2E-3") == 0.002)
        #expect(num("1e0") == 1)
        #expect(num("1e3 + 1") == 1001)
        #expect(num("1e") == nil) // no exponent digits — stays text
        #expect(num("1e+2") == 100)
        #expect(num("1e-2") == 0.01)
    }

    @Test func implicitMultiplicationByJuxtaposition() {
        #expect(num("2(3 + 4)") == 14)
        #expect(num("(2)(3)") == 6)
        #expect(num("2(3)(4)") == 24)
        #expect(num("sqrt(9)2") == nil) // juxtaposition is lparen-only:
                                        // a literal right after `)` stays text
        #expect(num("(2)") == 2) // bare paren group is untouched
    }

    @Test func comparisonsAndBooleanLogic() {
        #expect(value("2 > 1") == .boolean(true))
        #expect(value("1 < 2") == .boolean(true))
        #expect(value("3 <= 3") == .boolean(true))
        #expect(value("3 >= 4") == .boolean(false))
        #expect(value("2 == 2") == .boolean(true))
        #expect(value("2 != 2") == .boolean(false))
        #expect(value("true && false") == .boolean(false))
        #expect(value("true || false") == .boolean(true))
        #expect(value("!true") == .boolean(false))
        #expect(value("!false") == .boolean(true))
        // Precedence: ! binds tightest, then <... == ... && ... || ...
        #expect(value("!true || false") == .boolean(false))
        #expect(value("1 < 2 && 2 < 3") == .boolean(true))
        #expect(value("1 + 1 == 2") == .boolean(true))
        #expect(num("2 > 1") == nil) // numeric evaluate() rejects booleans
    }

    @Test func stringsConcatAndFunctions() {
        #expect(value("\"a\" + \"b\"") == .string("ab"))
        #expect(value("upper(\"abc\")") == .string("ABC"))
        #expect(value("lower(\"ABC\")") == .string("abc"))
        #expect(num("len(\"hello\")") == 5)
        #expect(value("len(\"a + b\")") == .number(5))
        #expect(value("upper(123)") == nil) // wrong argument type stays text
    }

    @Test func pendingAndParsedCalculationsCarrySparkValues() {
        #expect(IntentParser.pendingCalculation("2 > 1 =") ==
            IntentParser.Calculation(expression: "2 > 1", result: .boolean(true)))
        #expect(IntentParser.pendingCalculation("\"a\" + \"b\" =") ==
            IntentParser.Calculation(expression: "\"a\" + \"b\"", result: .string("ab")))
        #expect(IntentParser.parseCalculation("2 + 2")?.result == .number(4))
        #expect(IntentParser.parseCalculation("2 > 5")?.result == .boolean(false))
        #expect(IntentParser.parseCalculation("2 > 5").map { IntentParser.format($0.result) } == "false")
        #expect(IntentParser.format(SparkValue.boolean(true)) == "true")
        #expect(IntentParser.format(SparkValue.string("ab")) == "\"ab\"")
    }

    @Test func escapedLinesDoNothing() {
        #expect(IntentParser.isEscaped("\\ .timer"))
        #expect(!IntentParser.isEscaped(".timer"))
        #expect(IntentExecution.action(forLine: "\\ .timer") == .nothing)
        #expect(IntentExecution.preview(forLine: "\\ .timer") == nil)
        #expect(IntentExecution.action(forLine: "\\:x = 2 + 2") == .nothing)
    }

    @Test func mathLinesKeepQuiet() {
        // The syntax gate keeps prose from ever surfacing a hint: without a
        // number beside an operator, looksArithmetic says no and action() is
        // silent on return.
        #expect(!ExpressionEvaluator.looksArithmetic("hello world"))
        #expect(!ExpressionEvaluator.looksArithmetic("Hey!"))
        #expect(ExpressionEvaluator.looksArithmetic("2 +"))
        #expect(IntentExecution.action(forLine: "hello world") == .nothing)
        #expect(IntentExecution.action(forLine: "Hey!") == .nothing)
        #expect(ExpressionEvaluator.error(in: "2026-08-22", buffer: "2026-08-22") == nil)
    }

    @Test func diagnosticsExplainBrokenArithmetic() {
        #expect(ExpressionEvaluator.error(in: "2 +", buffer: "2 +") == "Expected a value after '+'")
        #expect(ExpressionEvaluator.error(in: "(2 + 3", buffer: "(2 + 3") == "Expected ')'")
        #expect(ExpressionEvaluator.error(in: "2 & 3", buffer: "2 & 3") != nil)
        #expect(ExpressionEvaluator.error(in: "price + 1", buffer: "price + 1") != nil)
    }

    /// A diagnostic must quote the token exactly once. `describeToken` used to
    /// return pre-quoted text that the single call site quoted again, so every
    /// "unexpected token" message came out as `Unexpected '')''`.
    @Test func unexpectedTokensAreQuotedOnce() {
        #expect(ExpressionEvaluator.error(in: "(2))") == "Unexpected ')'")
        #expect(ExpressionEvaluator.error(in: "1e") == "Unexpected 'e'")
        #expect(ExpressionEvaluator.error(in: "[1, 2] ]") == "Unexpected ']'")
        #expect(ExpressionEvaluator.error(in: "min()") == "Unexpected ')'")
    }

    /// …and it must name what the user *typed*. Number tokens used to carry only
    /// the parsed `Double`, so `2 3` complained about `'3.0'` and `1e6 2` about
    /// `'1000000'`.
    @Test func unexpectedNumbersEchoTheirSourceText() {
        #expect(ExpressionEvaluator.error(in: "2 3") == "Unexpected '3'")
        #expect(ExpressionEvaluator.error(in: "1e6 2") == "Unexpected '2'")
        #expect(ExpressionEvaluator.error(in: "1.2.3 + 1") == "Unexpected '1.2.3'")
    }

    /// A non-finite result one level down still gets said out loud. The check
    /// only looked at a top-level number, so a NaN *inside* a list produced
    /// silence even though `looksArithmetic` asked for a reason.
    @Test func nestedNonFiniteResultsAreDiagnosed() {
        let message = "Result is too large or undefined"
        #expect(ExpressionEvaluator.error(in: "ln(-1)") == message)
        #expect(ExpressionEvaluator.error(in: "[ln(-1)]") == message)
        #expect(ExpressionEvaluator.error(in: "[[0^-1]]") == message)
        // …and they still refuse to commit, list or not.
        #expect(value("[ln(-1)]")?.isFinite == false)
        #expect(IntentParser.pendingCalculation("[ln(-1)] =") == nil)
    }

    @Test func answersExtractBooleansAndStrings() {
        #expect(IntentExecution.answer(fromLine: "2 > 1 = true") == "true")
        #expect(IntentExecution.answer(fromLine: "\"a\" + \"b\" = \"ab\"") == "ab")
        #expect(IntentExecution.answer(fromLine: "384 * 27 = 10368") == "10368")
        #expect(IntentExecution.answer(fromLine: "2026-08-22 = Saturday") == "Saturday")
        #expect(IntentExecution.answer(fromLine: "plain prose") == nil)
    }

    @Test func definitionDiagnosticsFlagProblems() {
        #expect(IntentExecution.definitionDiagnostic(for: ("a", "b + 1"), in: "") == "':b' isn't defined yet")
        #expect(IntentExecution.definitionDiagnostic(for: ("a", ":a"), in: ":a = :a") == ":a can't be defined from itself")
        #expect(IntentExecution.definitionDiagnostic(for: ("a", "2 + 2"), in: ":b = 2") == nil)
        #expect(IntentExecution.definitionDiagnostic(for: ("a", "\"hi\""), in: "") == nil) // strings store now
    }
}

/// Ranges, lists, indexing, and `if` — plus the two ceilings that keep a
/// malformed line from taking the process down.
///
/// None of this had a single test, which is how `range()` came to compute its
/// own width *before* validating it and trap on `:x = -5e18..5e18`. Every
/// boundary that can end a process belongs here.
struct SparkCollectionsAndLimitsTests {

    private func value(_ input: String) -> SparkValue? {
        ExpressionEvaluator.evaluateValue(input)
    }

    private func list(_ input: String) -> [Double]? {
        value(input)?.list?.compactMap(\.number)
    }

    private func num(_ input: String) -> Double? {
        value(input)?.number
    }

    /// `2^2^2^…`, right-associative.
    private func powerChain(_ terms: Int) -> String {
        (0...terms).map { _ in "2" }.joined(separator: "^")
    }

    // MARK: Ranges

    @Test func rangesExpandUpwardAndInclusively() {
        #expect(list("1..5") == [1, 2, 3, 4, 5])
        #expect(list("-2..0") == [-2, -1, 0])
        #expect(list("3..3") == [3])
        #expect(value("1..5") == .list([.number(1), .number(2), .number(3), .number(4), .number(5)]))
    }

    @Test func rangesMustGoUpwardAndTakeWholeNumbers() {
        #expect(value("5..1") == nil)
        #expect(ExpressionEvaluator.error(in: "5..1") == "Ranges go upward")
        #expect(value("1.5..3") == nil)
        #expect(ExpressionEvaluator.error(in: "1.5..3") == "Ranges need whole numbers")
        #expect(value("1...5") == nil) // a third dot is a number, not an operator
        // `..` binds looser than `+`, so this widens rather than adding.
        #expect(list("1..3 + 1") == [1, 2, 3, 4])
    }

    /// The cap, and the boundary either side of it.
    @Test func theRangeCapIsEnforced() {
        #expect(list("1..100000")?.count == 100_000)
        #expect(value("1..100001") == nil)
        #expect(ExpressionEvaluator.error(in: "1..100001") == "That range is too large")
    }

    /// Regression: the width was computed as `last - first + 1` *before* the
    /// upward and cap checks, so any range wider than `Int.max` trapped instead
    /// of reporting an error. `-5e18..5e18` is 1e19 wide.
    ///
    /// This killed the app rather than the line: `VariableTable.scan` runs on
    /// every repaint, so a single such definition in a note crashed the process
    /// every time the note was drawn. Ordering the bounds first was not enough
    /// either — it rules out underflow, not overflow.
    @Test func absurdRangeBoundsReportAnErrorInsteadOfTrapping() {
        for input in ["-5e18..5e18", "-4.7e18..4.7e18", "-1e18..9.2e18", "-9.2e18..1e18"] {
            #expect(value(input) == nil, "\(input) must not evaluate")
            #expect(ExpressionEvaluator.error(in: input) == "That range is too large",
                    "\(input) should say it is too large")
        }
        // The widest range that *is* legal still works. `1..100000` is 100,000
        // entries; `0..100000` is 100,001 and so one over the cap.
        #expect(list("1..100000")?.count == 100_000)
        #expect(ExpressionEvaluator.error(in: "0..100000") == "That range is too large")
        // A single-element range at the very bottom of `Int` is fine.
        #expect(list("-9223372036854775808..-9223372036854775808")?.count == 1)
        // A negative width can't underflow either.
        #expect(value("5..1") == nil)
    }

    /// The same crash by the route that mattered most: a note containing the
    /// definition, scanned the way every repaint scans it.
    @Test func scanningANoteWithAnAbsurdRangeDoesNotTrap() {
        #expect(VariableTable.scan(":x = -5e18..5e18").isEmpty)
        #expect(VariableTable.scan(":x = 1..5")["x"]?.list?.count == 5)
    }

    // MARK: Lists

    @Test func listsHoldEveryValueKind() {
        #expect(value("[]") == .list([]))
        #expect(list("[1, 2, 3]") == [1, 2, 3])
        #expect(value("[[1], [2, 3]]") == .list([.list([.number(1)]), .list([.number(2), .number(3)])]))
        #expect(value("[\"a\", true]") == .list([.string("a"), .boolean(true)]))
        #expect(value("[1,]") == nil) // no trailing comma
    }

    @Test func listAggregatesAndLength() {
        #expect(value("len([1, 2, 3])") == .number(3))
        #expect(value("len([])") == .number(0))
        #expect(value("min([3, 1], 2)") == .number(1))
        #expect(value("max(1..5)") == .number(5))
        #expect(value("max([1, 2], [5, -9])") == .number(5))
    }

    /// Lists compare by value, all the way down. The `(list, list)` arm of
    /// `equality` used to be missing, so identical lists fell through to the
    /// mixed-kind default and compared *unequal* — `1..5 == 1..5` answered
    /// `false`, and being a finite non-list value it committed that to the note
    /// and kept it on every reactive pass.
    @Test func listsCompareStructurally() {
        #expect(value("[1, 2] == [1, 2]") == .boolean(true))
        #expect(value("[1, 2] != [1, 2]") == .boolean(false))
        #expect(value("[1, [2]] == [1, [2]]") == .boolean(true))
        #expect(value("[1, 2] == [1, 3]") == .boolean(false))
        #expect(value("[] == []") == .boolean(true))
        // Different kinds are still just unequal, never an error.
        #expect(value("[1] == 1") == .boolean(false))
        #expect(value("1 == \"1\"") == .boolean(false))
        // Ordering lists is not a thing.
        #expect(value("[1] < [2]") == nil)
    }

    @Test func listsCannotBeAddedOrSubtracted() {
        #expect(value("[1, 2] + 1") == nil)
        #expect(value("1 + [1, 2]") == nil)
        #expect(ExpressionEvaluator.error(in: "1 + [1, 2]") == "Can't add these")
    }

    /// A list answer is never written back into the line — a committed answer
    /// is rewritten text, and a range can be a hundred thousand entries long.
    @Test func listAnswersDoNotCommitOrRefresh() {
        #expect(IntentParser.pendingCalculation("1..5 =") == nil)
        #expect(IntentParser.pendingCalculation("[1, 2, 3] =") == nil)
        #expect(IntentParser.parseCalculation("[1, 2, 3]") == nil)
        // They still render everywhere a value is displayed.
        #expect(IntentParser.format(.list([.number(1), .number(2)])) == "[1, 2]")
    }

    // MARK: Indexing

    @Test func indexingReadsListsAndStrings() {
        #expect(value("[1, 2, 3][0]") == .number(1))
        #expect(value("[1, 2, 3][-1]") == .number(3))
        #expect(value("[[1, 2], [3, 4]][0][1]") == .number(2))
        #expect(value("\"abc\"[1]") == .string("b"))
        #expect(value("(1..5)[2]") == .number(3)) // a range is a list
    }

    @Test func badIndexesExplainThemselves() {
        #expect(value("[1, 2][5]") == nil)
        #expect(ExpressionEvaluator.error(in: "[1, 2][5]") == "No item 5 in a list of 2")
        #expect(ExpressionEvaluator.error(in: "[1, 2][\"a\"]") == "Indexes need whole numbers")
        #expect(ExpressionEvaluator.error(in: "[1, 2][1.5]") == "Indexes need whole numbers")
        #expect(ExpressionEvaluator.error(in: "[1, 2][-9]") == "No item -9 in a list of 2")
        #expect(ExpressionEvaluator.error(in: "1[0]") == "'[' needs a list or string")
    }

    /// A huge negative index used to be the other way to run the stack out of
    /// arithmetic — worth pinning, since it is the same shape of bug.
    @Test func extremeIndexesFailWithoutTrapping() {
        #expect(value("[1, 2][-9223372036854775808]") == nil)
        #expect(value("[1, 2][9e18]") == nil)
        #expect(value("\"ab\"[-9223372036854775808]") == nil)
    }

    // MARK: Conditionals

    @Test func conditionalsPickABranch() {
        #expect(value("if true then 1 else 2") == .number(1))
        #expect(value("if false then 1 else 2") == .number(2))
        #expect(value("if 1 > 2 then \"a\" else \"b\"") == .string("b"))
        #expect(value("if false then 1 else if true then 2 else 3") == .number(2))
        // Nested in the *then* branch, the inner `else` is the inner `if`'s, so
        // the outer one is left without an `else` — dangling `else` binds
        // innermost, as it does in C. `if false then …` (inner in an else
        // branch) nests fine, as above.
        #expect(value("if true then if true then 2 else 3") == nil)
        #expect(value("if true then if true then 1 else 2 else 3") == .number(1))
        // A branch can be any kind of value, lists included.
        #expect(value("if true then [1, 2] else []") == .list([.number(1), .number(2)]))
    }

    /// Only the taken branch runs, so a division by zero in the other one is
    /// not an error. The untaken branch is still parsed, but into a scratch
    /// state so its errors stay isolated.
    @Test func conditionalsAreLazy() {
        #expect(value("if 1 < 0 then 100 / 0 else 5") == .number(5))
        #expect(value("if false then 1 / 0 else 5") == .number(5))
        #expect(value("if true then 5 else 100 / 0") == .number(5))
        // The *taken* branch still has to work.
        #expect(value("if true then 100 / 0 else 5") == nil)
        #expect(ExpressionEvaluator.error(in: "if true then 100 / 0 else 5") == "Division by zero")
    }

    @Test func malformedConditionalsExplainThemselves() {
        #expect(ExpressionEvaluator.error(in: "if 1 then 2 else 3") == "Expected a boolean after 'if'")
        #expect(ExpressionEvaluator.error(in: "if true then 2") == "Expected 'else'")
        #expect(ExpressionEvaluator.error(in: "if true 2 else 3") == "Expected 'then'")
        #expect(value("if true then 2") == nil)
    }

    // MARK: Constants

    /// `^` is right-associative and used to recurse once per operator, so a long
    /// chain was bounded only by stack depth — and inconsistently: 200,000 terms
    /// was fine at `-Onone` and a segfault at `-O`. The fold is now iterative,
    /// and it stops at the first intermediate that isn't finite rather than
    /// carrying an `inf` into the next `pow` (where a fractional exponent makes
    /// `nan`, and `nan` slips past `isFinite` guards downstream).
    @Test func powerChainsAreIterativeAndBounded() {
        #expect(value("2^3^2") == .number(512))   // 2^(3^2), not (2^3)^2
        #expect(value("2^2^3") == .number(256))   // 2^8
        #expect(value("-2^2") == .number(4))      // unary binds the base
        #expect(value("2^-1") == .number(0.5))
        #expect(value("1^99999") == .number(1))
        #expect(value(powerChain(5_000)) == nil) // past the 4,096 chain ceiling
        #expect(ExpressionEvaluator.error(in: powerChain(5_000))
                == "That expression has too many operators in a row")
        #expect(value("2^") == nil)
        #expect(ExpressionEvaluator.error(in: "2^") == "Expected a value after '^'")
    }

    /// Long operator runs are collected rather than recursed, for the same
    /// reason. Semantics must be identical to the recursive form.
    @Test func unaryRunsAreIterativeAndKeepTheirSemantics() {
        #expect(value("!!!true") == .boolean(false))
        #expect(value("!!true") == .boolean(true))
        #expect(value("!false") == .boolean(true))
        #expect(value("--3") == .number(3))
        #expect(value("+-3") == .number(-3))
        #expect(value("-  -3") == .number(3))
        #expect(value("-1") == .number(-1))
        #expect(value("- (2 + 3)") == .number(-5))
        #expect(value(String(repeating: "!", count: 5_000) + "true") == nil)
        #expect(value(String(repeating: "-", count: 5_000) + "1") == nil)
    }

    /// `1e` is the number 1 followed by the constant `e` — two tokens, not one
    /// malformed number — so it must not evaluate.
    @Test func aTrailingLoneEIsNotANumber() {
        #expect(value("1e") == nil)
        #expect(ExpressionEvaluator.error(in: "1e") == "Unexpected 'e'")
        #expect(value("1e3") == .number(1000))
        #expect(value("2e-3") == .number(0.002))
        #expect(value("1E5") == .number(100000))
    }

    @Test func constantsAreAvailable() {
        #expect(num("pi") == Double.pi)
        #expect(num("tau") == Double.pi * 2)
        #expect(num("e") == M_E)
    }

    // MARK: Nesting ceiling

    /// Recursive descent used to have no depth bound at all, and four separate
    /// shapes of input exhausted the stack (SIGSEGV): parentheses, list
    /// brackets, a run of unary operators, a run of `^`, and nested `$( )`.
    ///
    /// Sized to just past each ceiling rather than to the 200,000 that used to
    /// segfault: past the guard the parser is iterative, so a bigger input only
    /// buys a bigger token array. Tokenizing 200k tokens allocates ~6 MB, which
    /// is enough to destabilize the test host — it runs the whole app, keychain
    /// and all — so the enormous versions took the *runner* down and read as a
    /// failure of the very thing being tested.
    @Test func deeplyNestedInputIsRejectedNotCrashed() {
        let tooDeep = "That expression is nested too deeply"
        let beyondChain = 5_000 // the chain ceiling is 4,096
        #expect(ExpressionEvaluator.error(in: String(repeating: "(", count: 1_000)
                                             + "1"
                                             + String(repeating: ")", count: 1_000)) == tooDeep)
        #expect(ExpressionEvaluator.error(in: String(repeating: "[", count: 1_000)
                                             + "1"
                                             + String(repeating: "]", count: 1_000)) == tooDeep)
        #expect(value(String(repeating: "!", count: beyondChain) + "true") == nil)
        #expect(value(String(repeating: "-", count: beyondChain) + "1") == nil)
        #expect(value(powerChain(beyondChain)) == nil)
        #expect(value(String(repeating: "$(", count: 1_000) + "1" + String(repeating: ")", count: 1_000)) == nil)
        #expect(ExpressionEvaluator.error(in: String(repeating: "$(", count: 1_000)
                                             + "1"
                                             + String(repeating: ")", count: 1_000)) == tooDeep)
        // A lone `^`, and a trailing operator, report rather than trap.
        #expect(value("2^") == nil)
        #expect(ExpressionEvaluator.error(in: "2^") == "Expected a value after '^'")
    }

    /// The nesting ceiling counts parens, brackets and `$( )` spans — the
    /// constructs a person would call nesting — so 64 has to mean 64. It first
    /// didn't: sharing one counter with the operator chains cost three units per
    /// paren and made the documented limit behave like 20.
    @Test func theNestingLimitIsExactlyWhatItSays() {
        let parens = { (count: Int) in
            String(repeating: "(", count: count) + "1" + String(repeating: ")", count: count)
        }
        // 24 is the ceiling; it is not a round number by accident. One level of
        // nesting is ~11 parser frames and a Debug frame is several times a
        // release one, so 64 levels overflowed the 512 KB stack the test host
        // gives a thread. See `maxNestingDepth`.
        #expect(value(parens(23)) == .number(1))
        #expect(value(parens(24)) == .number(1))
        #expect(value(parens(25)) == nil)
        #expect(ExpressionEvaluator.error(in: parens(25)) == "That expression is nested too deeply")
        // Long operator chains get their own, far larger allowance — 4,096 — and
        // a run of `!` is the clean check that it isn't firing on ordinary
        // input. 500 is even, so the answer is `true`.
        #expect(value(String(repeating: "!", count: 500) + "true") == .boolean(true))
    }

    /// This suite exists because the first attempt at the ceiling passed every
    /// standalone check and still crashed `xctest`. One paren costs *eleven*
    /// parser frames, so a guard on any single link of the chain bounds one
    /// frame in eleven: 64 parens still recursed ~700 deep, which the main
    /// thread's 8 MB stack absorbs and the test host's does not. The guard has
    /// to sit where a nesting construct is *entered*, once per level, and the
    /// thresholds below are load-bearing rather than incidental.
    @Test func ordinaryNestingStillWorks() {
        #expect(value("((((1 + 2))))") == .number(3))
        #expect(value("$($($(1 + 2)))") == .number(3))
        #expect(value("if true then if true then if true then 1 else 2 else 3 else 4") == .number(1))
        #expect(value("[[1, 2], [3, 4]][0][1]") == .number(2))
        #expect(value("sqrt(sqrt(sqrt(sqrt(65536))))") == .number(2))
        #expect(value(String(repeating: "(", count: 20) + "1" + String(repeating: ")", count: 20)) == .number(1))
        #expect(value(String(repeating: "$(", count: 13) + "1 + 2" + String(repeating: ")", count: 13)) == .number(3))
        // Ten-deep bracket nesting is ten *lists*, one wrapping the next. Comparing the
        // whole shape is unreadable; what matters is that it built without
        // complaint and that indexing reaches the innermost value.
        let nested = value("[[[[[[[[[[1]]]]]]]]]]")
        #expect(nested?.isList == true)
        #expect(nested?.list?.first?.isList == true)
        #expect(value("[[[[[[[[[[1]]]]]]]]]][0][0][0][0][0][0][0][0][0][0]") == .number(1))
        #expect(value("[1, 2, 3][1]") == .number(2))
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
    .timer 90s laundry
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
            #expect(IntentExecution.aggregateCommit(kind, keyword: ".sum", in: "", at: NSRange(location: 0, length: 3)) == nil)
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

    @Test func rewritesPreserveTheTrailingNewline() throws {
        // Regression: line ranges used to include the newline.
        let text = "price = 4 * 5 = 48\nkeep me\n"
        let result = try #require(commits(text).first)
        let after = (text as NSString).replacingCharacters(in: result.range, with: result.replacement)
        #expect(after == "price = 4 * 5 = 20\nkeep me\n")
    }

    @Test func aggregateLinesRecomputeWhenTheNoteChanges() {
        // The note changed after .sum was committed — it drifts, then rests.
        #expect(commits("12\n.sum = 99").first?.replacement.hasSuffix("= 12") == true)
        #expect(commits("12\n34\n.sum = 46").isEmpty)

        #expect(commits("1\n2\n3\n.count = 3").isEmpty) // fresh
        #expect(commits("1\n2\n3\n4\n.count = 3").first?.replacement.hasSuffix("= 4") == true)
    }
}

struct SignedLiteralTests {

    private func literals(_ input: String) -> [Double]? {
        ExpressionEvaluator.numericLiterals(input)
    }

    @Test func minusSticksToTheFollowingNumber() {
        #expect(literals("-5") == [-5])
        #expect(literals("10 - 5") == [10, -5])
        #expect(literals("2^-3") == [2, -3])
        #expect(literals("8 * -2") == [8, -2])
        #expect(literals("min(-1, 4)") == [-1, 4])
    }

    @Test func groupNegationIsNotALiteral() {
        #expect(literals("-(2 + 3)") == [2, 3])
    }

    @Test func signedLiteralsSumToTheValueOfAdditiveExpressions() {
        for input in ["-5", "10 - 5", "-1 - 2 - 3"] {
            #expect(literals(input)!.reduce(0, +) == ExpressionEvaluator.evaluate(input))
        }
    }

    @Test func listLiteralsAreTolerantOfSpaceSeparatedLists() {
        // A list like `10 20 30` isn't one expression, so numericLiterals
        // declines it — listLiterals is the permissive variant for `.sum`.
        #expect(ExpressionEvaluator.numericLiterals("10 20 30") == nil)
        #expect(ExpressionEvaluator.listLiterals("10 20 30") == [10, 20, 30])
        #expect(ExpressionEvaluator.listLiterals("-5 3") == [-5, 3])
        #expect(ExpressionEvaluator.listLiterals("1.5, 2.5") == [1.5, 2.5])
        #expect(ExpressionEvaluator.listLiterals("2 * 3 4") == [2, 3, 4])
        #expect(ExpressionEvaluator.listLiterals("no numbers") == [])
        #expect(ExpressionEvaluator.listLiterals("") == [])
    }
}

/// Dates and units.
struct DateIntentTests {

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        // en_US pins full weekday names ("Saturday"), matching
        // weekdayIsCorrectOutsideUTC, regardless of where the tests run.
        calendar.locale = Locale(identifier: "en_US")
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func commit(_ line: String, now: Date) -> String? {
        DateIntent.commit(line, now: now, calendar: utcCalendar)
    }

    private var fixedNow: Date { Date(timeIntervalSince1970: 1_789_000_000) } // 2026-08 UTC

    @Test func bareDateGainsWeekday() {
        let out = commit("2026-08-22", now: fixedNow)
        #expect(out == "2026-08-22 = Saturday")
        #expect(commit("  2026-08-22", now: fixedNow)?.hasPrefix("  ") == true) // indent kept
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

    @Test func weekdayIsCorrectOutsideUTC() {
        // New York is UTC-4 in August: a UTC-midnight parse of 2026-08-22
        // reads as the 21st at 20:00, which would report Friday. Interpreting
        // the date in the caller's own calendar keeps it Saturday. The
        // explicit en_US locale pins the weekday name regardless of where the
        // tests run.
        var newYork = Calendar(identifier: .gregorian)
        newYork.locale = Locale(identifier: "en_US")
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        let out = DateIntent.commit("2026-08-22", now: fixedNow, calendar: newYork)
        #expect(out?.contains("= Saturday") == true)
    }

    @Test func daysUntilCountsInTheCallersCalendar() {
        // The 8-day gap must hold no matter the zone: a UTC-midnight instant
        // for the target would sit at 8pm the day before in New York, which
        // the buggy count turned into 7. `now` is midday UTC (= 8am in NY)
        // so both calendars share the same "today".
        var newYork = Calendar(identifier: .gregorian)
        newYork.locale = Locale(identifier: "en_US")
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        let now = Date(timeIntervalSince1970: 1_789_038_000)
        let out = DateIntent.commit("days until 2026-09-18", now: now, calendar: newYork)
        #expect(out?.hasSuffix(" = 8") == true)
    }
}

/// Serialized: currency tests share the process-global RateCache.
@Suite(.serialized)
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
        #expect(UnitConverter.commit("12 kg → lb") == "12 kg → lb = 26.4555")
        #expect(UnitConverter.commit("3 mi -> km") == "3 mi -> km = 4.82803")
        #expect(UnitConverter.commit("   100 °F -> c") == "   100 °F -> c = 37.7778")
        #expect(UnitConverter.commit("12 kg->lb") == "12 kg->lb = 26.4555")
    }

    @Test func dashArrowsWork() {
        #expect(UnitConverter.commit("12 kg – lb")?.hasSuffix(" = 26.4555") == true)
        #expect(UnitConverter.commit("12 kg — lb")?.hasSuffix(" = 26.4555") == true)
    }

    @Test func currencyConversionUsesCache() {
        let fakeRates: [String: Double] = ["USD": 1.0, "EUR": 0.85, "GBP": 0.73, "BTC": 0.000024]
        RateCache.shared.replace(with: fakeRates)
        defer { RateCache.shared.replace(with: [:]) }

        let eur = UnitConverter.convert(value: 100, from: "usd", to: "eur")!
        #expect(abs(eur - 85.0) < 0.001)

        let usd = UnitConverter.convert(value: 17, from: "eur", to: "usd")!
        #expect(abs(usd - 20.0) < 0.001)

        let btc = UnitConverter.convert(value: 1000, from: "usd", to: "btc")!
        #expect(abs(btc - 0.024) < 0.000001)
    }

    @Test func currencyEmptyCacheReturnsNil() {
        RateCache.shared.replace(with: [:])
        #expect(UnitConverter.convert(value: 100, from: "usd", to: "eur") == nil)
    }

    @Test func currencyUnknownSymbolReturnsNil() {
        let fakeRates: [String: Double] = ["USD": 1.0, "EUR": 0.85]
        RateCache.shared.replace(with: fakeRates)
        defer { RateCache.shared.replace(with: [:]) }
        #expect(UnitConverter.convert(value: 100, from: "usd", to: "zzz") == nil)
    }

    @Test func commitCurrencyWithArrow() {
        let fakeRates: [String: Double] = ["USD": 1.0, "EUR": 0.85]
        RateCache.shared.replace(with: fakeRates)
        defer { RateCache.shared.replace(with: [:]) }
        let result = UnitConverter.commit("100 USD → eur")
        #expect(result == "100 USD → eur = 85")
    }
}
