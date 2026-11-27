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
    var buildIdentifier: String? = nil
}

enum RelayRecoveryLink {
    static func url(activityID: String) -> URL? {
        var components = URLComponents()
        components.scheme = "islandspeed"
        components.host = "relay"
        components.path = "/restore"
        components.queryItems = [URLQueryItem(name: "activity", value: activityID)]
        return components.url
    }

    static func activityID(from url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "islandspeed", components.host == "relay", components.path == "/restore",
              let items = components.queryItems, items.count == 1, items[0].name == "activity",
              let activityID = items[0].value, !activityID.isEmpty else { return nil }
        return activityID
    }
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
