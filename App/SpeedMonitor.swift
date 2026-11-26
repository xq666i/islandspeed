import ActivityKit
import CoreLocation
import Foundation
import SwiftUI
import UIKit

@MainActor final class SpeedMonitor: ObservableObject {
    static let samplesPerSecond = 4
    static weak var current: SpeedMonitor?
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
    @Published var autoRenew = false
    @Published var foregroundRenew = false
    @Published var renewalSeconds = 120
    @Published var heartbeat = 5
    @Published var adaptive = false
    @Published var timestamped = true
    @Published var lowTrafficGate = false
    @Published var relevance = 100
    @Published var staleSeconds = 30
    @Published private(set) var effectiveInterval = 1
    @Published private(set) var activityState = "未开启"
    @Published private(set) var renewCount = 0
    @Published private(set) var renewStatus = "尚未重建"
    @Published private(set) var activityAge = 0
    @Published private(set) var lastLatency = 0.0
    @Published private(set) var attemptCount = 0
    @Published var useLocation = true { didSet { refreshLocation() } }
    @Published var pipHeight = 0.1
    @Published var pipMode: PiPMode = .videoCall
    @Published var pipAudio: PiPAudioMode = .temporary
    @Published var pipFPS = 30
    @Published var pipHide = false
    @Published private(set) var pipPrivateStatus = "未启用"
    @Published private(set) var pipSentFrames = 0
    @Published private(set) var pipStatus = "未开启"
    @Published private(set) var pipOccupied = false
    @Published private(set) var pipFrames = 0
    @Published private(set) var pipBackgroundReport = "尚未测试"
    private var pipBaseline = 0
    private let pip = PiPSession()
    private let location = LocationSession()
    private var activityStarted: ContinuousClock.Instant?
    private var lastAttempt: ContinuousClock.Instant?
    private var lastKey: String?
    private var updateTask: Task<Void, Never>?
    private var inFlightSince: ContinuousClock.Instant?
    private var renewTask: Task<Void, Never>?
    private var retiring: Activity<SpeedAttributes>?
    private var backgroundRenewDenied = false
    private var nextRenewAttempt: ContinuousClock.Instant?
    private var sessionID = UUID()
    private var renewalAge: Duration { .seconds(renewalSeconds) }
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
        pip.onChange = { [weak self] in self?.refreshPiP() }
        Self.current = self
        refreshLocation()
    }
    private func refreshPiP() {
        pipStatus = pip.status; pipOccupied = pip.occupied; pipFrames = pip.frames; pipPrivateStatus = pip.privateStatus; pipSentFrames = pip.sentFrames
    }
    func togglePiP() {
        if pip.occupied { pip.stop() }
        else { pip.start(height: pipHeight, mode: pipMode, audioMode: pipAudio, fps: pipFPS, hide: pipHide) }
    }
    func changePiPHeight() { pip.setHeight(pipHeight) }
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
            activity = try Activity.request(attributes: SpeedAttributes(startedAt: now), content: ActivityContent(state: .init(down: 0, up: 0, sampledAt: now, sampleNumber: 0), staleDate: now.addingTimeInterval(Double(staleSeconds)), relevanceScore: Double(relevance)), pushType: nil)
        } catch { status = "实时活动启动失败：\(error.localizedDescription)"; return }
        meter = NetworkMeter(); _ = meter.sample()
        samples.removeAll(); down = 0; up = 0; sampleCount = 0; submitCount = 0
        lastSample = nil; lastSubmit = nil; lastTick = .now; lastGap = 0; baseline = nil
        backgroundReport = "尚未进行后台测试"
        sessionID = UUID()
        activityStarted = .now; activityAge = 0; renewCount = 0
        renewStatus = "尚未重建"; backgroundRenewDenied = false; nextRenewAttempt = nil; effectiveInterval = refreshInterval; activityState = "active"
        attemptCount = 0; lastLatency = 0
        lastAttempt = nil; lastKey = nil; inFlightSince = nil
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
        sampleCount += 1; lastSample = Date()
        samples.append(reading)
        if samples.count > 4 { samples.removeFirst(samples.count - 4) }
        down = samples.reduce(0) { $0 + $1.down } / Double(samples.count)
        up = samples.reduce(0) { $0 + $1.up } / Double(samples.count)
    }
    private func seconds(_ d: Duration) -> Double {
        let p = d.components
        return Double(p.seconds) + Double(p.attoseconds) / 1e18
    }
    private func content() -> ActivityContent<SpeedAttributes.ContentState> {
        let date = lastSample ?? Date()
        let valid = lastSample != nil && !samples.isEmpty && Date().timeIntervalSince(date) < 2
        let state = SpeedAttributes.ContentState(down: valid ? down : 0, up: valid ? up : 0,
            sampledAt: date, sampleNumber: valid ? sampleCount : 0)
        return ActivityContent(state: state, staleDate: date.addingTimeInterval(Double(staleSeconds)), relevanceScore: Double(relevance))
    }
    private func controlUpdates() {
        guard running, let activity else { return }
        let now = ContinuousClock.now
        if let start = activityStarted {
            let age = Int(max(0, seconds(start.duration(to: now))))
            if age != activityAge { activityAge = age; refreshPiP(); activityState = String(describing: activity.activityState) }
            if autoRenew, start.duration(to: now) >= renewalAge,
               UIApplication.shared.applicationState == .background, !backgroundRenewDenied {
                renew(force: false)
            }
        }
        if let since = inFlightSince {
            if since.duration(to: now) > .seconds(5), status != "等待 ActivityKit 更新返回（见采样计数）" {
                status = "等待 ActivityKit 更新返回（见采样计数）"
            }
            return
        }
        guard renewTask == nil, let date = lastSample, !samples.isEmpty,
              Date().timeIntervalSince(date) < 2 else { return }
        let base = max(1, refreshInterval)
        let delay = adaptive ? max(base, min(15, Int(ceil(lastLatency * 2)))) : base
        effectiveInterval = delay
        let interval = Duration.seconds(delay)
        if let lastAttempt, lastAttempt.duration(to: now) < interval { return }
        let d = RateText.parts(down), u = RateText.parts(up)
        let key = lowTrafficGate && down < 1024 && up < 1024 ? "低流量" : "\(d.0) \(d.1)|\(u.0) \(u.1)"
        // Coalesce unchanged display values, with a configurable heartbeat.
        if key == lastKey, let lastAttempt, lastAttempt.duration(to: now) < .seconds(heartbeat) { return }
        lastAttempt = now; lastKey = key; inFlightSince = now
        attemptCount += 1
        let snapshot = content()
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
    func renewNow() { renew(force: true) }
    func renewFromIntent() -> Bool {
        let before = renewCount
        renew(force: true, viaIntent: true)
        return renewCount > before
    }
    private func renew(force: Bool, viaIntent: Bool = false) {
        guard running, renewTask == nil, retiring == nil, let old = activity else { return }
        let now = ContinuousClock.now
        if !force, let nextRenewAttempt, now < nextRenewAttempt { return }
        let inBackground = UIApplication.shared.applicationState != .active
        if inBackground && backgroundRenewDenied && !viaIntent { return }
        nextRenewAttempt = now.advanced(by: .seconds(60))
        do {
            // Request first: if iOS refuses background creation, the existing activity survives.
            let new = try Activity.request(attributes: SpeedAttributes(startedAt: Date()), content: content(), pushType: nil)
            updateTask?.cancel(); updateTask = nil; inFlightSince = nil
            activity = new; activityStarted = .now; activityAge = 0
            lastAttempt = .now; lastKey = nil; renewCount += 1
            renewStatus = viaIntent ? "快捷指令重建成功" : (inBackground ? "后台重建成功" : "前台重建成功")
            retiring = old
            let token = sessionID
            renewTask = Task { [weak self] in
                await old.end(nil, dismissalPolicy: .immediate)
                guard let self, self.sessionID == token else { return }
                self.retiring = nil; self.renewTask = nil
            }
        } catch {
            if inBackground { backgroundRenewDenied = true }
            renewStatus = (inBackground ? "后台重建受限，保留原活动：" : "重建失败，保留原活动：") + error.localizedDescription
        }
    }
    func copyDiagnostics() {
        let lines = ["IslandSpeed 1.1.5 · \(Date())", "定位：\(useLocation) · \(locationStatus)", "PiP：\(pipMode.rawValue) · \(pipAudio.rawValue) · \(pipHeight)pt · \(pipFPS)fps", pipStatus, pipPrivateStatus, "PiP 回调/入队：\(pipFrames)/\(pipSentFrames)", "活动：\(activityState) · \(activityAge)s · 重建 \(renewCount)", renewStatus, "采样/发起/返回：\(sampleCount)/\(attemptCount)/\(submitCount)", "间隔：\(refreshInterval)s · 实际 \(effectiveInterval)s · 心跳 \(heartbeat)s · 自适应 \(adaptive) · 低流量合并 \(lowTrafficGate) · 时间戳 \(timestamped)", "最近返回耗时：\(lastLatency)s · 循环中断：\(lastGap)s", backgroundReport, pipBackgroundReport]
        UIPasteboard.general.string = lines.joined(separator: "\n")
    }
    func stop() { finish("已停止") }
    private func finish(_ reason: String) {
        guard running else { return }
        running = false; status = reason; activityState = "已停止"
        sampling?.cancel(); sampling = nil; publishing?.cancel(); publishing = nil
        updateTask?.cancel(); updateTask = nil; inFlightSince = nil
        renewTask?.cancel(); renewTask = nil
        let old = activity; activity = nil
        let previous = retiring; retiring = nil
        sessionID = UUID()
        location.stop()
        pip.stop()
        Task {
            if let old { await old.end(nil, dismissalPolicy: .immediate) }
            if let previous { await previous.end(nil, dismissalPolicy: .immediate) }
        }
    }
    func sceneChanged(_ phase: ScenePhase) {
        if phase == .background, running, baseline == nil { baseline = (sampleCount, submitCount, Date()); pipBaseline = pip.frames }
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
                pipBackgroundReport = "离开期间新增 PiP 回调：\(max(0, pip.frames - pipBaseline)) 次；当前\(pip.active ? "运行" : (pip.suspended ? "挂起" : "未激活"))"
                self.baseline = nil
                if running, foregroundRenew, let start = activityStarted,
                   start.duration(to: .now) >= renewalAge { renew(force: true) }
            }
        }
    }
}
