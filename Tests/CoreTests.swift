import Foundation

@main enum CoreTests {
    static func main() {
        let start = ContinuousClock.now
        var meter = NetworkMeter()
        var window = RateWindow()
        func read(_ ms: Int, _ rx: UInt32, _ tx: UInt32 = 0, on name: String = "en0") -> NetworkMeter.Interval? {
            meter.sample([name: .init(rx: rx, tx: tx)], at: start.advanced(by: .milliseconds(ms)))
        }
        func near(_ a: Double, _ b: Double) { precondition(abs(a - b) < 0.0001, "\(a) != \(b)") }
        precondition(read(0, 0) == nil)
        _ = window.append(read(100, 1_000, 100)!)
        let oneSecond = window.append(read(1_000, 1_000, 1_000)!)
        near(oneSecond.down, 1_000); near(oneSecond.up, 1_000)
        let next = window.append(read(1_050, 1_000, 1_000)!)
        near(next.down, 500); near(next.up, 950)
        precondition(read(3_501, 20_000) == nil)
        let afterGap = window.append(read(3_751, 21_000)!)
        near(afterGap.down, 4_000)
        precondition(read(4_001, 100, on: "pdp_ip0") == nil)
        precondition(read(4_251, 0, on: "pdp_ip0") == nil)
        precondition(read(4_501, 150_000_000, on: "pdp_ip0")!.received == 150_000_000)
        meter = NetworkMeter()
        precondition(read(0, UInt32.max - 20) == nil)
        precondition(read(250, 19)!.received == 40)
        precondition(meter.sample(nil, at: start.advanced(by: .milliseconds(500))) == nil)
        precondition(read(750, 20) == nil)

        let anchor = Date(timeIntervalSince1970: 42.125)
        let dates = RelaySchedule.dates(anchor: anchor, interval: 60, now: anchor.addingTimeInterval(121))
        precondition(dates == [180, 240, 300, 360].map { anchor.addingTimeInterval(Double($0)) })
        let plan = RelaySchedule.plan(desired: dates, existing: [dates[0], dates[0], dates[1].addingTimeInterval(0.001), dates[3]])
        precondition(plan.matched == 3 && plan.next == dates[2] && plan.release == dates[0])
        let limited = RelaySchedule.plan(desired: dates, existing: [dates[0], anchor], available: 2)
        precondition(limited.matched == 1 && limited.next == dates[1] && limited.release == anchor)
        precondition(RelaySchedule.plan(desired: dates, existing: dates).next == nil)
        print("PASS: weighted one-second window, gaps, interface changes, reset, counter wrap, fast links and relay allocation")
    }
}
