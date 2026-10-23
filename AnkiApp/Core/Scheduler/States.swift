import Foundation

/// Port of Anki's v3 SM-2 scheduling states (rslib/src/scheduler/states).

struct LearnState: Equatable {
    var remainingSteps: Int
    var scheduledSecs: Int
}

struct ReviewState: Equatable {
    var scheduledDays: Int
    var elapsedDays: Int
    var easeFactor: Double
    var lapses: Int
    var leeched: Bool = false

    var daysLate: Int { elapsedDays - scheduledDays }
}

enum IntervalKind: Equatable {
    case secs(Int)
    case days(Int)

    func maybeAsDays(_ secsUntilRollover: Int) -> IntervalKind {
        if case .secs(let s) = self, s >= secsUntilRollover {
            return .days((s - secsUntilRollover) / 86_400 + 1)
        }
        return self
    }

    var seconds: Int {
        switch self {
        case .secs(let s): return s
        case .days(let d): return d * 86_400
        }
    }

    var revlogInterval: Int {
        switch self {
        case .days(let d): return d
        case .secs(let s): return -s
        }
    }
}

enum CardState: Equatable {
    case new(position: Int)
    case learning(LearnState)
    case review(ReviewState)
    case relearning(LearnState, ReviewState)

    var intervalKind: IntervalKind {
        switch self {
        case .new: return .secs(0)
        case .learning(let l): return .secs(l.scheduledSecs)
        case .review(let r): return .days(r.scheduledDays)
        case .relearning(let l, _): return .secs(l.scheduledSecs)
        }
    }

    var revlogKind: Int {
        switch self {
        case .new, .learning: return 0
        case .review(let r): return r.daysLate < 0 ? 3 : 1
        case .relearning: return 2
        }
    }

    var reviewState: ReviewState? {
        switch self {
        case .review(let r): return r
        case .relearning(_, let r): return r
        default: return nil
        }
    }

    var leeched: Bool { reviewState?.leeched ?? false }
}

struct SchedulingStates {
    var current: CardState
    var again: CardState
    var hard: CardState
    var good: CardState
    var easy: CardState

    func state(for rating: Int) -> CardState {
        switch rating {
        case 1: return again
        case 2: return hard
        case 3: return good
        default: return easy
        }
    }
}

struct LearningSteps {
    let steps: [Double]

    private func toSecs(_ v: Double) -> Int { Int(v * 60) }

    private func index(_ remaining: Int) -> Int {
        let total = steps.count
        return min(max(0, total - (remaining % 1000)), max(0, total - 1))
    }

    private func secs(at i: Int) -> Int? { i >= 0 && i < steps.count ? toSecs(steps[i]) : nil }

    var againDelaySecs: Int? { secs(at: 0) }

    func hardDelaySecs(_ remaining: Int) -> Int? {
        let idx = index(remaining)
        guard let current = secs(at: idx) ?? steps.first.map(toSecs) else { return nil }
        if idx == 0 {
            if let next = secs(at: 1) {
                return roundInDays((current + next) / 2)
            }
            return roundInDays(min(current * 3 / 2, current + 86_400))
        }
        return current
    }

    func goodDelaySecs(_ remaining: Int) -> Int? { secs(at: index(remaining) + 1) }
    func currentDelaySecs(_ remaining: Int) -> Int { secs(at: index(remaining)) ?? 0 }
    func remainingForGood(_ remaining: Int) -> Int { max(0, steps.count - (index(remaining) + 1)) }
    var remainingForFailed: Int { steps.count }

    private func roundInDays(_ secs: Int) -> Int {
        secs > 86_400 ? Int((Double(secs) / 86_400).rounded()) * 86_400 : secs
    }
}

struct StateContext {
    var fuzzFactor: Double?
    var steps: LearningSteps
    var relearnSteps: LearningSteps
    var graduatingGood: Int
    var graduatingEasy: Int
    var initialEase: Double
    var hardMultiplier: Double
    var easyMultiplier: Double
    var intervalMultiplier: Double
    var maximumInterval: Int
    var leechThreshold: Int
    var lapseMultiplier: Double
    var minimumLapseInterval: Int

    init(config c: DeckConfig, fuzzFactor: Double?) {
        self.fuzzFactor = fuzzFactor
        steps = LearningSteps(steps: c.learnSteps)
        relearnSteps = LearningSteps(steps: c.relearnSteps)
        graduatingGood = c.graduatingGood
        graduatingEasy = c.graduatingEasy
        initialEase = c.initialEase
        hardMultiplier = c.hardMultiplier
        easyMultiplier = c.easyMultiplier
        intervalMultiplier = c.intervalMultiplier
        maximumInterval = c.maximumInterval
        leechThreshold = c.leechThreshold
        lapseMultiplier = c.lapseMultiplier
        minimumLapseInterval = c.minimumLapseInterval
    }

