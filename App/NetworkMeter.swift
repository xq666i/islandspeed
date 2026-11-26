import Foundation
import Darwin

// Read physical-interface counters only: avoid double counting VPN tunnel traffic.
// 32-bit interface counters may wrap; compute each interface independently.
struct NetworkMeter {
    struct Count { var rx: UInt32; var tx: UInt32 }
    private var previous: [String: Count] = [:]
    private var last: TimeInterval?

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
        guard let now = Self.counters() else { previous = [:]; last = nil; return nil }
        let t = ProcessInfo.processInfo.systemUptime
        defer { previous = now; last = t }
        guard let last, t > last, t - last < 5 else { return nil }
        var rx: UInt64 = 0, tx: UInt64 = 0
        for (name, count) in now {
            guard let old = previous[name] else { continue }
            // A counter reset can look like a wrap; reject implausible wrap rates.
            let dr = UInt64(count.rx &- old.rx), dt = UInt64(count.tx &- old.tx)
            if Double(dr) / (t-last) < 500_000_000 { rx += dr }
            if Double(dt) / (t-last) < 500_000_000 { tx += dt }
        }
        return (Double(rx) / (t-last), Double(tx) / (t-last))
    }
}
