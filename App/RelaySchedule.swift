import Foundation

enum RelaySchedule {
    static let capacity = 4
    static let minimumInterval = 120
    static let defaultInterval = 180
    static let intervalOptions = Array(stride(from: minimumInterval, through: 300, by: 30))

    // The grid belongs to the active activity, even after a delayed wake.
    static func dates(anchor: Date, interval: Int, now: Date) -> [Date] {
        let step = Double(max(1, interval))
        let first = floor(max(0, now.timeIntervalSince(anchor)) / step) + 1
        return (0..<capacity).map { anchor.addingTimeInterval((first + Double($0)) * step) }
    }

    // ActivityKit may round dates when storing an activity across launches.
    static func matches(_ lhs: Date, _ rhs: Date) -> Bool {
        abs(lhs.timeIntervalSince(rhs)) < 0.5
    }

    static func plan(anchor: Date, interval: Int, now: Date, existing: [Date], retiring: [Date] = [], available: Int = capacity)
        -> (matched: Int, next: Date?, release: Date?) {
        let desired = dates(anchor: anchor, interval: interval, now: now)
        let usual = plan(desired: desired, existing: existing, available: available)
        if let lastOld = retiring.max() {
            // Old appointments occupy slots, even when their times match the
            // new plan. Never create two appointments for the same time.
            let sameTime = usual.next.flatMap { next in retiring.first { matches($0, next) } }
            let needsSlot = existing.count + retiring.count >= available || usual.next == nil
            return (usual.matched, usual.next, sameTime ?? (needsSlot ? lastOld : nil))
        }
        // A manual handoff changes the anchor. Keep the existing cadence when
        // it preserves more appointments and its first handoff is no later.
        guard let first = existing.filter({ $0 > max(now, anchor) }).min(), first < desired[0] else { return usual }
        let step = Double(max(1, interval))
        let retainedDates = (0..<capacity).map { first.addingTimeInterval(Double($0) * step) }
        let retained = plan(desired: retainedDates, existing: existing, available: available)
        return retained.matched > usual.matched ? retained : usual
    }

    static func plan(desired: [Date], existing: [Date], available: Int = capacity) -> (matched: Int, next: Date?, release: Date?) {
        var unmatched = existing
        var missing: [Date] = []
        for date in desired {
            if let index = unmatched.firstIndex(where: { matches($0, date) }) {
                unmatched.remove(at: index)
            } else {
                missing.append(date)
            }
        }
        return (desired.count - missing.count, missing.first,
                existing.count >= available ? unmatched.max() : nil)
    }
}
