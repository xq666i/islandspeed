import Foundation
import Darwin

// Read physical-interface counters only: avoid double counting VPN tunnel traffic.
// 32-bit interface counters may wrap; compute each interface independently.
struct NetworkMeter {
    struct Count { var rx: UInt32; var tx: UInt32 }
    private var previous: [String: Count] = [:]
    private var last: ContinuousClock.Instant?

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

    mutating func sample() -> (down: Double, up: Double)? {
        sample(Self.counters(), at: .now)
    }

    mutating func sample(_ counters: [String: Count]?, at time: ContinuousClock.Instant) -> (down: Double, up: Double)? {
        guard let counters, !counters.isEmpty else {
            last = nil
            previous.removeAll()
            return nil
        }
        defer { previous = counters; last = time }
        guard let last else { return nil }
        let interval = last.duration(to: time)
        guard interval > .zero, interval < .seconds(5) else { return nil }
        let parts = interval.components
        let elapsed = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        var received: UInt64 = 0
        var sent: UInt64 = 0
        var measured = false
        for (name, current) in counters {
            guard let old = previous[name] else { continue }
            let rx = UInt64(current.rx &- old.rx)
            let tx = UInt64(current.tx &- old.tx)
            // Preserve the original wrap guard. A reset or a new interface needs a new baseline.
            guard Double(rx) / elapsed < 500_000_000, Double(tx) / elapsed < 500_000_000 else { continue }
            received += rx
            sent += tx
            measured = true
        }
        guard measured else { return nil }
        return (Double(received) / elapsed, Double(sent) / elapsed)
    }
}
