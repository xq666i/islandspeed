import Foundation

enum RelaySchedule {
    static let capacity = 4

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
