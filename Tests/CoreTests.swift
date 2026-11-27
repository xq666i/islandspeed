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
        precondition(RelaySchedule.intervalOptions == [120, 150, 180, 210, 240, 270, 300])
        precondition(RelaySchedule.defaultInterval == 240)
        let defaultDates = RelaySchedule.dates(anchor: anchor, interval: RelaySchedule.defaultInterval, now: anchor)
        precondition(defaultDates == [240, 480, 720, 960].map { anchor.addingTimeInterval(Double($0)) })

        func at(_ offset: Double) -> Date { anchor.addingTimeInterval(offset) }
        let renewedAt = at(30)
        let now = at(35)
        let kept = RelaySchedule.plan(anchor: renewedAt, interval: 180, now: now, existing: [at(180), at(360), at(540)])
        precondition(kept.matched == 3 && kept.next == at(720) && kept.release == nil)
        let full = RelaySchedule.plan(anchor: renewedAt, interval: 180, now: now, existing: [at(180), at(360), at(540), at(720)])
        precondition(full.matched == 4 && full.next == nil && full.release == nil)
        let missing = RelaySchedule.plan(anchor: renewedAt, interval: 180, now: now, existing: [at(180), at(540), at(720)])
        precondition(missing.matched == 3 && missing.next == at(360) && missing.release == nil)
        let late = RelaySchedule.plan(anchor: renewedAt, interval: 180, now: now, existing: [at(240), at(420), at(600)])
        precondition(late.matched == 0 && late.next == at(210))
        let betterGrid = RelaySchedule.plan(anchor: renewedAt, interval: 180, now: now, existing: [at(100), at(210), at(390), at(570)])
        precondition(betterGrid.matched == 3 && betterGrid.next == at(750) && betterGrid.release == at(100))
        let expired = RelaySchedule.plan(anchor: renewedAt, interval: 180, now: at(181), existing: [at(180), at(360), at(540)])
        precondition(expired.matched == 0 && expired.next == at(210))

        let reset = RelaySchedule.plan(anchor: renewedAt, interval: 180, now: now,
            existing: [], retiring: [at(180), at(360), at(540), at(720)])
        precondition(reset.matched == 0 && reset.next == at(210) && reset.release == at(720))
        let spare = RelaySchedule.plan(anchor: renewedAt, interval: 180, now: now,
            existing: [at(210)], retiring: [at(180)])
        precondition(spare.matched == 1 && spare.next == at(390) && spare.release == nil)
        let sameTime = RelaySchedule.plan(anchor: renewedAt, interval: 180, now: now,
            existing: [], retiring: [at(210.001), at(750)])
        precondition(sameTime.matched == 0 && sameTime.next == at(210) && sameTime.release == at(210.001))
        let reducedQuota = RelaySchedule.plan(anchor: renewedAt, interval: 180, now: now,
            existing: [at(210)], retiring: [at(180), at(360)], available: 3)
        precondition(reducedQuota.matched == 1 && reducedQuota.next == at(390) && reducedQuota.release == at(360))
        var oldQueue = [at(180), at(360), at(540), at(720)]
        var newQueue: [Date] = []
        for _ in 0..<RelaySchedule.capacity {
            let step = RelaySchedule.plan(anchor: renewedAt, interval: 180, now: now, existing: newQueue, retiring: oldQueue)
            guard let release = step.release, let next = step.next else { preconditionFailure("Expected to replace one appointment") }
            oldQueue.removeAll { $0 == release }
            newQueue.append(next)
            precondition(oldQueue.count + newQueue.count == RelaySchedule.capacity)
        }
        precondition(oldQueue.isEmpty && newQueue == [at(210), at(390), at(570), at(750)])
        print("PASS: weighted one-second window, gaps, interface changes, reset, counter wrap, fast links and relay allocation")
    }
}
