import Foundation
import Testing
@testable import antimatter

struct IntentTimerTests {

    @Test func bareNumberMeansMinutes() {
        #expect(IntentParser.parseTimer(".timer 5") == IntentParser.Timer(duration: 300, label: "", name: nil, fullScreen: false))
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

    @Test func oversizedDurationsAreClampedAndFlagged() {
        let clamped = IntentParser.parseTimer(".timer 100d")
        #expect(clamped?.duration == IntentParser.maxDuration)
        #expect(clamped?.clamped == true)
        #expect(IntentParser.parseTimer(".timer 5")?.clamped == false)
    }

    @Test func remainderBecomesTheLabel() {
        #expect(IntentParser.parseTimer(".timer 5 laundry") == IntentParser.Timer(duration: 300, label: "laundry", name: nil, fullScreen: false))
        #expect(IntentParser.parseTimer(".timer 1h 20m stand up") == IntentParser.Timer(duration: 4_800, label: "stand up", name: nil, fullScreen: false))
    }

    @Test func keywordIsCaseInsensitive() {
        #expect(IntentParser.parseTimer(".TIMER 5") != nil)
        #expect(IntentParser.parseTimer(".Timer 30s stretch") != nil)
    }

    @Test func fullUnitWordsAreHonoured() {
        #expect(IntentParser.parseTimer(".timer 5 minutes")?.duration == 300)
        #expect(IntentParser.parseTimer(".timer 5 mins")?.duration == 300)
        #expect(IntentParser.parseTimer(".timer 2 hours")?.duration == 7_200)
        #expect(IntentParser.parseTimer(".timer 1 hour 30 minutes")?.duration == 5_400)
        #expect(IntentParser.parseTimer(".timer 3 days")?.duration == 259_200)
        #expect(IntentParser.parseTimer(".timer 45 seconds")?.duration == 45)
    }

    @Test func spacedNumberAndUnitLeaveTheLabelIntact() {
        #expect(IntentParser.parseTimer(".timer 5 mins stand up") == IntentParser.Timer(duration: 300, label: "stand up", name: nil, fullScreen: false))
        #expect(IntentParser.parseTimer(".timer 90 minutes tea")?.label == "tea")
    }

    @Test func timerCancelForms() {
        #expect(IntentParser.isTimerCancel(".timer cancel") == true)
        #expect(IntentParser.isTimerCancel(".timer cancel all") == true)
        #expect(IntentParser.isTimerCancel(".TIMER CANCEL ALL") == true)
        #expect(IntentParser.isTimerCancel(".timer 5") == false)
        #expect(IntentParser.isTimerCancel(".timer cancel xyz") == false)
    }

    @Test func nonTimersStayNil() {
        // A bare "timer" is just a word now; only the dot-command fires.
        for line in ["timer", "timer abc", "timer 0", "timers 5", "remind me at 5", "timer 5"] {
            #expect(IntentParser.parseTimer(line) == nil, "\(line) should not be a timer")
        }
    }

    @Test func namedTimersExtractName() {
        let named = IntentParser.parseTimer(".timer 5 soup name Dinner")
        #expect(named?.label == "soup")
        #expect(named?.name == "Dinner")
        let multiWord = IntentParser.parseTimer(".timer 10 work name Focus Session")
        #expect(multiWord?.label == "work")
        #expect(multiWord?.name == "Focus Session")
    }

    @Test func fullScreenKeywordIsRecognized() {
        let fs = IntentParser.parseTimer(".timer 5 soup full-screen")
        #expect(fs?.label == "soup")
        #expect(fs?.fullScreen == true)
        let noFs = IntentParser.parseTimer(".timer 5 soup")
        #expect(noFs?.fullScreen == false)
    }
}

struct IntentPomodoroTests {

    @Test func basicPomodoroParses() {
        let p = IntentParser.parsePomodoro(".pomodoro 25/5/4")
        #expect(p?.workDuration == 1500)
        #expect(p?.breakDuration == 300)
        #expect(p?.cycles == 4)
    }

    @Test func defaultCycleCount() {
        let p = IntentParser.parsePomodoro(".pomodoro 50/10")
        #expect(p?.workDuration == 3000)
        #expect(p?.breakDuration == 600)
        #expect(p?.cycles == 4)
    }

    @Test func cyclesAreCapped() {
        let p = IntentParser.parsePomodoro(".pomodoro 25/5/20")
        #expect(p?.cycles == 12)
    }

    @Test func nonPomodoroLinesStayNil() {
        #expect(IntentParser.parsePomodoro(".timer 5") == nil)
        #expect(IntentParser.parsePomodoro("pomodoro 25/5") == nil)
        #expect(IntentParser.parsePomodoro(".pomodoro") == nil)
    }
}

struct IntentStopwatchTests {

    @Test func bareCommandStartsOne() {
        #expect(IntentParser.isStopwatch(".stopwatch"))
        #expect(IntentParser.stopwatchLabel(".stopwatch") == "")
        #expect(!IntentParser.isStopwatchCancel(".stopwatch"))
    }