    func minMax(_ minimum: Int) -> (Int, Int) {
        let maximum = max(1, maximumInterval)
        return (min(max(minimum, 1), maximum), maximum)
    }

    func withFuzz(_ interval: Double, _ minimum: Int, _ maximum: Int) -> Int {
        Fuzz.apply(fuzzFactor, interval, minimum, maximum)
    }

    // MARK: Next states

    func nextStates(_ current: CardState) -> SchedulingStates {
        switch current {
        case .new:
            let s = learningNext(LearnState(remainingSteps: steps.remainingForFailed, scheduledSecs: 0))
            return SchedulingStates(current: current, again: s.again, hard: s.hard, good: s.good, easy: s.easy)
        case .learning(let l):
            var s = learningNext(l)
            s.current = current
            return s
        case .review(let r):
            return reviewNext(r)
        case .relearning(let l, let r):
            return relearningNext(l, r)
        }
    }

    private func learningNext(_ l: LearnState) -> SchedulingStates {
        let (minimum, maximum) = minMax(1)
        func graduate() -> CardState {
            .review(ReviewState(scheduledDays: withFuzz(Double(graduatingGood), minimum, maximum), elapsedDays: 0,
                                easeFactor: initialEase, lapses: 0))
        }
        let again: CardState = steps.againDelaySecs.map {
            .learning(LearnState(remainingSteps: steps.remainingForFailed, scheduledSecs: $0))
        } ?? graduate()
        let hard: CardState = steps.hardDelaySecs(l.remainingSteps).map {
            .learning(LearnState(remainingSteps: l.remainingSteps, scheduledSecs: $0))
        } ?? graduate()
        let good: CardState = steps.goodDelaySecs(l.remainingSteps).map {
            .learning(LearnState(remainingSteps: steps.remainingForGood(l.remainingSteps), scheduledSecs: $0))
        } ?? graduate()
        let easy: CardState = .review(ReviewState(
            scheduledDays: withFuzz(Double(graduatingEasy), minimum, maximum), elapsedDays: 0,
            easeFactor: initialEase, lapses: 0))
        return SchedulingStates(current: .learning(l), again: again, hard: hard, good: good, easy: easy)
    }

    func failingReviewInterval(_ r: ReviewState) -> Double {
        let (minimum, maximum) = minMax(minimumLapseInterval)
        return Double(withFuzz(Double(max(r.scheduledDays, 1)) * lapseMultiplier, minimum, maximum))
    }

    private func reviewNext(_ r: ReviewState) -> SchedulingStates {
        let (hardIvl, goodIvl, easyIvl) = passingIntervals(r)
        let lapses = r.lapses + 1
        let leeched = Fuzz.leechThresholdMet(lapses, leechThreshold)
        let scheduledDays = failingReviewInterval(r)
        let againReview = ReviewState(
            scheduledDays: max(1, Int(scheduledDays.rounded())), elapsedDays: 0,
            easeFactor: max(r.easeFactor - 0.2, 1.3), lapses: lapses, leeched: leeched)
        let again: CardState = relearnSteps.againDelaySecs.map {
            .relearning(LearnState(remainingSteps: relearnSteps.remainingForFailed, scheduledSecs: $0), againReview)
        } ?? .review(againReview)

        var hard = r
        hard.scheduledDays = hardIvl
        hard.elapsedDays = 0
        hard.easeFactor = max(r.easeFactor - 0.15, 1.3)
        hard.leeched = false
        var good = r
        good.scheduledDays = goodIvl
        good.elapsedDays = 0
        good.leeched = false
        var easy = r
        easy.scheduledDays = easyIvl
        easy.elapsedDays = 0
        easy.easeFactor = r.easeFactor + 0.15
        easy.leeched = false
        return SchedulingStates(current: .review(r), again: again, hard: .review(hard), good: .review(good), easy: .review(easy))
    }

