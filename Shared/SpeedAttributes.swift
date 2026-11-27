import ActivityKit
import Foundation

struct SpeedAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var down: Double
        var up: Double
        var sampledAt: Date
        var sampleNumber: Int? = nil
        var pendingRelays: Int? = nil
        var totalRelays: Int? = nil
        var nextRelay: Date? = nil
        var alignedRelays: Int? = nil
        var lostSample: Bool? = nil
    }
    var sessionID: UUID? = nil
    var startedAt: Date
}

enum RateText {
    static func parts(_ bytes: Double) -> (String, String) {
        let v = max(0, bytes.isFinite ? bytes : 0)
        if v >= 1_000_000 {
            let n = v / 1_000_000
            return (String(format: n < 10 ? "%.1f" : "%.0f", n), "MB/s")
        }
        if v >= 1_000 {
            let n = v / 1_000
            return (String(format: n < 10 ? "%.1f" : "%.0f", n), "KB/s")
        }
        return (String(format: "%.0f", v), "B/s")
    }
}