    @Test func labelIsTheRemainder() {
        #expect(IntentParser.isStopwatch(".stopwatch soup"))
        #expect(IntentParser.stopwatchLabel(".stopwatch soup") == "soup")
        #expect(IntentParser.stopwatchLabel(".STOPWATCH pasta") == "pasta")
        #expect(IntentParser.stopwatchLabel(".stopwatch read a book") == "read a book")
    }

    @Test func cancelForms() {
        #expect(IntentParser.isStopwatchCancel(".stopwatch cancel"))
        #expect(IntentParser.isStopwatchCancel(".stopwatch cancel all"))
        #expect(IntentParser.isStopwatchCancel(".STOPWATCH CANCEL ALL"))
        #expect(!IntentParser.isStopwatchCancel(".stopwatch"))
        #expect(!IntentParser.isStopwatchCancel(".stopwatch cancel xyz"))
    }

    @Test func nonStopwatchesAreRejected() {
        for line in ["stopwatch", "stopwatch soup", ".stop", ".timer", ".stopwatchfoo"] {
            #expect(!IntentParser.isStopwatch(line), "\(line) should not be a stopwatch")
            #expect(!IntentParser.isStopwatchCancel(line), "\(line) should not be a cancel")
        }
    }
}

struct IntentCalculationTests {


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
        #expect(IntentParser.parseCalculation("1.") == nil)          // bare number, not a calculation
        #expect(IntentParser.parseCalculation("1 / 0") == nil)       // not finite
        #expect(IntentParser.parseCalculation("") == nil)
        #expect(IntentParser.parseCalculation("(2+3") == nil)        // unbalanced
        #expect(IntentParser.parseCalculation("2(3+4)") == nil)      // no implicit multiplication
        #expect(IntentParser.parseCalculation("1.2.3 + 1") == nil)
    }


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

    @Test func bareNumberDetection() {
        #expect(ExpressionEvaluator.isBareNumber("42"))
        #expect(ExpressionEvaluator.isBareNumber("3.14"))
        #expect(ExpressionEvaluator.isBareNumber("-5"))
        #expect(!ExpressionEvaluator.isBareNumber("1 + 2"))
        #expect(!ExpressionEvaluator.isBareNumber("sqrt(4)"))
        #expect(!ExpressionEvaluator.isBareNumber(""))
        #expect(!ExpressionEvaluator.isBareNumber("hello"))
    }
}

struct ReminderIntentTests {
    private let fixedNow = Date(timeIntervalSince1970: 1_789_000_000) // 2026-08 UTC

    @Test func relativeMinutes() throws {
        let result = try #require(ReminderIntent.parse(".remind in 10 mins stand up", now: fixedNow))
        #expect(result.message == "stand up")
        #expect(abs(result.date.timeIntervalSince(fixedNow) - 600) < 1)
    }

    @Test func relativeHoursAndSingleUnits() throws {
        let hours = try #require(ReminderIntent.parse(".remind in 2h deploy", now: fixedNow))
        #expect(abs(hours.date.timeIntervalSince(fixedNow) - 7_200) < 1)

        let aMinute = try #require(ReminderIntent.parse(".remind in a minute blink", now: fixedNow))
        #expect(abs(aMinute.date.timeIntervalSince(fixedNow) - 60) < 1)

        let aDay = try #require(ReminderIntent.parse(".remind in a day stretch", now: fixedNow))
        #expect(abs(aDay.date.timeIntervalSince(fixedNow) - 86_400) < 1)
    }

    @Test func absoluteTimesWork() throws {
        let result = try #require(ReminderIntent.parse(".remind tomorrow call mom"))
        let calendar = Calendar.current
        let dayDelta = calendar.dateComponents([.day], from: calendar.startOfDay(for: Date()), to: calendar.startOfDay(for: result.date)).day
        #expect(dayDelta == 1)
        #expect(result.message == "call mom")
    }

    @Test func quotedMessagesStayVerbatim() throws {
        let result = try #require(ReminderIntent.parse(".remind in 10 mins \"water the plants\"", now: fixedNow))
        #expect(result.message == "water the plants")
    }

    @Test func toGlueIsDropped() throws {
        let result = try #require(ReminderIntent.parse(".remind me in 10 minutes to stretch", now: fixedNow))
        #expect(result.message == "stretch")
    }

    @Test func cancelAllForms() {
        #expect(ReminderIntent.isCancelAll(".reminder cancel") == true)
        #expect(ReminderIntent.isCancelAll(".reminder cancel all") == true)
        #expect(ReminderIntent.isCancelAll(".remind cancel") == true)
        #expect(ReminderIntent.isCancelAll(".remind cancel all") == true)
        #expect(ReminderIntent.isCancelAll(".REMINDER CANCEL ALL") == true)
        #expect(ReminderIntent.isCancelAll(".reminder cancel xyz") == false)
        #expect(ReminderIntent.isCancelAll(".remind in 10 mins call mom") == false)
    }

    @Test func missingPartsAreRejected() {
        #expect(ReminderIntent.parse(".remind", now: fixedNow) == nil)
        #expect(ReminderIntent.parse(".remind in 10 mins", now: fixedNow) == nil)
        #expect(ReminderIntent.parse(".timer 5", now: fixedNow) == nil)
        #expect(ReminderIntent.parse("hello reminder", now: fixedNow) == nil)
    }
}
