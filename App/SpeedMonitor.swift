import ActivityKit
import CoreLocation
import Foundation
import SwiftUI
import UIKit

@MainActor final class SpeedMonitor: ObservableObject {
    static let samplesPerSecond = 4
    @Published private(set) var down: Double = 0
    @Published private(set) var up: Double = 0
    @Published private(set) var running = false
    @Published private(set) var status = "尚未开启"
    @Published private(set) var permission = "检查定位权限"
    @Published private(set) var authorized = false
    @Published private(set) var permissionButton = "申请定位权限"
    @Published private(set) var permissionHint = "定位为可选；不授权也可直接开启灵动岛。"
    @Published private(set) var locationStatus = "未开启"
    @Published private(set) var sampleCount = 0
    @Published private(set) var submitCount = 0
    @Published private(set) var lastSample: Date?
    @Published private(set) var lastSubmit: Date?
    @Published private(set) var lastGap: Double = 0
    @Published private(set) var backgroundReport = "尚未进行后台测试"
    @Published var refreshInterval = 1
    @Published var foregroundRenew = true
    @Published var heartbeat = 0 // 0: submit only when the visible value changes
    @Published var adaptive = false
    @Published var timestamped = true
    @Published var relevance = 100
    @Published var staleSeconds = 60
    @Published private(set) var effectiveInterval = 1
    @Published private(set) var activityState = "未开启"
    @Published private(set) var renewCount = 0
    @Published private(set) var renewStatus = "尚未重建"
    @Published private(set) var activityAge = 0
    @Published private(set) var lastLatency = 0.0
    @Published private(set) var attemptCount = 0
    @Published private(set) var unchangedChecks = 0
    @Published private(set) var lastPublishedValue = "—"
    @Published var useLocation = true { didSet { refreshLocation() } }
    private let location = LocationSession()
    private var activityStarted: ContinuousClock.Instant?
    private var lastAttempt: ContinuousClock.Instant?
    private var lastKey: String?
    private var updateTask: Task<Void, Never>?
    private var inFlightSince: ContinuousClock.Instant?
    private var renewTask: Task<Void, Never>?
    private var retiring: Activity<SpeedAttributes>?
    private var sessionID = UUID()
    private let renewalAge: Duration = .seconds(60)
    private var foregroundRenewTask: Task<Void, Never>?
    private var lastCheck: ContinuousClock.Instant?
    private var lastPublishedPolicy: String?
    private var lastValidInstant: ContinuousClock.Instant?
    private var meter = NetworkMeter()
    private var activity: Activity<SpeedAttributes>?
    private var sampling: Task<Void, Never>?
    private var publishing: Task<Void, Never>?
    private var starting = false
    private var lastTick: ContinuousClock.Instant?
    private var samples: [(down: Double, up: Double)] = []
    private var baseline: (samples: Int, submits: Int, date: Date)?

