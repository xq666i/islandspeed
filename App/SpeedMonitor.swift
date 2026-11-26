import ActivityKit
import CoreFoundation
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
    private let relevance = 100
    @Published var expandRelay = false
    static let shared = SpeedMonitor()
    @Published private(set) var expandSignals = 0
    @Published private(set) var renewFailures = 0
    @Published private(set) var reservationPeak = 0
    @Published private(set) var reservationProbe = "尚未探测"
    @Published private(set) var reservationFailure = "尚无失败记录"
    @Published private(set) var expansionAttempts = 0
    @Published private(set) var expansionSuccesses = 0
    @Published private(set) var expansionFailures = 0
    @Published private(set) var expansionSkipped = 0
    @Published private(set) var expansionResult = "尚未收到展开信号"
    @Published private(set) var expansionLastAttempt = "尚未尝试"
    @Published private(set) var buttonAttempts = 0
    @Published private(set) var buttonSuccesses = 0
    @Published private(set) var buttonFailures = 0
    @Published private(set) var buttonFallbackSignals = 0
    var intentRoutingMode: String {
        #if ISLANDSPEED_MAIN_TARGET_ROUTING
        if #available(iOS 27.0, *) { return "iOS 27 显式主程序路由（.main）" }
        #endif
        return "兼容路由（未启用 iOS 27 .main）"
    }
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
    private var lastManualRenew: ContinuousClock.Instant?
    private var expandAttemptID: String?
    private var extraRetiring: [Activity<SpeedAttributes>] = []
    private var cleanupTask: Task<Void, Never>?
    private let reservationProbeLimit = 4
    @Published private(set) var effectiveInterval = 1
    @Published private(set) var activityState = "未开启"
    @Published private(set) var renewCount = 0
    @Published private(set) var renewStatus = "尚未重建"
    @Published private(set) var activityAge = 0
    @Published private(set) var lastLatency = 0.0
    @Published private(set) var attemptCount = 0
    @Published private(set) var unchangedChecks = 0
    @Published private(set) var lastPublishedValue = "—"
    @Published var relayEnabled = true
    @Published var relayInterval = 180
    @Published private(set) var relayStatus = "未预约"
    @Published private(set) var pendingCount = 0
    @Published private(set) var relayCount = 0
    @Published private(set) var observedCount = 0
    @Published private(set) var observedAt: Date?
    @Published private(set) var activityAttempts = 0
    @Published private(set) var suppressedCount = 0
    private var scheduled: [(activity: Activity<SpeedAttributes>, date: Date)] = []
    private var contentObserver: Task<Void, Never>?
    private var stateObserver: Task<Void, Never>?
    private var lastShown: (down: Double, up: Double)?
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
    var currentActivityID: String { activity?.id ?? "无" }
    private var sampling: Task<Void, Never>?
    private var publishing: Task<Void, Never>?
    private var starting = false
    private var lastTick: ContinuousClock.Instant?
    private var samples: [(down: Double, up: Double)] = []
    private var baseline: (samples: Int, submits: Int, date: Date)?

    private init() {
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, _, _, _ in
            Task { @MainActor in SpeedMonitor.shared.expandedSignal() }
        }, RelaySignal.name.rawValue, nil, .deliverImmediately)
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, _, _, _ in
            Task { @MainActor in SpeedMonitor.shared.buttonFallbackReceived() }
        }, RelaySignal.fallbackName.rawValue, nil, .deliverImmediately)
        location.onChange = { [weak self] in self?.refreshLocation() }
        refreshLocation()
    }
    private func buttonFallbackReceived() {
        buttonFallbackSignals += 1
        recordRelay("按钮 Intent 扩展侧信号：主程序收到转发；普通后台尝试，不继承 Intent 授权")
        guard running, let current = activity else {
            buttonAttempts += 1; buttonFailures += 1
            buttonStage = "扩展转发：无采样会话"
            buttonResult = "扩展转发已收到，但没有运行中的活动"
            recordRelay(buttonResult)
            return
        }
        let id = current.id
        Task { [weak self] in
            guard let self else { return }
            _ = await self.renewFromIntent(activityID: id, route: "扩展转发（普通后台）") { attributes, content in
                try Activity<SpeedAttributes>.request(attributes: attributes, content: content, pushType: nil)
            }
        }
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
        guard cleanupTask == nil else { status = "正在清理旧活动，请稍后再开启"; return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { status = "请允许实时活动"; return }
        starting = true; defer { starting = false }
        for old in Activity<SpeedAttributes>.activities { await old.end(nil, dismissalPolicy: .immediate) }
        let now = Date()
        do {
            activity = try Activity.request(attributes: SpeedAttributes(startedAt: now, expandRelay: expandRelay), content: ActivityContent(state: .init(down: 0, up: 0, sampledAt: now, sampleNumber: 0), staleDate: nil, relevanceScore: Double(relevance)), pushType: nil)
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
        lastShown = nil; activityAttempts = 0; observedCount = 0; observedAt = nil
        relayCount = 0; renewFailures = 0; expandSignals = 0; lastManualRenew = nil; expandAttemptID = nil; suppressedCount = 0
        relayStatus = "未预约"; scheduled.removeAll(); pendingCount = 0
        reservationPeak = 0; reservationProbe = "尚未探测"; reservationFailure = "尚无失败记录"
        expansionAttempts = 0; expansionSuccesses = 0; expansionFailures = 0; expansionSkipped = 0
        expansionResult = expandRelay ? "尚未收到展开信号" : "长按实验未开启"
        expansionLastAttempt = "尚未尝试"
        buttonAttempts = 0; buttonSuccesses = 0; buttonFailures = 0; buttonFallbackSignals = 0; buttonStage = "尚未执行"; buttonResult = "尚未点击"
        recordRelay("开始新一轮监控：预约=\(relayEnabled)，间隔=\(relayInterval)s，长按实验=\(expandRelay)")
        running = true; status = "监控中"
        if let activity { observe(activity) }
        // Starting the activity never requests or requires location permission.
        refreshLocation()
        if relayEnabled { scheduleRelay() }
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
        checkRelay()
        guard let activity else { return }
        if retiring == nil && (activity.activityState == .ended || activity.activityState == .dismissed) { finish("实时活动已结束"); return }
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
    private var policyKey: String { "\(pendingCount)|\(renewCount + relayCount)|\(scheduled.first?.date.timeIntervalSince1970 ?? 0)" }
    private func rates(valid: Bool) -> (down: Double, up: Double) {
        guard valid else { return (0, 0) }
        return (RateStabilizer.value(down, previous: lastShown?.down),
                RateStabilizer.value(up, previous: lastShown?.up))
    }
    private func content(valid: Bool, rates: (down: Double, up: Double)) -> ActivityContent<SpeedAttributes.ContentState> {
        let date = valid ? (lastSample ?? Date()) : Date()
        let state = SpeedAttributes.ContentState(down: rates.down, up: rates.up,
            sampledAt: date, sampleNumber: valid ? sampleCount : 0,
            pendingRelays: pendingCount, totalRelays: renewCount + relayCount, nextRelay: scheduled.first?.date)
        return ActivityContent(state: state, staleDate: nil, relevanceScore: Double(relevance))
    }
    private func displayKey(valid: Bool, rates: (down: Double, up: Double)) -> String {
        guard valid else { return "待采样" }
        let d = RateText.parts(rates.down), u = RateText.parts(rates.up)
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
        // Cleanup and reservation work must not block the current activity publisher.
        let base = max(1, refreshInterval)
        let delay = base
        effectiveInterval = delay
        let interval = Duration.seconds(delay)
        if let lastAttempt, lastAttempt.duration(to: now) < interval { return }
        if let lastCheck, lastCheck.duration(to: now) < interval { return }
        let valid = lastValidInstant.map { $0.duration(to: now) < .seconds(2) } == true && !samples.isEmpty
        // A transient missing sample must not create spurious updates. After
        // five seconds without data, publish unavailable once (if previously valid).
        if !valid {
            if let lastValidInstant {
                guard lastValidInstant.duration(to: now) >= .seconds(5) else { return }
            } else {
                guard policyKey != lastPublishedPolicy else { return }
            }
        }
        lastCheck = now
        let displayRates = rates(valid: valid)
        let key = displayKey(valid: valid, rates: displayRates)
        if valid && key != displayKey(valid: true, rates: (down, up)) { suppressedCount += 1 }
        let policy = policyKey
        if key == lastKey, policy == lastPublishedPolicy {
            unchangedChecks += 1
            return
        }
        lastAttempt = now; lastKey = key; lastPublishedPolicy = policy; inFlightSince = now
        lastPublishedValue = key
        attemptCount += 1; activityAttempts += 1
        lastShown = valid ? displayRates : nil
        let snapshot = content(valid: valid, rates: displayRates)
        let date = snapshot.state.sampledAt
        let token = sessionID
        updateTask = Task { [weak self] in
            if #available(iOS 17.2, *) { await activity.update(snapshot, timestamp: date) }
            else { await activity.update(snapshot) }
            guard let self, !Task.isCancelled, self.running, self.sessionID == token,
                  self.activity?.id == activity.id else { return }
            self.lastLatency = self.seconds(now.duration(to: .now))
            self.inFlightSince = nil; self.updateTask = nil
            self.submitCount += 1; self.lastSubmit = Date(); self.status = "监控中"
        }
    }
    func renewNow() {
        Task { _ = await renew(source: "前台", intent: false) }
    }
    // The system invokes LiveActivityIntent in the app process. Count entry
    // before any guard, including cold launch or a stale button.
    func renewFromIntent(activityID: String, route: String, request: @escaping @MainActor (SpeedAttributes, ActivityContent<SpeedAttributes.ContentState>) throws -> Activity<SpeedAttributes>) async -> Bool {
        let token = sessionID
        buttonAttempts += 1
        buttonStage = route
        buttonResult = "已收到按钮请求：\(activityID)；当前：\(activity?.id ?? "无")"
        recordRelay("按钮入口 [\(route)] pid=\(ProcessInfo.processInfo.processIdentifier)：\(buttonResult)")
        guard running, let current = activity else {
            buttonFailures += 1; buttonStage = "监控进程没有运行"
            buttonResult = "未重建：没有运行中的采样会话，请打开 App。"
            recordRelay(buttonResult); return false
        }
        guard activityID.isEmpty || activityID == current.id else {
            buttonFailures += 1; buttonStage = "旧活动的按钮"
            buttonResult = "忽略旧活动按钮，当前活动：\(current.id)"
            recordRelay(buttonResult); return false
        }
        let successesBefore = buttonSuccesses
        let success = await renew(source: "按钮", intent: true, request: request, authorizedIntentPath: route == "系统 Intent 主程序")
        if sessionID == token {
            if !success && buttonSuccesses == successesBefore {
                buttonFailures += 1
                if buttonResult.hasPrefix("已收到") { buttonStage = "接力未完成"; buttonResult = renewStatus }
            } else if success {
                buttonStage = relayEnabled && pendingCount < reservationProbeLimit ? "接力成功，预约未补满" : "新活动已绑定；预约重置结束"
                buttonResult = "新活动创建成功；累计接力 \(renewCount + relayCount)；预约 \(pendingCount)/4 个；下次 \(scheduled.first?.date.formatted(.dateTime.hour().minute().second()) ?? "无")；\(relayStatus)"
            }
            recordRelay("按钮结果：\(buttonResult)")
        }
        return success
    }
    private func expandedSignal() {
        guard running, expandRelay else { return }
        expandSignals += 1
        let reason: String?
        if activity == nil || activityStarted == nil { reason = "没有当前活动" }
        else if let start = activityStarted, start.duration(to: .now) < renewalAge { reason = "活动未满60秒" }
        else if expandAttemptID == activity?.id { reason = "本活动已经尝试过" }
        else if renewTask != nil || retiring != nil { reason = "其他接力正在执行" }
        else { reason = nil }
        if let reason {
            expansionSkipped += 1
            expansionResult = "收到展开信号，跳过：\(reason)"
            // Avoid unbounded log writes if a renderer repeatedly emits the hint.
            if expansionSkipped <= 5 || expansionSkipped % 20 == 0 { recordRelay(expansionResult) }
            return
        }
        guard let current = activity else { return }
        expandAttemptID = current.id
        expansionAttempts += 1
        expansionResult = "收到展开信号，尝试创建新活动"
        expansionLastAttempt = "尝试中"
        recordRelay("展开实验 #\(expansionAttempts)：活动 \(current.id) · \(activityAge)s")
        let token = sessionID
        Task { [weak self] in
            guard let self else { return }
            let success = await self.renew(source: "展开信号实验", intent: false, expansion: true)
            guard self.sessionID == token else { return }
            if success { self.expansionSuccesses += 1 }
            else { self.expansionFailures += 1 }
            self.expansionLastAttempt = success ? "创建新活动成功（画面刷新需实测）" : "未完成；详见接力事件"
            self.expansionResult = self.expansionLastAttempt
            self.recordRelay("展开实验结果：\(self.expansionLastAttempt)")
        }
    }
    private func isLimit(_ error: Error) -> Bool {
        guard let authorization = error as? ActivityAuthorizationError else { return false }
        switch authorization {
        case .targetMaximumExceeded, .globalMaximumExceeded: return true
        default: return false
        }
    }
    private func renew(source: String, intent: Bool, expansion: Bool = false, request: (@MainActor (SpeedAttributes, ActivityContent<SpeedAttributes.ContentState>) throws -> Activity<SpeedAttributes>)? = nil, authorizedIntentPath: Bool = true) async -> Bool {
        guard running, renewTask == nil, retiring == nil, let old = activity,
              intent || expansion || UIApplication.shared.applicationState == .active else {
            if intent { renewStatus = "按钮接力跳过：监控不可用、已有接力执行或不具备执行条件" }
            recordRelay("\(source)接力跳过：监控不可用、已有接力执行或不具备执行条件")
            return false
        }
        if let lastManualRenew, lastManualRenew.duration(to: .now) < .seconds(3) {
            if intent { renewStatus = "按钮接力跳过：3秒防重复限制" }
            recordRelay("\(source)接力跳过：3秒防重复限制")
            return false
        }
        lastManualRenew = .now
        let token = sessionID
        retiring = old // also guards against concurrent automatic/manual promotion
        defer { if sessionID == token { retiring = nil } }
        // Only a system-authorized Intent or the foreground should consume
        // appointments before a new Activity has actually been created.
        let canPreclear = (!intent && !expansion && UIApplication.shared.applicationState == .active)
            || (intent && authorizedIntentPath)
        let originalDates = scheduled.map { $0.date }
        var queueCleared = false
        var valid = false
        var displayRates: (down: Double, up: Double) = (0, 0)
        func requestNew() throws -> Activity<SpeedAttributes> {
            valid = lastValidInstant.map { $0.duration(to: .now) < .seconds(2) } == true && !samples.isEmpty
            displayRates = rates(valid: valid)
            let attributes = SpeedAttributes(startedAt: Date(), expandRelay: expandRelay)
            // The new ID starts a fresh cycle. Never put old appointment dates
            // or the old cumulative relay count into its initial content.
            let state = SpeedAttributes.ContentState(down: displayRates.down, up: displayRates.up,
                sampledAt: valid ? (lastSample ?? Date()) : Date(), sampleNumber: valid ? sampleCount : 0,
                pendingRelays: 0, totalRelays: renewCount + relayCount + 1, nextRelay: nil)
            let snapshot = ActivityContent(state: state, staleDate: nil, relevanceScore: Double(relevance))
            if intent { buttonStage = "调用 Activity.request"; recordRelay("按钮：开始创建新活动") }
            if let request { return try request(attributes, snapshot) }
            return try Activity.request(attributes: attributes, content: snapshot, pushType: nil)
        }
        do {
            if canPreclear {
                if intent { buttonStage = "取消原预约队列" }
                queueCleared = true
                guard await clearQueueForRenew(token: token, source: source) else { return false }
            }
            let new = try requestNew()
            guard running, sessionID == token else { await new.end(nil, dismissalPolicy: .immediate); return false }
            updateTask?.cancel(); updateTask = nil; inFlightSince = nil
            activity = new; activityStarted = .now; activityAge = 0; activityState = "active"
            lastAttempt = .now; lastCheck = nil; lastKey = displayKey(valid: valid, rates: displayRates)
            lastPublishedPolicy = nil; lastShown = valid ? displayRates : nil
            resetActivityDiagnostics(); observe(new)
            lastPublishedValue = lastKey ?? "—"; renewCount += 1
            renewStatus = "\(source)接力成功"; status = "监控中"
            if intent {
                buttonSuccesses += 1
                buttonStage = "新活动已绑定，等待旧活动清理"
                buttonResult = "新活动：\(new.id)；原活动：\(old.id)"
                recordRelay("按钮创建成功并绑定：\(buttonResult)")
            }
            recordRelay("\(source)接力成功：\(old.id) → \(new.id)")
            // Keep the new activity bound even if queue management fails.
            // Non-authorized experimental routes only reach here after they
            // actually succeeded in creating a new Activity.
            if !queueCleared {
                guard await clearQueueForRenew(token: token, source: source) else { return false }
            }
            await old.end(nil, dismissalPolicy: .immediate)
            guard running, sessionID == token else { return false }
            if relayEnabled {
                if intent { buttonStage = "旧活动已结束，重新预约4次" }
                let anchor = new.attributes.startedAt
                recordRelay("\(source)重新规划：以新活动启动时间 \(anchor.formatted(.dateTime.hour().minute().second())) 为基准，间隔 \(relayInterval)s")
                fillReservations(intent: intent || expansion, anchor: anchor)
            } else {
                relayStatus = "自动预约已关闭"
            }
            // Queue/count metadata is a meaningful change even if rates have
            // not moved. Publish it at the next possible opportunity rather
            // than waiting up to the configured 15-second sampling interval.
            lastAttempt = nil; lastCheck = nil
            controlUpdates()
            recordRelay("\(source)接力队列处理结束：累计接力 \(renewCount + relayCount)，预约 \(pendingCount)/4；下次 \(scheduled.first?.date.formatted(.dateTime.hour().minute().second()) ?? "无")")
            return true
        } catch {
            if sessionID == token {
                renewFailures += 1
                renewStatus = "\(source)接力失败，保留原活动：\(error.localizedDescription)"
                if intent { buttonStage = "创建失败，保留旧活动"; buttonResult = errorDetail(error) }
                recordRelay("\(source)接力失败：\(errorDetail(error))")
                if queueCleared && relayEnabled {
                    recordRelay("创建失败：尝试恢复原有预约时间并补足，保留当前活动")
                    fillReservations(intent: intent, anchor: Date(), preserving: originalDates)
                    lastAttempt = nil; lastCheck = nil
                    controlUpdates()
                }
            }
            return false
        }
    }
    private func resetActivityDiagnostics() {
        activityAttempts = 0; observedCount = 0; observedAt = nil
        lastLatency = 0
    }
    private func observe(_ target: Activity<SpeedAttributes>) {
        contentObserver?.cancel(); stateObserver?.cancel()
        let token = sessionID
        contentObserver = Task { [weak self] in
            for await _ in target.contentUpdates {
                guard let self, !Task.isCancelled, self.running, self.sessionID == token, self.activity?.id == target.id else { return }
                self.observedCount += 1; self.observedAt = Date()
            }
        }
        stateObserver = Task { [weak self] in
            for await state in target.activityStateUpdates {
                guard let self, !Task.isCancelled, self.running, self.sessionID == token, self.activity?.id == target.id else { return }
                self.activityState = String(describing: state)
            }
        }
    }
    private func isPending(_ target: Activity<SpeedAttributes>) -> Bool {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) { return target.activityState == .pending }
        #endif
        return false
    }
    private func makeReservation(at date: Date) throws -> Activity<SpeedAttributes> {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            let blank = SpeedAttributes.ContentState(down: 0, up: 0, sampledAt: date, sampleNumber: 0)
            let alert = AlertConfiguration(title: "灵动网速", body: "预约的网速活动已启动", sound: .default)
            return try Activity.request(attributes: SpeedAttributes(startedAt: date, expandRelay: expandRelay),
                content: ActivityContent(state: blank, staleDate: nil, relevanceScore: Double(relevance)),
                pushType: nil, style: .standard, alertConfiguration: alert, startDate: date)
        }
        #endif
        throw NSError(domain: "IslandSpeed", code: 26, userInfo: [NSLocalizedDescriptionKey: "当前系统或 SDK 不支持预约活动"])
    }
    private func fillReservations(intent: Bool = false, anchor: Date? = nil, preserving: [Date] = []) {
        guard running, relayEnabled, intent || UIApplication.shared.applicationState == .active else {
            recordRelay("预约探测跳过：监控/预约未启用，或不具备后台预约调用条件")
            return
        }
        scheduled.removeAll { $0.activity.activityState == .ended || $0.activity.activityState == .dismissed }
        pendingCount = scheduled.count
        let now = Date()
        let origin = anchor ?? max(now, scheduled.last?.date ?? now)
        let initial = scheduled.count
        let dates = RelaySchedule.dates(anchor: origin, interval: relayInterval,
            count: reservationProbeLimit - initial, now: now, preserving: preserving)
        reservationFailure = "本轮尚无失败记录"
        reservationProbe = "探测中（原有 \(initial) 个）"
        recordRelay("预约探测开始：原有 \(initial) 个；来源=\(intent ? "按钮 Intent" : "前台")")
        for (offset, date) in dates.enumerated() {
            let i = offset + 1
            do {
                let next = try makeReservation(at: date)
                scheduled.append((next, date)); pendingCount = scheduled.count
                reservationPeak = max(reservationPeak, pendingCount)
                recordRelay("预约第\(pendingCount)个成功（本轮第\(i)次）：\(date.formatted(.dateTime.hour().minute().second())) · 状态 \(next.activityState)")
            } catch {
                let kind = isLimit(error) ? "数量上限" : "其他错误"
                reservationFailure = "第\(pendingCount + 1)个失败（本轮第\(i)次，\(kind)）：\(errorDetail(error))"
                reservationProbe = "本轮新增 \(pendingCount - initial) 个，共 \(pendingCount) 个；\(kind)"
                recordRelay(reservationProbe + "；" + reservationFailure)
                relayStatus = isLimit(error) ? "系统预约额度已满：\(pendingCount) 个" : "已预约 \(pendingCount) 个；后续被拒：\(error.localizedDescription)"
                return
            }
        }
        reservationProbe = "本轮新增 \(pendingCount - initial) 个，共 \(pendingCount) 个；达到设定上限4（不再探测第5个）"
        recordRelay(reservationProbe)
        relayStatus = "已预约 \(pendingCount)/4 个"
    }
    func scheduleRelay() {
        guard retiring == nil, renewTask == nil else { return }
        fillReservations()
    }
    // Remove every old appointment, even if there are already four. Keep
    // references until end() returns so stop() can still clean them up.
    private func clearQueueForRenew(token: UUID, source: String) async -> Bool {
        guard running, sessionID == token else { return false }
        let targets = scheduled.map { $0.activity }
        scheduled.removeAll(); pendingCount = 0
        relayStatus = "正在取消原预约队列"
        recordRelay("\(source)：取消原预约 \(targets.count) 个")
        extraRetiring.append(contentsOf: targets)
        for target in targets {
            await target.end(nil, dismissalPolicy: .immediate)
            guard running, sessionID == token else { return false }
            recordRelay("旧预约结束返回：\(target.id) · \(target.activityState)")
        }
        let ids = Set(targets.map { $0.id })
        extraRetiring.removeAll { ids.contains($0.id) }
        return true
    }
    func cancelRelay() {
        guard retiring == nil, renewTask == nil else { return }
        let targets = scheduled.map { $0.activity }; scheduled.removeAll(); pendingCount = 0
        relayStatus = "预约已取消（等待系统结束）"
        recordRelay("手动取消 \(targets.count) 个预约")
        extraRetiring.append(contentsOf: targets)
        let token = sessionID
        renewTask = Task { [weak self] in
            for target in targets { await target.end(nil, dismissalPolicy: .immediate) }
            guard let self, self.sessionID == token else { return }
            let ids = Set(targets.map { $0.id }); self.extraRetiring.removeAll { ids.contains($0.id) }
            self.renewTask = nil
        }
    }
    private func checkRelay() {
        guard running, !scheduled.isEmpty, let old = activity, renewTask == nil, retiring == nil else { return }
        if old.activityState == .dismissed { return } // respect user dismissal
        // Only promote an actually active scheduled activity, never a pending one.
        let now = Date()
        let ready = scheduled.filter { $0.date <= now && $0.activity.activityState == .active }
        let expired = scheduled.filter { $0.activity.activityState == .ended || $0.activity.activityState == .dismissed }
        if !expired.isEmpty {
            let ids = Set(expired.map { $0.activity.id }); scheduled.removeAll { ids.contains($0.activity.id) }
            pendingCount = scheduled.count
            recordRelay("\(expired.count) 个预约已结束或被移除，未用于接力；剩余 \(pendingCount)")
        }
        guard let newest = ready.max(by: { $0.date < $1.date }) else { return }
        let used = scheduled.filter { $0.date <= newest.date }
        scheduled.removeAll { $0.date <= newest.date }; pendingCount = scheduled.count
        updateTask?.cancel(); updateTask = nil; inFlightSince = nil
        activity = newest.activity; activityStarted = .now; activityAge = 0; activityState = "active"
        lastAttempt = nil; lastCheck = nil; lastKey = nil; lastPublishedPolicy = nil
        lastShown = nil; resetActivityDiagnostics(); observe(newest.activity)
        relayCount += 1; renewStatus = "预约接力成功（实际显示仍需验证）"
        relayStatus = "接力 \(relayCount) 次；剩余预约 \(pendingCount) 个"
        recordRelay("自动预约接力 #\(relayCount) 成功：\(old.id) → \(newest.activity.id)；剩余 \(pendingCount)")
        let targets = [old] + used.map { $0.activity }.filter { $0.id != newest.activity.id }
        retiring = old
        extraRetiring.append(contentsOf: targets)
        let token = sessionID
        renewTask = Task { [weak self] in
            for target in targets { await target.end(nil, dismissalPolicy: .immediate) }
            guard let self, self.sessionID == token else { return }
            let ids = Set(targets.map { $0.id }); self.extraRetiring.removeAll { ids.contains($0.id) }
            self.retiring = nil; self.renewTask = nil
        }
    }
    func copyDiagnostics() {
        let lines = ["IslandSpeed 1.1.8 · \(Date())", "定位：\(useLocation) · \(locationStatus)", "活动：\(activityState) · \(activityAge)s · 重建 \(renewCount) · ID \(currentActivityID)", renewStatus, "采样/发起/返回/同值跳过检查：\(sampleCount)/\(attemptCount)/\(submitCount)/\(unchangedChecks)", "最近发起显示值：\(lastPublishedValue)", "防抖检查抑制：\(suppressedCount) · 当前活动发起：\(activityAttempts) · 内容观察：\(observedCount)", "预约：\(relayStatus)", "接力失败：\(renewFailures) · 展开信号：\(expandSignals)", "间隔：\(refreshInterval)s · 实际 \(effectiveInterval)s · 心跳关 · 时间戳开", "最近返回耗时：\(lastLatency)s · 循环中断：\(lastGap)s", backgroundReport]
        let extra = ["本轮成功预约峰值：\(reservationPeak) · 当前待接力：\(pendingCount) · 累计接力：\(renewCount + relayCount)",
                     "预约时间表：\(scheduled.map { $0.date.formatted(.dateTime.hour().minute().second()) }.joined(separator: "、"))",
                     "最近预约探测：\(reservationProbe)", "最近预约失败：\(reservationFailure)",
                     "长按实验：\(expandRelay) · 信号 \(expandSignals) · 尝试 \(expansionAttempts) · 成功 \(expansionSuccesses) · 失败 \(expansionFailures) · 跳过 \(expansionSkipped)",
                     "最近展开信号结果：\(expansionResult)", "最近展开接力结果：\(expansionLastAttempt)",
                     "Intent 路由：\(intentRoutingMode)",
                     "按钮接力：\(buttonAttempts) 次，成功 \(buttonSuccesses) 次，失败 \(buttonFailures) 次；扩展信号 \(buttonFallbackSignals) 次；阶段：\(buttonStage)；\(buttonResult)", "--- 接力事件（最近120条，跨启动保留） ---"]
        UIPasteboard.general.string = (lines + extra + relayEvents).joined(separator: "\n")
    }
    func stop() { finish("已停止") }
    private func finish(_ reason: String) {
        guard running else { return }
        running = false; status = reason; activityState = "已停止"
        sampling?.cancel(); sampling = nil; publishing?.cancel(); publishing = nil
        updateTask?.cancel(); updateTask = nil; inFlightSince = nil
        renewTask?.cancel(); renewTask = nil
        foregroundRenewTask?.cancel(); foregroundRenewTask = nil
        contentObserver?.cancel(); contentObserver = nil; stateObserver?.cancel(); stateObserver = nil
        relayStatus = "监控停止，取消剩余预约"
        recordRelay("停止监控：\(reason)；本轮预约峰值 \(reservationPeak)，长按尝试/成功/失败 \(expansionAttempts)/\(expansionSuccesses)/\(expansionFailures)")
        let pending = scheduled.map { $0.activity }; scheduled.removeAll(); pendingCount = 0
        let old = activity; activity = nil
        let previous = retiring; retiring = nil
        let extras = extraRetiring; extraRetiring.removeAll()
        sessionID = UUID()
        location.stop()
        cleanupTask = Task { [weak self] in
            if let old { await old.end(nil, dismissalPolicy: .immediate) }
            if let previous { await previous.end(nil, dismissalPolicy: .immediate) }
            for target in pending + extras { await target.end(nil, dismissalPolicy: .immediate) }
            self?.cleanupTask = nil
        }
    }
    func sceneChanged(_ phase: ScenePhase) {
        if phase == .background {
            foregroundRenewTask?.cancel(); foregroundRenewTask = nil
            if running, baseline == nil { baseline = (sampleCount, submitCount, Date()) }
        }
        if phase == .active {
            checkRelay()
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
                if running, let start = activityStarted,
                   start.duration(to: .now) >= renewalAge {
                    let token = sessionID
                    foregroundRenewTask?.cancel()
                    foregroundRenewTask = Task { [weak self] in
                        // ScenePhase may arrive slightly before UIApplication becomes active.
                        for _ in 0..<10 {
                            guard let self, !Task.isCancelled, self.running, self.sessionID == token else { return }
                            if UIApplication.shared.applicationState == .active {
                                if let start = self.activityStarted,
                                   start.duration(to: .now) >= self.renewalAge { self.renewNow() }
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
