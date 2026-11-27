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
    @Published var refreshInterval = 1 { didSet { savePreferences() } }
    static let shared = SpeedMonitor()
    @Published private(set) var renewFailures = 0
    @Published private(set) var reservationPeak = 0
    @Published private(set) var reservationProbe = "尚未探测"
    @Published private(set) var reservationFailure = "尚无失败记录"
    @Published private(set) var buttonAttempts = 0
    @Published private(set) var buttonSuccesses = 0
    @Published private(set) var buttonFailures = 0
    @Published private(set) var buttonSkipped = 0
    var intentRoutingMode: String {
        #if ISLANDSPEED_MAIN_TARGET_ROUTING
        if #available(iOS 27.0, *) { return "iOS 27 显式主程序路由（.main）" }
        #endif
        return "兼容路由（未启用 iOS 27 .main）"
    }
    @Published private(set) var queueResetStatus = "尚未重置"
    @Published private(set) var foregroundRecoveryStatus: String?
    @Published private(set) var buttonStage = "尚未执行"
    @Published private(set) var buttonResult = "尚未点击"
    @Published private(set) var relayEvents: [String] = UserDefaults.standard.stringArray(forKey: "IslandSpeed.relayDiagnostics.v118") ?? []
    private func recordRelay(_ message: String) {
        let stamp = Date().formatted(.dateTime.month().day().hour().minute().second())
        relayEvents.append("\(stamp) | \(message)")
        if relayEvents.count > 120 { relayEvents.removeFirst(relayEvents.count - 120) }
        UserDefaults.standard.set(relayEvents, forKey: "IslandSpeed.relayDiagnostics.v118")
    }
    func clearRelayEvents() {
        relayEvents.removeAll()
        UserDefaults.standard.removeObject(forKey: "IslandSpeed.relayDiagnostics.v118")
    }
    private func errorDetail(_ error: Error) -> String {
        let e = error as NSError
        return "\(String(describing: error)) | \(e.domain) #\(e.code) | \(e.localizedDescription)"
    }
    @Published private(set) var effectiveInterval = 1
    @Published private(set) var activityState = "未开启"
    @Published private(set) var renewCount = 0
    @Published private(set) var renewStatus = "尚未重建"
    @Published private(set) var activityAge = 0
    @Published private(set) var lastLatency = 0.0
    @Published private(set) var attemptCount = 0
    @Published private(set) var unchangedChecks = 0
    @Published private(set) var lastPublishedValue = "—"
    typealias ReservationRequest = @MainActor (SpeedAttributes, ActivityContent<SpeedAttributes.ContentState>, AlertConfiguration, Date) throws -> Activity<SpeedAttributes>
    @Published private(set) var standaloneAttempts = 0
    @Published private(set) var standaloneSuccesses = 0
    @Published private(set) var standaloneResult = "尚未尝试"
    static var supportsReservations: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }
    @Published var relayEnabled = SpeedMonitor.supportsReservations { didSet { savePreferences() } }
    @Published var relayInterval = RelaySchedule.defaultInterval { didSet { savePreferences() } }
    @Published private(set) var relayStatus = "未预约"
    @Published private(set) var appointmentDates: [Date] = []
    var pendingCount: Int { appointmentDates.count }
    var queueIsReady: Bool { pendingCount == RelaySchedule.capacity && retiringAppointments.isEmpty }
    var arrangingAppointments: Bool { starting || editing || foregroundMaintenance != nil || foregroundRecoveryRequest != nil }
    @Published private(set) var relayCount = 0
    @Published private(set) var observedCount = 0
    @Published private(set) var observedAt: Date?
    @Published private(set) var activityAttempts = 0
    @Published private(set) var suppressedCount = 0

    typealias Island = Activity<SpeedAttributes>
    typealias Snapshot = ActivityContent<SpeedAttributes.ContentState>
    private var activity: Island?
    var currentActivityID: String { activity?.id ?? "无" }
    @Published var useLocation = true {
        didSet {
            if !applyingPreferences { refreshLocation() }
            savePreferences()
        }
    }
    private let location = LocationSession()
    var canUseLocation: Bool { location.canUseLocation }
    private var sessionID = UUID()
    @Published private(set) var starting = false
    @Published private(set) var editing = false
    private static let renewalCooldownSeconds = 3
    private var lastManualRenew: ContinuousClock.Instant?
    private var knownPendingLimit = RelaySchedule.capacity
    private var releasedSlotActivityID: String?
    private var scheduled: [Island] = []
    private var ending: [String: Task<Void, Never>] = [:]
    private var meter = NetworkMeter()
    private var window = RateWindow()
    private var hasReading = false
    private var lastValid: ContinuousClock.Instant?
    private var lastTick: ContinuousClock.Instant?
    private var loop: Task<Void, Never>?
    private var observer: Task<Void, Never>?
    private var foregroundWork: Task<Void, Never>?
    private var sceneIsActive = false
    private enum ForegroundMaintenance: Equatable { case reset, refill }
    @Published private var foregroundMaintenance: ForegroundMaintenance?
    @Published private var foregroundRecoveryRequest: String?
    private var retiringAppointments: Set<String> = []
    private var recoveryActivityID: String?
    private var baseline: (samples: Int, submits: Int, date: Date)?
    private var lastCheckDue: ContinuousClock.Instant?
    private var lastAttempt: ContinuousClock.Instant?
    private var lastState: SpeedAttributes.ContentState?
    private struct Submission {
        let start: ContinuousClock.Instant
        let task: Task<Void, Never>
    }
    private var submissions: [Int: Submission] = [:]

    private struct SavedSession: Codable {
        let id: UUID
        let currentID: String?
        let renewals: Int
        let relays: Int
        let refresh: Int
        let interval: Int
        let relayEnabled: Bool
        let location: Bool
        let recoveryActivityID: String?
    }
    private static let sessionKey = "IslandSpeed.monitoringSession.v122"
    private static let preferencesKey = "IslandSpeed.monitorPreferences"
    private var applyingPreferences = false

    private struct Preferences: Codable {
        let refresh: Int
        let interval: Int
        let relayEnabled: Bool
        let location: Bool
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.preferencesKey),
           let preferences = try? JSONDecoder().decode(Preferences.self, from: data) {
            applyPreferences(preferences, restoringSession: false)
        }
        location.onChange = { [weak self] in self?.refreshLocation() }
        refreshLocation()
    }

    private func applyPreferences(_ preferences: Preferences, restoringSession: Bool) {
        applyingPreferences = true
        defer { applyingPreferences = false }
        refreshInterval = max(1, min(15, preferences.refresh))
        let minimum = restoringSession ? 60 : RelaySchedule.minimumInterval
        relayInterval = max(minimum, min(RelaySchedule.maximumInterval, preferences.interval))
        relayEnabled = preferences.relayEnabled && Self.supportsReservations
        useLocation = preferences.location
    }

    private func savePreferences() {
        guard !applyingPreferences else { return }
        let preferences = Preferences(refresh: refreshInterval, interval: relayInterval, relayEnabled: relayEnabled, location: useLocation)
        if let data = try? JSONEncoder().encode(preferences) {
            UserDefaults.standard.set(data, forKey: Self.preferencesKey)
        }
        saveSession()
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
    private func saveSession() {
        guard running else { return }
        let saved = SavedSession(id: sessionID, currentID: activity?.id, renewals: renewCount,
            relays: relayCount, refresh: refreshInterval, interval: relayInterval,
            relayEnabled: relayEnabled, location: useLocation, recoveryActivityID: recoveryActivityID)
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: Self.sessionKey)
        }
    }

    // Rebind only this user's previously started session. Cold intents and
    // foreground launches use the same path. Restoration makes no new requests.
    @discardableResult func restoreIfNeeded() -> Bool {
        guard !running, !starting,
              let data = UserDefaults.standard.data(forKey: Self.sessionKey),
              let saved = try? JSONDecoder().decode(SavedSession.self, from: data) else { return running }
        let owned = Island.activities.filter { $0.attributes.sessionID == saved.id }
        let candidates = owned.filter(isLive).sorted { $0.attributes.startedAt < $1.attributes.startedAt }
        let pending = owned.filter(isPending)
        if let previous = owned.first(where: { $0.id == saved.currentID }), previous.activityState == .dismissed {
            UserDefaults.standard.removeObject(forKey: Self.sessionKey)
            for item in owned { _ = endActivity(item) }
            return false
        }
        guard !candidates.isEmpty || !pending.isEmpty else {
            UserDefaults.standard.removeObject(forKey: Self.sessionKey)
            return false
        }
        sessionID = saved.id
        applyPreferences(.init(refresh: saved.refresh, interval: saved.interval,
                               relayEnabled: saved.relayEnabled, location: saved.location), restoringSession: true)
        renewCount = saved.renewals
        relayCount = saved.relays
        let current = candidates.last
        // Continue the last published sequence, but always rebaseline the
        // network counters after a process restart.
        sampleCount = owned.compactMap { $0.content.state.sampleNumber }.max() ?? 0
        if let current, saved.currentID != current.id { relayCount += 1 }
        // A delayed older pending activity must not later replace a newer one.
        scheduled = pending.sorted { $0.attributes.startedAt < $1.attributes.startedAt }
        if let current {
            let obsolete = scheduled.filter { $0.attributes.startedAt <= current.attributes.startedAt }
            scheduled.removeAll { $0.attributes.startedAt <= current.attributes.startedAt }
            for item in obsolete { _ = endActivity(item) }
        }
        for older in candidates.dropLast() { _ = endActivity(older) }
        running = true
        recoveryActivityID = saved.recoveryActivityID
        bind(current)
        refreshQueueStatus()
        beginSampling()
        if UIApplication.shared.applicationState != .active { baseline = (sampleCount, submitCount, Date()) }
        saveSession()
        recordRelay("恢复监控：活动 \(currentActivityID)，剩余预约 \(pendingCount) 个")
        return true
    }

    func start() async {
        guard !running, !starting, !restoreIfNeeded() else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { status = "请在设置中允许实时活动"; return }
        starting = true
        defer { starting = false }
        let old = Island.activities.filter { !isTerminal($0) }
        for target in old { _ = endActivity(target) }
        guard await waitForEnd(old, token: sessionID) else {
            status = "系统正在结束上次活动，请稍后再开启"; return
        }
        guard UIApplication.shared.applicationState == .active else { status = "请在前台开启网速"; return }
        sessionID = UUID()
        let date = Date()
        let initial = SpeedAttributes.ContentState(down: 0, up: 0, sampledAt: date, sampleNumber: 0)
        let new: Island
        do {
            new = try Island.request(attributes: .init(sessionID: sessionID, startedAt: date),
                content: Snapshot(state: initial, staleDate: nil, relevanceScore: 100), pushType: nil)
        } catch { status = "实时活动启动失败：\(error.localizedDescription)"; return }
        down = 0; up = 0; sampleCount = 0; submitCount = 0
        lastSample = nil; lastSubmit = nil; lastGap = 0; baseline = nil
        renewCount = 0; relayCount = 0; renewFailures = 0
        attemptCount = 0; unchangedChecks = 0; suppressedCount = 0
        buttonAttempts = 0; buttonSuccesses = 0; buttonFailures = 0; buttonSkipped = 0
        standaloneAttempts = 0; standaloneSuccesses = 0; reservationPeak = 0
        standaloneResult = "尚未尝试"; buttonResult = "尚未点击"; buttonStage = "尚未执行"
        reservationFailure = "尚无失败记录"; reservationProbe = "尚未探测"; renewStatus = "尚未重建"
        knownPendingLimit = RelaySchedule.capacity
        lastManualRenew = nil; backgroundReport = "尚未进行后台测试"
        running = true
        bind(new)
        beginSampling()
        saveSession()
        refreshQueueStatus()
        recordRelay("开始网速监控，预约间隔 \(relayInterval) 秒")
        if relayEnabled { await replanInForeground() }
    }

    private func beginSampling() {
        meter = NetworkMeter(); _ = meter.sample()
        window = RateWindow(); hasReading = false; lastValid = nil; lastTick = .now
        status = activity == nil ? "等待预约接力，正在采样" : "监控中"
        refreshLocation()
        let token = sessionID
        loop = Task { [weak self] in
            let clock = ContinuousClock()
            let interval = Duration.milliseconds(1_000 / Self.samplesPerSecond)
            var next = clock.now.advanced(by: interval)
            while !Task.isCancelled {
                do { try await clock.sleep(until: next, tolerance: .milliseconds(10)) } catch { return }
                guard let self, self.running, self.sessionID == token, !Task.isCancelled else { return }
                self.tick()
                self.controlUpdates(at: next)
                next = next.advanced(by: interval)
                if next <= clock.now { next = clock.now.advanced(by: interval) }
            }
        }
    }

    private func tick() {
        reconcile()
        guard running else { return }
        let now = ContinuousClock.now
        if let lastTick {
            let gap = lastTick.duration(to: now)
            if gap > .seconds(2) { lastGap = gap / .seconds(1) }
        }
        lastTick = now
        guard let interval = meter.sample() else {
            window = RateWindow(); hasReading = false
            return
        }
        let rates = window.append(interval)
        down = rates.down; up = rates.up
        sampleCount += 1; lastSample = Date(); lastValid = now; hasReading = true
    }

    var hasRecentReading: Bool {
        hasReading && lastValid.map { $0.duration(to: .now) < .seconds(2) } == true
    }
    private func readState(pending: [Island], anchor: Date?, total: Int) -> SpeedAttributes.ContentState {
        let valid = hasRecentReading
        let previous = lastState
        let aligned = relayEnabled ? anchor.map { plan(for: $0, pending: pending).matched } : nil
        return .init(down: valid ? RateStabilizer.value(down, previous: previous?.down) : 0,
            up: valid ? RateStabilizer.value(up, previous: previous?.up) : 0,
            sampledAt: lastSample ?? Date(), sampleNumber: valid ? sampleCount : 0,
            pendingRelays: pending.count, totalRelays: total, nextRelay: pending.first?.attributes.startedAt,
            alignedRelays: aligned, lostSample: !valid && lastSample != nil ? true : nil)
    }

    private func key(_ state: SpeedAttributes.ContentState) -> String {
        guard state.sampleNumber != 0 else { return state.lostSample == true ? "无样本" : "待采样" }
        return formattedPair(state.down, state.up)
    }
    private func formattedPair(_ down: Double, _ up: Double) -> String {
        let d = RateText.parts(down), u = RateText.parts(up)
        return "↓ \(d.0) \(d.1) | ↑ \(u.0) \(u.1)"
    }
    private func snapshot(_ state: SpeedAttributes.ContentState) -> Snapshot {
        // One keepalive per minute of valid, unchanged readings lets an
        // interrupted measurement expire without paying for per-second heartbeats.
        Snapshot(state: state, staleDate: state.sampleNumber == 0 ? nil : state.sampledAt.addingTimeInterval(90),
                 relevanceScore: 100)
    }

    private func controlUpdates(at scheduledTick: ContinuousClock.Instant) {
        guard running, let activity, isLive(activity) else { return }
        let age = Int(max(0, Date().timeIntervalSince(activity.attributes.startedAt)))
        if age != activityAge { activityAge = age }
        let stateName = String(describing: activity.activityState)
        if stateName != activityState { activityState = stateName }
        let interval = max(1, refreshInterval)
        if effectiveInterval != interval { effectiveInterval = interval; lastCheckDue = nil }
        if let due = lastCheckDue, scheduledTick < due { return }
        let step = Duration.seconds(interval)
        let next = (lastCheckDue ?? scheduledTick).advanced(by: step)
        lastCheckDue = next > scheduledTick ? next : scheduledTick.advanced(by: step)
        let now = ContinuousClock.now
        if !hasRecentReading, let lastValid, lastValid.duration(to: now) < .seconds(5) { return }
        let stalled = submissions.values.contains { $0.start.duration(to: now) >= .seconds(5) }
        if latestUpdateIsStalled, status != "等待 ActivityKit 更新返回（采样继续）" { status = "等待 ActivityKit 更新返回（采样继续）" }
        if !submissions.isEmpty {
            guard #available(iOS 17.2, *), stalled, submissions.count < 2 else { return }
        }
        let state = readState(pending: pendingAppointments, anchor: activity.attributes.startedAt, total: renewCount + relayCount)
        let label = key(state)
        let refreshFreshness = hasRecentReading && lastAttempt.map { $0.duration(to: now) >= .seconds(60) } == true
        let retryUnreturned = stalled && submissions[attemptCount] != nil
        if let previous = lastState, label == key(previous),
           state.pendingRelays == previous.pendingRelays, state.totalRelays == previous.totalRelays,
           state.nextRelay == previous.nextRelay, state.alignedRelays == previous.alignedRelays,
           !refreshFreshness && !retryUnreturned {
            unchangedChecks += 1
            return
        }
        if hasRecentReading && label != formattedPair(down, up) { suppressedCount += 1 }
        let token = sessionID
        let content = snapshot(state)
        // Order content revisions (including queue-only changes) separately from
        // the sample timestamp shown in the UI.
        let timestamp = Date()
        lastState = state; lastAttempt = now; lastPublishedValue = label
        attemptCount += 1; activityAttempts += 1
        let serial = attemptCount
        let task = Task { [weak self] in
            guard !Task.isCancelled else { return }
            if #available(iOS 17.2, *) { await activity.update(content, timestamp: timestamp) }
            else { await activity.update(content) }
            guard let self, !Task.isCancelled, self.running, self.sessionID == token,
                  self.activity?.id == activity.id else { return }
            self.submissions.removeValue(forKey: serial)
            self.lastLatency = now.duration(to: .now) / .seconds(1)
            self.submitCount += 1; self.lastSubmit = Date(); self.status = "监控中"
        }
        submissions[serial] = Submission(start: now, task: task)
    }

    private var latestUpdateIsStalled: Bool {
        submissions[attemptCount].map { $0.start.duration(to: .now) >= .seconds(5) } == true
    }
    private var pendingAppointments: [Island] { scheduled.filter(isPending) }
    private func isPending(_ item: Island) -> Bool {
        if #available(iOS 26.0, *) { return item.activityState == .pending }
        return false
    }
    private func isTerminal(_ item: Island) -> Bool { item.activityState == .ended || item.activityState == .dismissed }
    private func isLive(_ item: Island) -> Bool { item.activityState == .active || item.activityState == .stale }
    private func plan(for anchor: Date, pending: [Island], replacing: Bool = true) -> (matched: Int, next: Date?, release: Date?) {
        let old = replacing ? pending.filter { retiringAppointments.contains($0.id) } : []
        let new = replacing ? pending.filter { !retiringAppointments.contains($0.id) } : pending
        return RelaySchedule.plan(anchor: anchor, interval: relayInterval, now: Date(),
            existing: new.map { $0.attributes.startedAt },
            retiring: old.map { $0.attributes.startedAt }, available: knownPendingLimit)
    }
    private func refreshQueueStatus() {
        let pending = pendingAppointments
        retiringAppointments.formIntersection(pending.map(\.id))
        let dates = pending.map { $0.attributes.startedAt }
        if appointmentDates != dates { appointmentDates = dates }
        reservationPeak = max(reservationPeak, pendingCount)
        let matched = activity.map { plan(for: $0.attributes.startedAt, pending: pending).matched } ?? 0
        queueResetStatus = relayEnabled ? "重排进度 \(matched)/4" : "预约已关闭"
        relayStatus = relayEnabled ? "预约 \(pendingCount)/4 · \(queueResetStatus)" : "预约已关闭"
        if pendingCount > knownPendingLimit { knownPendingLimit = pendingCount }
        if pendingCount > 0 && pendingCount >= knownPendingLimit { releasedSlotActivityID = nil }
    }

    private func bind(_ target: Island?) {
        for update in submissions.values { update.task.cancel() }
        submissions.removeAll()
        observer?.cancel(); observer = nil
        activity = target
        if recoveryActivityID != target?.id {
            recoveryActivityID = nil
            foregroundRecoveryStatus = nil
        }
        lastState = nil; lastAttempt = nil; lastCheckDue = nil
        releasedSlotActivityID = nil
        activityAge = target.map { Int(max(0, Date().timeIntervalSince($0.attributes.startedAt))) } ?? 0
        activityState = target.map { String(describing: $0.activityState) } ?? "等待预约"
        guard let target else { return }
        lastPublishedValue = "—"; activityAttempts = 0; observedCount = 0; observedAt = nil; lastLatency = 0
        let token = sessionID
        observer = Task { [weak self] in
            for await _ in target.contentUpdates {
                guard let self, !Task.isCancelled, self.running, self.sessionID == token, self.activity?.id == target.id else { return }
                self.observedCount += 1; self.observedAt = Date()
            }
        }
    }

    // Use ActivityKit's state as the source of truth. Several reservations
    // can already be active by the time iOS allows the sampler to run again.
    private func reconcile() {
        guard running else { return }
        if activity?.activityState == .dismissed { finish("实时活动已被移除"); return }
        guard !editing else { return }
        let originalCount = scheduled.count
        scheduled.removeAll { $0.activityState == .ended || $0.activityState == .dismissed }
        if let newest = scheduled.last(where: isLive) {
            let old = activity
            let used = scheduled.filter { $0.attributes.startedAt <= newest.attributes.startedAt }
            scheduled.removeAll { $0.attributes.startedAt <= newest.attributes.startedAt }
            if let old, old.attributes.startedAt > newest.attributes.startedAt {
                for item in used { _ = endActivity(item) }
            } else {
                bind(newest)
                relayCount += 1
                renewStatus = "预约接力成功"; status = "监控中"
                saveSession()
                if let old { _ = endActivity(old) }
                for item in used where item.id != newest.id { _ = endActivity(item) }
                recordRelay("预约接力：\(old?.id ?? "等待中") → \(newest.id)")
                if relayEnabled, UIApplication.shared.applicationState != .background, foregroundMaintenance == nil {
                    foregroundMaintenance = .refill
                    startForegroundWorkIfNeeded()
                }
            }
            refreshQueueStatus()
        } else if originalCount != scheduled.count {
            refreshQueueStatus()
        }
        if activity?.activityState == .ended {
            bind(nil); saveSession()
            status = "等待预约接力，正在采样"
        }
        if activity == nil && scheduled.isEmpty { finish("实时活动和预约均已结束") }
    }

    private var endAssertion = UIBackgroundTaskIdentifier.invalid
    private func releaseEndAssertion() {
        guard endAssertion != .invalid else { return }
        let token = endAssertion; endAssertion = .invalid
        UIApplication.shared.endBackgroundTask(token)
    }
    // Share the same cleanup if stop or another handoff also owns the ID.
    // Start each end independently so a slow retirement cannot block promotion.
    @discardableResult private func endActivity(_ target: Island) -> Task<Void, Never> {
        if let task = ending[target.id] { return task }
        if UIApplication.shared.applicationState == .background, endAssertion == .invalid {
            endAssertion = UIApplication.shared.beginBackgroundTask(withName: "Finish IslandSpeed activities") { [weak self] in
                MainActor.assumeIsolated { self?.releaseEndAssertion() }
            }
        }
        let task = Task { [weak self] in
            await target.end(nil, dismissalPolicy: .immediate)
            guard let self else { return }
            self.ending.removeValue(forKey: target.id)
            if self.ending.isEmpty { self.releaseEndAssertion() }
        }
        ending[target.id] = task
        return task
    }
    // The framework can acknowledge the terminal state before end() returns.
    // Bound how long a queue operation owns editing; slow cleanup continues
    // independently, and an unconfirmed slot is never reused as if it were free.
    private func waitForEnd(_ targets: [Island], token: UUID) async -> Bool {
        for _ in 0..<20 {
            guard sessionID == token, !Task.isCancelled else { return false }
            if targets.allSatisfy(isTerminal) { return true }
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return false }
        }
        return sessionID == token && targets.allSatisfy(isTerminal)
    }
    private func isCurrent(_ token: UUID, _ id: String) -> Bool {
        running && sessionID == token && activity?.id == id && activity.map(isLive) == true
    }
    private func removePending(_ item: Island, token: UUID) async -> Bool {
        guard sessionID == token, running, isPending(item), scheduled.contains(where: { $0.id == item.id }) else { return false }
        _ = endActivity(item)
        guard await waitForEnd([item], token: token), running else { return false }
        scheduled.removeAll { $0.id == item.id }
        refreshQueueStatus()
        return true
    }
    private func isLimit(_ error: Error) -> Bool {
        guard let authError = error as? ActivityAuthorizationError else { return false }
        switch authError {
        case .targetMaximumExceeded, .globalMaximumExceeded: return true
        default: return false
        }
    }

    private typealias ImmediateRequest = @MainActor (SpeedAttributes, Snapshot) throws -> Island
    func renewNow() {
        Task { _ = await renew(source: "前台", request: nil) }
    }
    func renewFromIntent(activityID: String, request: @escaping @MainActor (SpeedAttributes, Snapshot) throws -> Island) async -> Bool {
        restoreIfNeeded()
        reconcile()
        buttonAttempts += 1
        guard let current = activity, running, current.id == activityID else {
            buttonSkipped += 1; buttonResult = "活动已变化或未监控，请从当前网速卡操作。"
            recordRelay(buttonResult); return false
        }
        let token = sessionID
        buttonStage = "主程序收到按钮"
        let success = await renew(source: "按钮", request: request)
        guard sessionID == token else { return false }
        if success { buttonSuccesses += 1 } else { buttonFailures += 1 }
        buttonStage = success ? "新活动已绑定" : "未创建新活动"
        buttonResult = "\(renewStatus) · \(relayStatus)"
        recordRelay(buttonResult)
        return success
    }

    private func renew(source: String, request: ImmediateRequest?, recoveringQueue: Bool = false,
                       resettingQueue: Bool = false) async -> Bool {
        reconcile()
        let fromIntent = request != nil
        let old = activity
        guard running, !editing, old.map(isLive) ?? resettingQueue,
              fromIntent || (!Task.isCancelled && UIApplication.shared.applicationState == .active) else {
            renewStatus = "接力处理中或当前活动不可用"; return false
        }
        if let lastManualRenew, lastManualRenew.duration(to: .now) < .seconds(Self.renewalCooldownSeconds) {
            renewStatus = "请在上次接力三秒后重试"; return false
        }
        lastManualRenew = .now
        let token = sessionID
        editing = true
        defer { if sessionID == token { editing = false; reconcile() } }
        // Never end the displayed activity on a failed creation. Once a slot
        // was freed, retries reuse it until the user has filled the queue again.
        var released = false
        func canReplaceCurrent() -> Bool {
            running && sessionID == token && activity?.id == old?.id && (old.map(isLive) ?? resettingQueue)
        }
        func freeSlot() async -> Bool {
            guard old == nil || releasedSlotActivityID != old?.id, let last = pendingAppointments.last,
                  await removePending(last, token: token) else { return false }
            released = true; releasedSlotActivityID = old?.id
            return true
        }
        func create() throws -> (Island, SpeedAttributes.ContentState) {
            let anchor = Date()
            let state = readState(pending: pendingAppointments, anchor: anchor, total: renewCount + relayCount + 1)
            let attrs = SpeedAttributes(sessionID: token, startedAt: anchor)
            let content = snapshot(state)
            if let request { return (try request(attrs, content), state) }
            return (try Island.request(attributes: attrs, content: content, pushType: nil), state)
        }
        if fromIntent, !pendingAppointments.isEmpty, pendingAppointments.count >= knownPendingLimit {
            guard await freeSlot(), canReplaceCurrent() else {
                if sessionID == token { renewStatus = "无法确认预约已释放，保留当前活动" }; return false
            }
        }
        do {
            let new: Island, initial: SpeedAttributes.ContentState
            do { (new, initial) = try create() }
            catch {
                // A background button has one authorized creation. Foreground
                // can retry a limit error after releasing a confirmed slot.
                guard !fromIntent, !released, isLimit(error), !Task.isCancelled, UIApplication.shared.applicationState == .active,
                      await freeSlot(), canReplaceCurrent(), !Task.isCancelled, UIApplication.shared.applicationState == .active else { throw error }
                (new, initial) = try create()
            }
            bind(new); renewCount += 1; lastState = initial; lastAttempt = .now
            if recoveringQueue { recoveryActivityID = new.id }
            lastPublishedValue = key(initial)
            renewStatus = "\(source)接力成功"; status = "监控中"
            saveSession(); refreshQueueStatus()
            recordRelay("\(source)接力：\(old?.id ?? "等待中") → \(new.id)")
            if let old { _ = endActivity(old) }
            if !fromIntent && relayEnabled {
                let ended = await waitForEnd(old.map { [$0] } ?? [], token: token)
                guard isCurrent(token, new.id) else { return false }
                if ended { _ = await editReservations(for: new, token: token, request: nil) }
                else if recoveringQueue { recordRelay("旧活动仍在结束，将保留新活动并稍后补排") }
            }
            return true
        } catch {
            if sessionID == token {
                renewFailures += 1; renewStatus = "\(source)接力失败，保留当前网速：\(error.localizedDescription)"
                recordRelay("\(renewStatus) · \(errorDetail(error))")
                refreshQueueStatus()
            }
            return false
        }
    }

    private func editReservations(for current: Island, token: UUID, request: ReservationRequest?) async -> Bool {
        guard #available(iOS 26.0, *) else { return false }
        let inForeground = request == nil
        let maximum = inForeground ? RelaySchedule.capacity : 1
        func canCreate() -> Bool {
            isCurrent(token, current.id) && (!inForeground || (!Task.isCancelled && UIApplication.shared.applicationState == .active))
                && !scheduled.contains(where: isLive)
        }
        var added = 0
        var retriedLimit = false
        defer { if sessionID == token { refreshQueueStatus() } }
        while added < maximum {
            guard canCreate() else { return false }
            let pending = pendingAppointments
            let planned = plan(for: current.attributes.startedAt, pending: pending, replacing: inForeground)
            if let release = planned.release, planned.next != nil || inForeground {
                let candidates = pending.filter { $0.attributes.startedAt == release }
                let old = inForeground ? candidates.last { retiringAppointments.contains($0.id) } : nil
                if let target = old ?? (planned.next == nil ? nil : candidates.last) {
                    guard await removePending(target, token: token), canCreate() else { return false }
                }
            }
            guard let date = planned.next else { break }
            guard date > Date() else { return false }
            do {
                let attributes = SpeedAttributes(sessionID: token, startedAt: date)
                let blank = SpeedAttributes.ContentState(down: 0, up: 0, sampledAt: date, sampleNumber: 0)
                let content = snapshot(blank)
                let alert = AlertConfiguration(title: "灵动网速", body: "预约的网速活动已启动", sound: .default)
                let next: Island
                if let request { next = try request(attributes, content, alert, date) }
                else { next = try ReserveOneIslandIntent.schedule(attributes, content, alert, date) }
                scheduled.append(next)
                scheduled.sort { $0.attributes.startedAt < $1.attributes.startedAt }
                added += 1
                refreshQueueStatus()
            } catch {
                reservationFailure = errorDetail(error)
                // Other apps also consume the system quota. A lower effective
                // capacity is valid. Replace an obsolete reservation only once
                // a limit has been seen; a button still makes just one request.
                if isLimit(error), !pending.isEmpty, planned.release == nil {
                    knownPendingLimit = min(knownPendingLimit, pending.count)
                    if inForeground, !retriedLimit,
                       plan(for: current.attributes.startedAt, pending: pending, replacing: inForeground).release != nil {
                        retriedLimit = true
                        continue
                    }
                }
                reservationProbe = "本次新增 \(added) 个，其他预约保留"
                recordRelay("预约失败：\(reservationFailure) · \(reservationProbe)")
                return false
            }
        }
        reservationProbe = added == 0 ? "预约已对齐" : "本次新增 \(added) 个"
        if added > 0 { recordRelay(reservationProbe) }
        return true
    }

    func reserveOneFromIntent(activityID: String, request: @escaping ReservationRequest) async -> Bool {
        restoreIfNeeded()
        reconcile()
        standaloneAttempts += 1
        guard running, relayEnabled, !editing, let current = activity, current.id == activityID else {
            standaloneResult = "当前活动已变化、接力忙或预约已关闭"; recordRelay(standaloneResult); return false
        }
        let token = sessionID
        editing = true
        defer { if sessionID == token { editing = false; reconcile() } }
        let ok = await editReservations(for: current, token: token, request: request)
        guard sessionID == token else { return false }
        if ok { standaloneSuccesses += 1; standaloneResult = reservationProbe }
        else { standaloneResult = "未完成重排，待接力 \(pendingCount) 个。最近预约错误：\(reservationFailure)" }
        return ok
    }

    private func replanInForeground(reporting: Bool = false) async {
        reconcile()
        guard let current = activity, running, relayEnabled, !editing,
              UIApplication.shared.applicationState == .active else { return }
        let token = sessionID
        editing = true
        defer { if sessionID == token { editing = false; reconcile() } }
        _ = await editReservations(for: current, token: token, request: nil)
        if isCurrent(token, current.id), reporting || recoveryActivityID == current.id {
            reportForegroundRecovery(for: current)
        }
    }
    func scheduleRelay() { Task { await replanInForeground(reporting: true) } }
    func cancelRelay() {
        reconcile()
        guard running, !editing else { return }
        foregroundMaintenance = nil
        let token = sessionID
        let targets = pendingAppointments
        editing = true
        // Start all cancellations immediately. Do not cancel an already-live successor.
        for item in targets { _ = endActivity(item) }
        Task {
            _ = await waitForEnd(targets, token: token)
            guard running, sessionID == token else { return }
            editing = false
            reconcile(); refreshQueueStatus()
            recordRelay("取消剩余预约，系统中仍待接力 \(pendingCount) 个")
        }
    }

    func stop() { finish("已停止") }
    private func finish(_ reason: String) {
        guard running else { return }
        UserDefaults.standard.removeObject(forKey: Self.sessionKey)
        running = false
        relayInterval = max(RelaySchedule.minimumInterval, relayInterval)
        sessionID = UUID(); editing = false
        loop?.cancel(); loop = nil; foregroundWork?.cancel()
        foregroundRecoveryRequest = nil; foregroundMaintenance = nil; retiringAppointments.removeAll()
        foregroundRecoveryStatus = nil
        let old = activity
        bind(nil)
        if let old { _ = endActivity(old) }
        for item in scheduled { _ = endActivity(item) }
        scheduled.removeAll(); appointmentDates = []
        location.stop(); hasReading = false; lastValid = nil
        status = reason; activityState = "已停止"; relayStatus = "预约已取消"
        recordRelay("停止监控：\(reason)")
    }

    func openRelayRecovery(_ url: URL) {
        guard let id = RelayRecoveryLink.activityID(from: url) else { return }
        foregroundRecoveryRequest = id
        startForegroundWorkIfNeeded()
    }

    func sceneChanged(_ phase: ScenePhase) {
        sceneIsActive = phase == .active
        if phase == .background {
            foregroundWork?.cancel()
            foregroundMaintenance = nil
            if running && baseline == nil { baseline = (sampleCount, submitCount, Date()) }
        }
        guard phase == .active else { return }
        let restored = !running && restoreIfNeeded()
        reconcile()
        refreshLocation()
        let returned = baseline != nil
        if let baseline {
            let elapsed = Int(max(0, Date().timeIntervalSince(baseline.date)))
            backgroundReport = "离开 \(elapsed) 秒：新增 \(sampleCount - baseline.samples) 个样本，\(submitCount - baseline.submits) 次更新调用返回"
            self.baseline = nil
        }
        if running && (returned || restored) {
            foregroundMaintenance = .reset
        }
        startForegroundWorkIfNeeded()
    }

    private func startForegroundWorkIfNeeded() {
        guard sceneIsActive, foregroundWork == nil,
              foregroundRecoveryRequest != nil || foregroundMaintenance != nil else { return }
        foregroundWork = Task { [weak self] in
            guard let self else { return }
            await self.performForegroundWork()
        }
    }

    private func performForegroundWork() async {
        defer {
            foregroundWork = nil
            startForegroundWorkIfNeeded()
        }
        await Task.yield()
        while sceneIsActive && !Task.isCancelled && (foregroundRecoveryRequest != nil || foregroundMaintenance != nil) {
            guard UIApplication.shared.applicationState == .active, !editing, !starting else {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                continue
            }
            let maintenance = foregroundMaintenance
            foregroundMaintenance = nil
            if maintenance == .reset {
                let request = foregroundRecoveryRequest
                await resetInForeground()
                if foregroundRecoveryRequest == request { foregroundRecoveryRequest = nil }
            } else if let id = foregroundRecoveryRequest {
                await recoverQueueFromLink(activityID: id)
                if foregroundRecoveryRequest == id { foregroundRecoveryRequest = nil }
            } else {
                await replanInForeground(reporting: true)
            }
        }
    }

    private func resetInForeground() async {
        refreshLocation()
        guard running else { return }
        guard relayEnabled else {
            if activity?.activityState == .stale || latestUpdateIsStalled {
                _ = await renew(source: "前台恢复", request: nil)
            }
            return
        }
        let token = sessionID
        retiringAppointments = Set(pendingAppointments.map(\.id))
        foregroundRecoveryStatus = "正在重排全部预约…"
        if let current = activity,
           Date().timeIntervalSince(current.attributes.startedAt) < Double(Self.renewalCooldownSeconds) {
            await replanInForeground(reporting: true)
            return
        }
        let renewed = await renew(source: "回前台重排", request: nil, recoveringQueue: true, resettingQueue: true)
        guard running, sessionID == token else { return }
        if renewed, let activity {
            reportForegroundRecovery(for: activity)
        } else {
            showForegroundRecovery("前台重排未完成，剩余 \(pendingAppointments.count) 个预约。\(renewStatus)")
        }
    }

    private func recoverQueueFromLink(activityID: String) async {
        restoreIfNeeded()
        reconcile()
        guard running, relayEnabled, let current = activity, isLive(current) else {
            showForegroundRecovery("当前没有可补齐预约的网速活动。")
            return
        }
        guard current.id == activityID else {
            // Another handoff may have finished while the app was opening.
            if foregroundRecoveryStatus == nil { reportForegroundRecovery(for: current) }
            return
        }
        let token = sessionID
        if recoveryActivityID != current.id && pendingAppointments.isEmpty {
            let renewed = await renew(source: "耗尽预约恢复", request: nil, recoveringQueue: true)
            guard running, sessionID == token else { return }
            guard renewed, let replacement = activity, replacement.id != current.id,
                  isCurrent(token, replacement.id) else {
                showForegroundRecovery(renewStatus)
                return
            }
            reportForegroundRecovery(for: replacement)
        } else {
            await replanInForeground(reporting: true)
        }
    }

    private func reportForegroundRecovery(for current: Island) {
        let pending = pendingAppointments
        let count = plan(for: current.attributes.startedAt, pending: pending).matched
        let oldCount = pending.filter { retiringAppointments.contains($0.id) }.count
        let capacity = RelaySchedule.capacity
        if count == capacity && oldCount == 0 {
            if recoveryActivityID == current.id {
                recoveryActivityID = nil
                saveSession()
            }
            showForegroundRecovery("已排好 \(count)/\(capacity) 个预约，可切回其他 App。")
        } else {
            let fallback = oldCount == 0 ? "" : "，仍有 \(oldCount) 个旧预约可接续"
            showForegroundRecovery("已排 \(count)/\(capacity) 个新预约\(fallback)。可在 App 内重排剩余预约。")
        }
    }

    private func showForegroundRecovery(_ result: String) {
        foregroundRecoveryStatus = result
        recordRelay("前台预约：\(result)")
    }

    func copyDiagnostics() {
        let lines = ["IslandSpeed \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—") · \(Date())", "定位：\(useLocation) · \(locationStatus)", "活动：\(activityState) · \(activityAge)s · 重建 \(renewCount) · ID \(currentActivityID)", renewStatus, "采样/发起/返回/同值跳过检查：\(sampleCount)/\(attemptCount)/\(submitCount)/\(unchangedChecks)", "最近发起显示值：\(lastPublishedValue)", "防抖检查抑制：\(suppressedCount) · 当前活动发起：\(activityAttempts) · 内容观察：\(observedCount)", "预约：\(relayStatus)", "接力失败：\(renewFailures)", "间隔：\(refreshInterval)s · 实际 \(effectiveInterval)s · 同值约60秒确认 · 时间戳开", "最近返回耗时：\(lastLatency)s · 循环中断：\(lastGap)s", backgroundReport]
        let extra = ["本轮成功预约峰值：\(reservationPeak) · 当前待接力：\(pendingCount) · 累计接力：\(renewCount + relayCount)",
                     "预约时间表：\(pendingAppointments.map { $0.attributes.startedAt.formatted(.dateTime.hour().minute().second()) }.joined(separator: "、"))",
                     "队列重置：\(queueResetStatus)", "最近预约探测：\(reservationProbe)", "最近预约失败：\(reservationFailure)",
                     "重排预约：\(standaloneAttempts) 次，成功 \(standaloneSuccesses) 次；\(standaloneResult)",
                     "Intent 路由：\(intentRoutingMode)",
                     "按钮接力：\(buttonAttempts) 次，成功 \(buttonSuccesses) 次，失败 \(buttonFailures) 次，跳过 \(buttonSkipped) 次；阶段：\(buttonStage)；\(buttonResult)", "--- 接力事件（最近120条，跨启动保留） ---"]
        UIPasteboard.general.string = (lines + extra + relayEvents).joined(separator: "\n")
    }
}