    init() {
        location.onChange = { [weak self] in self?.refreshLocation() }
        refreshLocation()
    }
    func requestPermission() {
        switch location.authorization {
        case .notDetermined:
            permissionHint = "已请求定位权限。请在系统弹窗选择使用 App 期间允许（不要选仅允许一次），之后可申请始终允许。"
            location.requestPermission()
        case .authorizedWhenInUse:
            permissionHint = "已请求升级为始终允许。系统可能延迟或不再显示弹窗；可点击打开系统设置检查权限。"
            location.requestPermission()
        case .denied, .restricted:
            permissionHint = "定位未授权或受限，请在系统设置中检查。仍可直接开启网速。"
            openSettings()
        case .authorizedAlways:
            permissionHint = "已获得始终允许定位。"
        @unknown default:
            permissionHint = "未知定位状态，请检查系统设置。"
            openSettings()
        }
        refreshLocation()
    }
    func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }
    private func refreshLocation() {
        authorized = location.authorization == .authorizedAlways
        switch location.authorization {
        case .notDetermined:
            permission = "尚未授权"
            permissionButton = "申请定位权限"
        case .authorizedWhenInUse:
            permission = "使用期间允许（可尝试后台定位）"
            permissionButton = "升级为始终允许"
        case .authorizedAlways:
            permission = "始终允许"
            permissionHint = "已获得始终允许定位。"
        case .denied, .restricted:
            permission = "定位不可用，请检查系统设置"
            permissionButton = "前往设置授权"
        @unknown default:
            permission = "未知权限"
            permissionButton = "前往设置检查"
        }
        if let error = location.error, location.active { locationStatus = error }
        else if let date = location.lastEvent, location.active { locationStatus = "最近定位回调：\(date.formatted(.dateTime.hour().minute().second()))" }
        else if location.active { locationStatus = "定位服务已启动，等待回调" }
        else if running && !useLocation { locationStatus = "定位辅助已关闭" }
        else if running && !location.canUseLocation { locationStatus = "无定位辅助，切换到后台后可能暂停采样" }
        else { locationStatus = "未开启" }
        // Location assistance is optional and must never end an active Live Activity.
        // Start only in the foreground; authorization changes can arrive during a system prompt.
        if running && useLocation && location.canUseLocation && !location.active && UIApplication.shared.applicationState == .active {
            location.start()
        } else if location.active && (!running || !useLocation || !location.canUseLocation) {
            location.stop()
        }
    }
    func start() async {
        guard !running, !starting else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { status = "请允许实时活动"; return }
        starting = true; defer { starting = false }
        for old in Activity<SpeedAttributes>.activities { await old.end(nil, dismissalPolicy: .immediate) }
        let now = Date()
        do {
            activity = try Activity.request(attributes: SpeedAttributes(startedAt: now), content: ActivityContent(state: .init(down: 0, up: 0, sampledAt: now, sampleNumber: 0), staleDate: expiry(from: now), relevanceScore: Double(relevance)), pushType: nil)
        } catch { status = "实时活动启动失败：\(error.localizedDescription)"; return }
        meter = NetworkMeter(); _ = meter.sample()
        samples.removeAll(); down = 0; up = 0; sampleCount = 0; submitCount = 0
        lastSample = nil; lastSubmit = nil; lastTick = .now; lastGap = 0; baseline = nil
        backgroundReport = "尚未进行后台测试"
        sessionID = UUID()
        activityStarted = .now; activityAge = 0; renewCount = 0
        renewStatus = "尚未重建"; effectiveInterval = refreshInterval; activityState = "active"
        attemptCount = 0; lastLatency = 0; unchangedChecks = 0; lastPublishedValue = "—"
        lastAttempt = nil; lastKey = nil; inFlightSince = nil; lastCheck = nil; lastPublishedPolicy = nil; lastValidInstant = nil
        running = true; status = "监控中"
        // Starting the activity never requests or requires location permission.
        refreshLocation()
        sampling = Task { [weak self] in
            let clock = ContinuousClock()
            let interval: Duration = .milliseconds(250)
            var next = clock.now.advanced(by: interval)
            while !Task.isCancelled {
                do { try await clock.sleep(until: next, tolerance: .milliseconds(10)) } catch { return }
                guard let self, self.running, !Task.isCancelled else { return }
                self.tick()
                next = next.advanced(by: interval)
                if next <= clock.now { next = clock.now.advanced(by: interval) }
            }
        }
        publishing = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let self, self.running, !Task.isCancelled else { return }
                self.controlUpdates()
            }
        }
    }
    private func tick() {
        guard let activity else { return }
        if activity.activityState == .ended || activity.activityState == .dismissed { finish("实时活动已结束"); return }
        let now = ContinuousClock.now
        if let lastTick {
            let gap = lastTick.duration(to: now)
            if gap > .seconds(2) {
                let p = gap.components
                lastGap = Double(p.seconds) + Double(p.attoseconds) / 1e18
                samples.removeAll()
            }
        }
        lastTick = now
        guard let reading = meter.sample() else { samples.removeAll(); return }
        sampleCount += 1; lastSample = Date(); lastValidInstant = now
        samples.append(reading)
        if samples.count > 4 { samples.removeFirst(samples.count - 4) }
        down = samples.reduce(0) { $0 + $1.down } / Double(samples.count)
        up = samples.reduce(0) { $0 + $1.up } / Double(samples.count)
    }
    private func seconds(_ d: Duration) -> Double {
        let p = d.components
        return Double(p.seconds) + Double(p.attoseconds) / 1e18
    }
    // With change-only updates, a finite stale date would incorrectly expire
    // a perfectly stable connection. An optional heartbeat re-enables expiry.
    private func expiry(from date: Date) -> Date? {
        guard heartbeat > 0 else { return nil }
        return date.addingTimeInterval(Double(max(staleSeconds, heartbeat + max(refreshInterval, 15) + 5)))
    }
    private var policyKey: String { "\(heartbeat)|\(staleSeconds)|\(relevance)|\(refreshInterval)" }
    private func content(valid: Bool) -> ActivityContent<SpeedAttributes.ContentState> {
        let date = valid ? (lastSample ?? Date()) : Date()
        let state = SpeedAttributes.ContentState(down: valid ? down : 0, up: valid ? up : 0,
            sampledAt: date, sampleNumber: valid ? sampleCount : 0)
        return ActivityContent(state: state, staleDate: expiry(from: date), relevanceScore: Double(relevance))
    }
    private func displayKey(valid: Bool) -> String {
        guard valid else { return "待采样" }
        let d = RateText.parts(down), u = RateText.parts(up)
        return "↓ \(d.0) \(d.1) | ↑ \(u.0) \(u.1)"
    }
    private func controlUpdates() {
        guard running, let activity else { return }
        let now = ContinuousClock.now
        if let start = activityStarted {
            let age = Int(max(0, seconds(start.duration(to: now))))
            if age != activityAge { activityAge = age; activityState = String(describing: activity.activityState) }
        }
        if let since = inFlightSince {
            if since.duration(to: now) > .seconds(5), status != "等待 ActivityKit 更新返回（见采样计数）" {
                status = "等待 ActivityKit 更新返回（见采样计数）"
            }
            return
        }
        guard renewTask == nil else { return }
        let base = max(1, refreshInterval)
        let delay = adaptive ? max(base, min(15, Int(ceil(lastLatency * 2)))) : base
        effectiveInterval = delay
        let interval = Duration.seconds(delay)
        if let lastAttempt, lastAttempt.duration(to: now) < interval { return }
        if let lastCheck, lastCheck.duration(to: now) < interval { return }
        let valid = lastValidInstant.map { $0.duration(to: now) < .seconds(2) } == true && !samples.isEmpty
        // A transient missing sample must not create spurious updates. After
        // five seconds without data, publish unavailable once (if previously valid).
        if !valid {
            guard let lastValidInstant, lastValidInstant.duration(to: now) >= .seconds(5) else { return }
        }
        lastCheck = now
        let key = displayKey(valid: valid)
        let policy = policyKey
        if key == lastKey, policy == lastPublishedPolicy {
            if heartbeat == 0 || !valid || (lastAttempt.map { $0.duration(to: now) < .seconds(heartbeat) } ?? false) {
                unchangedChecks += 1
                return
            }
        }
        lastAttempt = now; lastKey = key; lastPublishedPolicy = policy; inFlightSince = now
        lastPublishedValue = key
        attemptCount += 1
        let snapshot = content(valid: valid)
        let date = snapshot.state.sampledAt
        let token = sessionID
        let useTimestamp = timestamped
        updateTask = Task { [weak self] in
            if #available(iOS 17.2, *), useTimestamp { await activity.update(snapshot, timestamp: date) }
            else { await activity.update(snapshot) }
            guard let self, !Task.isCancelled, self.running, self.sessionID == token,
                  self.activity?.id == activity.id else { return }
            self.lastLatency = self.seconds(now.duration(to: .now))
            self.inFlightSince = nil; self.updateTask = nil
            self.submitCount += 1; self.lastSubmit = Date(); self.status = "监控中"
        }
    }
    func renewNow() { renew() }
    private func renew() {
        guard running, renewTask == nil, retiring == nil, let old = activity,
              UIApplication.shared.applicationState == .active else { return }
        let valid = lastValidInstant.map { $0.duration(to: .now) < .seconds(2) } == true && !samples.isEmpty
        do {
            // Request first; preserve the previous activity on failure.
            let new = try Activity.request(attributes: SpeedAttributes(startedAt: Date()), content: content(valid: valid), pushType: nil)
            updateTask?.cancel(); updateTask = nil; inFlightSince = nil
            activity = new; activityStarted = .now; activityAge = 0
            lastAttempt = .now; lastCheck = nil; lastKey = displayKey(valid: valid); lastPublishedPolicy = policyKey
            lastPublishedValue = lastKey ?? "—"; renewCount += 1
            renewStatus = "前台重建成功"; status = "监控中"
            retiring = old
            let token = sessionID
            renewTask = Task { [weak self] in
                await old.end(nil, dismissalPolicy: .immediate)
                guard let self, self.sessionID == token else { return }
                self.retiring = nil; self.renewTask = nil
            }
        } catch {
            renewStatus = "重建失败，保留原活动：" + error.localizedDescription
        }
    }
    func copyDiagnostics() {
        let lines = ["IslandSpeed 1.1.6 · \(Date())", "定位：\(useLocation) · \(locationStatus)", "活动：\(activityState) · \(activityAge)s · 重建 \(renewCount)", renewStatus, "采样/发起/返回/同值跳过检查：\(sampleCount)/\(attemptCount)/\(submitCount)/\(unchangedChecks)", "最近发起显示值：\(lastPublishedValue)", "间隔：\(refreshInterval)s · 实际 \(effectiveInterval)s · 心跳 \(heartbeat)s（0=关） · 自适应 \(adaptive) · 时间戳 \(timestamped)", "最近返回耗时：\(lastLatency)s · 循环中断：\(lastGap)s", backgroundReport]
        UIPasteboard.general.string = lines.joined(separator: "\n")
    }
    func stop() { finish("已停止") }
    private func finish(_ reason: String) {
        guard running else { return }
        running = false; status = reason; activityState = "已停止"
        sampling?.cancel(); sampling = nil; publishing?.cancel(); publishing = nil
        updateTask?.cancel(); updateTask = nil; inFlightSince = nil
        renewTask?.cancel(); renewTask = nil
        foregroundRenewTask?.cancel(); foregroundRenewTask = nil
        let old = activity; activity = nil
        let previous = retiring; retiring = nil
        sessionID = UUID()
        location.stop()
        Task {
            if let old { await old.end(nil, dismissalPolicy: .immediate) }
            if let previous { await previous.end(nil, dismissalPolicy: .immediate) }
        }
    }
    func sceneChanged(_ phase: ScenePhase) {
        if phase == .background {
            foregroundRenewTask?.cancel(); foregroundRenewTask = nil
            if running, baseline == nil { baseline = (sampleCount, submitCount, Date()) }
        }
        if phase == .active {
            refreshLocation()
            // UIKit's active state may lag the SwiftUI scene callback briefly.
            // Retry the optional assistance after the scene becomes active.
            if running && useLocation && location.canUseLocation && !location.active {
                Task { @MainActor [weak self] in
                    await Task.yield()
                    self?.refreshLocation()
                }
            }
            if let baseline {
                backgroundReport = "离开 \(Int(max(0, Date().timeIntervalSince(baseline.date)))) 秒：新增 \(sampleCount - baseline.samples) 个样本，\(submitCount - baseline.submits) 次更新调用返回"
                self.baseline = nil
                if running, foregroundRenew, let start = activityStarted,
                   start.duration(to: .now) >= renewalAge {
                    let token = sessionID
                    foregroundRenewTask?.cancel()
                    foregroundRenewTask = Task { [weak self] in
                        // ScenePhase may arrive slightly before UIApplication becomes active.
                        for _ in 0..<10 {
                            guard let self, !Task.isCancelled, self.running, self.sessionID == token else { return }
                            if UIApplication.shared.applicationState == .active {
                                if self.foregroundRenew, let start = self.activityStarted,
                                   start.duration(to: .now) >= self.renewalAge { self.renew() }
                                return
                            }
                            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                        }
                    }
                }
            }
        }
    }
}
