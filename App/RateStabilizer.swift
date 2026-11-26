import Foundation

// All thresholds are decimal bytes/s, matching RateText. The reference is the
// last submitted display, not the last sample, so slow drift eventually updates.
enum RateStabilizer {
    static func value(_ raw: Double, previous: Double?) -> Double {
        let v = max(0, raw.isFinite ? raw : 0)
        guard let p = previous, p.isFinite, p >= 0 else { return v }
        let old = RateText.parts(p), next = RateText.parts(v)
        if old.0 == next.0 && old.1 == next.1 { return p }
        // Always show unit changes immediately. Preserve weak-network precision.
        guard old.1 == next.1, let center = Double(old.0) else { return v }
        if v >= 500_000 && p >= 500_000 && v < 1_000_000 && p < 1_000_000 {
            return abs(v - center * 1_000) < 20_000 ? p : v
        }
        if v >= 1_000_000 && p >= 1_000_000 {
            let fractional = p < 10_000_000
            guard fractional == (v < 10_000_000) else { return v }
            let halfStep = fractional ? 50_000.0 : 500_000.0
            let margin = fractional ? 30_000.0 : 300_000.0
            return abs(v - center * 1_000_000) < halfStep + margin ? p : v
        }
        return v
    }
}