    private func passingIntervals(_ r: ReviewState) -> (Int, Int, Int) {
        if r.daysLate < 0 {
            let scheduled = Double(max(r.scheduledDays, 1))
            let elapsed = Double(r.elapsedDays)
            let hard = constrain(max(elapsed * hardMultiplier, scheduled * hardMultiplier / 2), 0, fuzz: false)
            let good = constrain(max(elapsed * r.easeFactor, scheduled), 0, fuzz: false)
            let reducedBonus = easyMultiplier - (easyMultiplier - 1) / 2
            let easy = constrain(max(elapsed * r.easeFactor, scheduled) * reducedBonus, 0, fuzz: false)
            return (hard, good, easy)
        }
        let current = Double(max(r.scheduledDays, 1))
        let daysLate = Double(max(r.daysLate, 0))
        let hardMinimum = hardMultiplier <= 1 ? 0 : r.scheduledDays + 1
        let hard = constrain(current * hardMultiplier, hardMinimum, fuzz: true)
        let goodMinimum = hardMultiplier <= 1 ? r.scheduledDays + 1 : hard + 1
        let good = constrain((current + daysLate / 2) * r.easeFactor, goodMinimum, fuzz: true)
        let easy = constrain((current + daysLate) * r.easeFactor * easyMultiplier, good + 1, fuzz: true)
        return (hard, good, easy)
    }

    private func constrain(_ interval: Double, _ minimum: Int, fuzz: Bool) -> Int {
        let ivl = interval * intervalMultiplier
        let (minimum, maximum) = minMax(minimum)
        if fuzz { return withFuzz(ivl, minimum, maximum) }
        return min(max(Int(ivl.rounded()), minimum), maximum)
    }

    private func relearningNext(_ l: LearnState, _ r: ReviewState) -> SchedulingStates {
        let scheduledDays = failingReviewInterval(r)
        let again: CardState
        if let delay = relearnSteps.againDelaySecs {
            var review = r
            review.scheduledDays = max(1, Int(scheduledDays.rounded()))
            review.elapsedDays = 0
            again = .relearning(LearnState(remainingSteps: relearnSteps.remainingForFailed, scheduledSecs: delay), review)
        } else {
            again = .review(r)
        }
        let hard: CardState
        if let delay = relearnSteps.hardDelaySecs(l.remainingSteps) {
            var review = r
            review.elapsedDays = 0
            hard = .relearning(LearnState(remainingSteps: l.remainingSteps, scheduledSecs: delay), review)
        } else {
            hard = .review(r)
        }
        let good: CardState
        if let delay = relearnSteps.goodDelaySecs(l.remainingSteps) {
            var review = r
            review.elapsedDays = 0
            good = .relearning(LearnState(remainingSteps: relearnSteps.remainingForGood(l.remainingSteps), scheduledSecs: delay), review)
        } else {
            good = .review(r)
        }
        var easyReview = r
        easyReview.scheduledDays = r.scheduledDays + 1
        easyReview.elapsedDays = 0
        return SchedulingStates(current: .relearning(l, r), again: again, hard: hard, good: good, easy: .review(easyReview))
    }
}

enum Fuzz {
    private static let ranges: [(start: Double, end: Double, factor: Double)] = [
        (2.5, 7.0, 0.15), (7.0, 20.0, 0.1), (20.0, .greatestFiniteMagnitude, 0.05),
    ]

    static func apply(_ factor: Double?, _ interval: Double, _ minimum: Int, _ maximum: Int) -> Int {
        guard let factor else { return min(max(Int(interval.rounded()), minimum), maximum) }
        let (lower, upper) = bounds(interval, minimum, maximum)
        return Int((Double(lower) + factor * Double(1 + upper - lower)).rounded(.down))
    }

    static func bounds(_ interval: Double, _ minimum: Int, _ maximum: Int) -> (Int, Int) {
        let minimum = min(minimum, maximum)
        let ivl = min(max(interval, Double(minimum)), Double(maximum))
        let delta = ivl < 2.5 ? 0 : ranges.reduce(1.0) { d, r in d + r.factor * max(min(ivl, r.end) - r.start, 0) }
        var lower = Int((ivl - delta).rounded())
        var upper = Int((ivl + delta).rounded())
        lower = min(max(lower, minimum), maximum)
        upper = min(max(upper, minimum), maximum)
        if upper == lower, upper > 2, upper < maximum { upper = lower + 1 }
        return (lower, upper)
    }

    static func leechThresholdMet(_ lapses: Int, _ threshold: Int) -> Bool {
        guard threshold > 0 else { return false }
        let half = max(1, Int((Double(threshold) / 2).rounded(.up)))
        return lapses >= threshold && (lapses - threshold) % half == 0
    }

    /// A stable pseudo-random factor in [0, 1) per card and review count,
    /// like Anki's fuzz seed, so intervals shown match what is applied.
    static func factor(cardID: Int64, reps: Int) -> Double {
        var z = UInt64(bitPattern: cardID) &+ UInt64(reps) &* 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z = z ^ (z >> 31)
        return Double(z >> 11) / Double(1 << 53)
    }
}
