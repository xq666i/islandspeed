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
    @Published private(set) var locationStatus = "未开启"
    @Published private(set) var sampleCount = 0
    @Published private(set) var submitCount = 0
    @Published private(set) var lastSample: Date?
    @Published private(set) var lastSubmit: Date?
    @Published private(set) var lastGap: Double = 0
    @Published private(set) var backgroundReport = "尚未进行后台测试"
    private let location = LocationSession()
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
    func requestPermission() { location.requestPermission(); refreshLocation() }
    func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }
    private func refreshLocation() {
        authorized = location.authorization == .authorizedAlways
        switch location.authorization {
        case .notDetermined: permission = "尚未授权，请先允许使用期间定位"
        case .authorizedWhenInUse: permission = "使用期间允许，请升级为始终允许"
        case .authorizedAlways: permission = "始终允许"
        case .denied, .restricted: permission = "定位不可用，请检查系统设置"
        @unknown default: permission = "未知权限"
        }
        if let error = location.error, location.active { locationStatus = error }
        else if let date = location.lastEvent, location.active { locationStatus = "最近定位回调：\(date.formatted(.dateTime.hour().minute().second()))" }
        else { locationStatus = location.active ? "定位服务已启动，等待回调" : "未开启" }
        if running && !authorized { finish("定位权限已撤销") }
    }
    func start() async {
        guard !running, !starting else { return }
        guard authorized else { status = "请先在系统设置中选择始终允许定位"; return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { status = "请允许实时活动"; return }
        starting = true; defer { starting = false }
        for old in Activity<SpeedAttributes>.activities { await old.end(nil, dismissalPolicy: .immediate) }
        guard authorized else { return }
        let now = Date()
        do {
            activity = try Activity.request(attributes: SpeedAttributes(startedAt: now), content: ActivityContent(state: .init(down: 0, up: 0, sampledAt: now, sampleNumber: 0), staleDate: now.addingTimeInterval(30), relevanceScore: 100), pushType: nil)
        } catch { status = "实时活动启动失败：\(error.localizedDescription)"; return }
        meter = NetworkMeter(); _ = meter.sample()
        samples.removeAll(); down = 0; up = 0; sampleCount = 0; submitCount = 0
        lastSample = nil; lastSubmit = nil; lastTick = .now; lastGap = 0; baseline = nil
        backgroundReport = "尚未进行后台测试"
        running = true; status = "监控中"
        location.start()
        guard running else { return }
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
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, self.running, !Task.isCancelled else { return }
                await self.publish()
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
    private func publish() async {
        guard let activity, let date = lastSample, !samples.isEmpty, Date().timeIntervalSince(date) < 2 else { return }
        let state = SpeedAttributes.ContentState(down: down, up: up, sampledAt: date, sampleNumber: sampleCount)
        let content = ActivityContent(state: state, staleDate: date.addingTimeInterval(30), relevanceScore: 100)
        status = "正在提交网速"
        await activity.update(content)
        guard !Task.isCancelled, running, self.activity?.id == activity.id else { return }
        submitCount += 1; lastSubmit = Date(); status = "监控中"
    }
    func stop() { finish("已停止") }
    private func finish(_ reason: String) {
        guard running else { return }
        running = false; status = reason
        sampling?.cancel(); sampling = nil; publishing?.cancel(); publishing = nil
        let old = activity; activity = nil
        location.stop()
        if let old { Task { await old.end(nil, dismissalPolicy: .immediate) } }
    }
    func sceneChanged(_ phase: ScenePhase) {
        if phase == .background, running, baseline == nil { baseline = (sampleCount, submitCount, Date()) }
        if phase == .active {
            refreshLocation()
            if let baseline {
                backgroundReport = "离开 \(Int(max(0, Date().timeIntervalSince(baseline.date)))) 秒：新增 \(sampleCount - baseline.samples) 个样本，\(submitCount - baseline.submits) 次更新调用返回"
                self.baseline = nil
            }
        }
    }
}
