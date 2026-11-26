import Foundation

/// Frecency: how often and how recently a page was visited, as one number for ranking.
///
/// Each visit adds `weight` to a score that decays exponentially with a fixed half-life. The score
/// at time `now` is `sum(weight_i * exp(-rate * (now - t_i)))`. That equals
/// `exp(-rate * now) * sum(weight_i * exp(rate * t_i))`, and the first factor is the same for every
/// page, so pages can be ranked by the time-independent part alone. Plain stores that part as a
/// log (`key`), updates it once per visit, and never recomputes stored values as time passes.
public enum Frecency {
    static let rate = log(2) / FixedChoices.frecencyHalfLife

    /// The key after one more visit at `date`. Pass nil for a page's first visit.
    public static func adding(visitAt date: Date, weight: Double = 1, to key: Double?) -> Double {
        let visit = rate * date.timeIntervalSinceReferenceDate + log(weight)
        guard let key else { return visit }
        // log(exp(a) + exp(b)) without overflow.
        let high = max(key, visit), low = min(key, visit)
        return high + log1p(exp(low - high))
    }

    /// The decayed score at `now`: 1.0 for one visit just now, 0.5 for one visit a half-life ago.
    /// Use it to show or threshold scores; rank by `key` directly.
    public static func score(key: Double, now: Date) -> Double {
        exp(key - rate * now.timeIntervalSinceReferenceDate)
    }
}
