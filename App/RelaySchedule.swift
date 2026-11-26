import Foundation

// Use an absolute anchor so cleanup latency never shifts the next appointment.
// If cleanup takes more than an interval, skip elapsed slots rather than asking
// ActivityKit to create an appointment in the past.
enum RelaySchedule {
    static func dates(anchor: Date, interval: Int, count: Int, now: Date,
                      preserving: [Date] = []) -> [Date] {
        guard count > 0 else { return [] }
        let step = Double(max(1, interval))
        var result = Array(Set(preserving.filter { $0 > now })).sorted()
        if result.count >= count { return Array(result.prefix(count)) }
        var next: Date
        if let last = result.last {
            next = last.addingTimeInterval(step)
        } else {
            let elapsed = max(0, now.timeIntervalSince(anchor))
            let firstSlot = floor(elapsed / step) + 1
            next = anchor.addingTimeInterval(firstSlot * step)
        }
        while result.count < count {
            result.append(next)
            next = next.addingTimeInterval(step)
        }
        return result
    }
    // Return a single missing target and, only at capacity, the farthest
    // obsolete pending date. A caller must verify cancellation before creating.
    static func nextReplacement(desired: [Date], existing: [Date], capacity: Int) -> (date: Date, release: Date?)? {
        let wanted = Set(desired)
        let current = Set(existing)
        guard let date = desired.first(where: { !current.contains($0) }) else { return nil }
        let release = existing.count >= capacity ? existing.filter { !wanted.contains($0) }.max() : nil
        return (date, release)
    }
}
