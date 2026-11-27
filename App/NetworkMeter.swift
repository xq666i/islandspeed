import Foundation
#if canImport(Darwin)
import Darwin
#endif

// Read physical-interface counters only: avoid double counting VPN tunnel traffic.
// 32-bit interface counters may wrap; compute each interface independently.
struct NetworkMeter {
    struct Count { var rx: UInt32; var tx: UInt32 }
    private var previous: [String: Count] = [:]
    private var last: ContinuousClock.Instant?

    #if canImport(Darwin)
    static func counters() -> [String: Count]? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(first) }
        var current: UnsafeMutablePointer<ifaddrs>? = first
        var output: [String: Count] = [:]
        while let entry = current {
            let i = entry.pointee
            current = i.ifa_next
            guard let address = i.ifa_addr, Int32(address.pointee.sa_family) == AF_LINK,
                  let data = i.ifa_data, let rawName = i.ifa_name else { continue }
            let name = String(cString: rawName)
            // en0 is normally Wi-Fi; pdp_ip* are cellular data interfaces.
            // Other transports (USB, Ethernet etc.) aren't measured by this prototype.
            guard name == "en0" || name.hasPrefix("pdp_ip") else { continue }
            let d = data.assumingMemoryBound(to: if_data.self).pointee
            output[name] = Count(rx: UInt32(truncatingIfNeeded: d.ifi_ibytes), tx: UInt32(truncatingIfNeeded: d.ifi_obytes))
        }
        return output
    }

    mutating func sample() -> Interval? {
        sample(Self.counters(), at: .now)
    }

    #endif

    struct Interval {
        let start: ContinuousClock.Instant
        let end: ContinuousClock.Instant
        let received: UInt64
        let sent: UInt64
    }

    mutating func sample(_ counters: [String: Count]?, at time: ContinuousClock.Instant) -> Interval? {
        guard let counters, !counters.isEmpty else {
            last = nil
            previous.removeAll()
            return nil
        }
        defer { previous = counters; last = time }
        guard let last else { return nil }
        let interval = last.duration(to: time)
        guard interval > .zero, interval <= .seconds(2) else { return nil }
        var received: UInt64 = 0
        var sent: UInt64 = 0
        var measured = false
        for (name, current) in counters {
            guard let old = previous[name] else { continue }
            let rx = UInt64(current.rx &- old.rx)
            let tx = UInt64(current.tx &- old.tx)
            // Only a backwards counter needs a wrap plausibility check. Do not
            // discard fast, monotonically increasing counters on modern links.
            let wrapLimit = interval / .seconds(1) * 1_250_000_000
            guard (current.rx >= old.rx || Double(rx) <= wrapLimit),
                  (current.tx >= old.tx || Double(tx) <= wrapLimit) else { continue }
            received += rx
            sent += tx
            measured = true
        }
        guard measured else { return nil }
        return Interval(start: last, end: time, received: received, sent: sent)
    }
}

// Average the bytes carried in the last second. A sample crossing the window
// boundary contributes only the fraction of its interval inside the window.
struct RateWindow {
    private var intervals: [NetworkMeter.Interval] = []

    mutating func append(_ sample: NetworkMeter.Interval) -> (down: Double, up: Double) {
        if let previous = intervals.last, previous.end != sample.start { intervals.removeAll() }
        let cutoff = sample.end.advanced(by: .seconds(-1))
        intervals.removeAll { $0.end <= cutoff }
        intervals.append(sample)
        var received = 0.0, sent = 0.0
        for item in intervals {
            let covered = max(cutoff, item.start).duration(to: item.end)
            let fraction = covered / item.start.duration(to: item.end)
            received += Double(item.received) * fraction
            sent += Double(item.sent) * fraction
        }
        let elapsed = max(cutoff, intervals[0].start).duration(to: sample.end) / .seconds(1)
        return (received / elapsed, sent / elapsed)
    }
}
