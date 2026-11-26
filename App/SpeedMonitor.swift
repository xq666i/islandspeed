import ActivityKit
import AVFoundation
import Foundation
import SwiftUI
import UIKit

enum MonitoringMode: String, CaseIterable {
    case system = "系统后台测量"
    case audio = "实验性音频"
    case foreground = "仅前台"

    static var available: [Self] {
        if #available(iOS 26.0, *) { return [.system, .audio, .foreground] }
        return [.audio, .foreground]
    }
}

@MainActor final class SpeedMonitor: ObservableObject {
    static let samplesPerSecond = 4
    private static let sampleInterval: Duration = .milliseconds(1_000 / samplesPerSecond)
    private static let unchangedRefreshInterval: Duration = .seconds(1)
    private static let slowSubmissionThreshold: Duration = .seconds(1)

    @Published private(set) var down: Double = 0
    @Published private(set) var up: Double = 0
    @Published private(set) var running = false
    @Published private(set) var status = "尚未开启"
    @Published var mode = MonitoringMode.available[0]
    @Published var minutes = 30
    @Published var quietAudio = false
    @Published private(set) var audioStatus = "未启动"
    @Published private(set) var backgroundStatus = "尚未开启"
    @Published private(set) var sampleCount = 0
    @Published private(set) var submitCount = 0
    @Published private(set) var lastSample: Date?
    @Published private(set) var lastSubmit: Date?
    @Published private(set) var backgroundReport = "尚未进行后台测试"
    @Published private(set) var lastGap: Double = 0

    private var meter = NetworkMeter()
    private var activity: Activity<SpeedAttributes>?
    private var measurement: BackgroundMeasurement?
    private var starting = false
    private var loop: Task<Void, Never>?
    private struct Submission {
        let started: ContinuousClock.Instant
        let task: Task<Void, Never>
    }
    private var submissions: [Int: Submission] = [:]
    private var needsSubmission = false
    private var lastDisplay: (text: String, instant: ContinuousClock.Instant)?
    private var lastSampleInstant: ContinuousClock.Instant?
    private var lastTick: Date?
    private var peakDown: Double = 0
    private var peakUp: Double = 0
    private var backgroundBaseline: (count: Int, submits: Int, time: Date)?
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var audioSessionActive = false
    private var audioReset = false

    func start() async {
        guard !running, !starting else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            status = "请在设置中允许实时活动"
            return
        }
        starting = true
        defer { starting = false }
        for old in Activity<SpeedAttributes>.activities {
            await old.end(nil, dismissalPolicy: .immediate)
        }
        let now = Date()
        let initial = SpeedAttributes.ContentState(down: 0, up: 0, sampledAt: now, sampleNumber: 0)
        do {
            activity = try Activity.request(
                attributes: SpeedAttributes(startedAt: now),
                content: ActivityContent(state: initial, staleDate: now.addingTimeInterval(8), relevanceScore: 100),
                pushType: nil
            )
        } catch {
            status = "实时活动启动失败：\(error.localizedDescription)"
            return
        }
        meter = NetworkMeter()
        down = 0; up = 0
        peakDown = 0; peakUp = 0
        sampleCount = 0; submitCount = 0
        lastSample = nil; lastSubmit = nil
        lastTick = nil; lastGap = 0
        lastDisplay = nil; lastSampleInstant = nil
        needsSubmission = false
        backgroundBaseline = nil
        backgroundReport = "尚未进行后台测试"
        running = true

        switch mode {
        case .system:
            guard #available(iOS 26.0, *), let bundleID = Bundle.main.bundleIdentifier else {
                finish("当前系统无法启动后台测量")
                return
            }
            let session = BackgroundMeasurement(minutes: minutes, samplesPerSecond: Self.samplesPerSecond, bundleID: bundleID)
            measurement = session
            backgroundStatus = "等待系统批准，请暂留前台"
            status = "正在申请后台测量"
            do {
                try session.request(onStart: { [weak self] in
                    guard let self else { return }
                    self.backgroundStatus = "后台测量已启动"
                    self.beginSampling()
                }, onStop: { [weak self] reason in self?.finish(reason) })
            } catch {
                finish("系统未批准后台测量：\(error.localizedDescription)")
            }
        case .audio:
            backgroundStatus = "实验性音频模式"
            restartAudio()
            beginSampling()
        case .foreground:
            backgroundStatus = "仅前台采样"
            beginSampling()
        }
    }

    private func beginSampling() {
        _ = meter.sample()
        lastTick = Date()
        status = "采样中"
        loop = Task { [weak self] in
            let clock = ContinuousClock()
            let interval = Self.sampleInterval
            var next = clock.now.advanced(by: interval)
            while !Task.isCancelled {
                do { try await clock.sleep(until: next, tolerance: .milliseconds(10)) } catch { return }
                guard !Task.isCancelled, let self, self.running else { return }
                self.tick()
                next = next.advanced(by: interval)
                if next <= clock.now { next = clock.now.advanced(by: interval) }
            }
        }
    }

    func stop() { finish("已停止") }

    private func finish(_ reason: String, completed: Bool = false) {
        guard running else { return }
        running = false
        loop?.cancel()
        loop = nil
        for pending in submissions.values { pending.task.cancel() }
        submissions.removeAll()
        needsSubmission = false
        if let old = activity {
            activity = nil
            endActivity(old)
        }
        measurement?.finish(success: completed)
        measurement = nil
        stopAudio()
        audioStatus = "已停止"
        backgroundStatus = reason
        if sampleCount > 0 {
            status = "\(reason) · \(sampleCount) 个有效样本，峰值 \(ratePair(peakDown, peakUp))"
        } else {
            status = reason
        }
    }

    // Finish removing the island even if completing the measurement gives up
    // our background runtime. This short assertion covers only the end call.
    private func endActivity(_ old: Activity<SpeedAttributes>) {
        let app = UIApplication.shared
        var token = UIBackgroundTaskIdentifier.invalid
        let release: @MainActor @Sendable () -> Void = {
            guard token != .invalid else { return }
            let finished = token
            token = .invalid
            app.endBackgroundTask(finished)
        }
        if app.applicationState == .background {
            token = app.beginBackgroundTask(withName: "End IslandSpeed activity") {
                MainActor.assumeIsolated { release() }
            }
        }
        Task {
            await old.end(nil, dismissalPolicy: .immediate)
            release()
        }
    }

    private func tick() {
        guard running, let activity else { return }
        if activity.activityState == .ended || activity.activityState == .dismissed {
            finish("实时活动已结束")
            return
        }
        let date = Date()
        if let lastTick, date.timeIntervalSince(lastTick) > 3 { lastGap = date.timeIntervalSince(lastTick) }
        lastTick = date
        if mode == .audio { refreshAudioStatus() }
        if let measurement, measurement.reachedDeadline {
            finish("采样窗口已结束，取得 \(sampleCount)/\(measurement.target) 个样本")
            return
        }
        let now = ContinuousClock.now
        guard let result = meter.sample() else {
            needsSubmission = false
            status = "等待有效网卡样本"
            if displayIsDue(status, at: now) {
                measurement?.showRates(status)
            }
            return
        }
        down = result.down
        up = result.up
        peakDown = max(peakDown, down)
        peakUp = max(peakUp, up)
        lastSample = date
        lastSampleInstant = now
        sampleCount += 1
        if let measurement, sampleCount >= measurement.target {
            measurement.record(count: sampleCount)
            finish("后台测量完成", completed: true)
            return
        }
        let rates = ratePair(down, up)
        if displayIsDue(rates, at: now) {
            needsSubmission = true
            if let measurement {
                measurement.record(count: sampleCount)
                let stamp = date.formatted(.dateTime.hour().minute().second())
                measurement.showRates("\(rates) · \(stamp)")
            }
        }
        let blocked = !submissions.isEmpty && submissions.values.allSatisfy {
            $0.started.duration(to: now) >= Self.slowSubmissionThreshold
        }
        let message = blocked ? "采样中，灵动岛更新等待系统返回" : "采样中"
        if status != message { status = message }
        submitLatest(to: activity, now: now)
    }

    private func displayIsDue(_ text: String, at now: ContinuousClock.Instant) -> Bool {
        if let lastDisplay, text == lastDisplay.text,
           lastDisplay.instant.duration(to: now) < Self.unchangedRefreshInterval { return false }
        lastDisplay = (text, now)
        return true
    }

    private func ratePair(_ down: Double, _ up: Double) -> String {
        let d = RateText.parts(down), u = RateText.parts(up)
        return "↓ \(d.0) \(d.1)  ↑ \(u.0) \(u.1)"
    }

    private func submitLatest(to activity: Activity<SpeedAttributes>, now: ContinuousClock.Instant) {
        guard needsSubmission, let date = lastSample, let lastSampleInstant else { return }
        guard lastSampleInstant.duration(to: now) < Self.unchangedRefreshInterval else {
            needsSubmission = false
            return
        }
        if !submissions.isEmpty {
            // Timestamped updates can overlap without an older reading replacing a
            // newer one. When both calls are busy, retain only the latest sample.
            guard #available(iOS 17.2, *), submissions.count < 2 else { return }
        }
        needsSubmission = false
        let sequence = sampleCount
        let state = SpeedAttributes.ContentState(down: down, up: up, sampledAt: date, sampleNumber: sequence)
        let content = ActivityContent(state: state, staleDate: date.addingTimeInterval(8), relevanceScore: 100)
        let task = Task { [weak self] in
            guard !Task.isCancelled else { return }
            if #available(iOS 17.2, *) {
                await activity.update(content, timestamp: date)
            } else {
                await activity.update(content)
            }
            guard !Task.isCancelled, let self, self.activity?.id == activity.id else { return }
            self.submissions.removeValue(forKey: sequence)
            self.submitCount += 1
            self.lastSubmit = Date()
            // One pending change represents the newest reading, irrespective of how
            // many samples arrived while ActivityKit was busy.
            self.submitLatest(to: activity, now: .now)
        }
        submissions[sequence] = Submission(started: now, task: task)
    }

    func sceneChanged(_ phase: ScenePhase) {
        let now = Date()
        switch phase {
        case .background:
            if running, backgroundBaseline == nil { backgroundBaseline = (sampleCount, submitCount, now) }
        case .active:
            if let baseline = backgroundBaseline {
                let elapsed = Int(max(0, now.timeIntervalSince(baseline.time)))
                let age = lastSample.map { String(format: "%.1f 秒", max(0, now.timeIntervalSince($0))) } ?? "无样本"
                backgroundReport = "离开 \(elapsed) 秒：新增 \(sampleCount - baseline.count) 个有效样本，\(submitCount - baseline.submits) 次灵动岛提交返回；距最近样本 \(age)"
                backgroundBaseline = nil
            }
            if running, mode == .audio { refreshAudioStatus() }
        default: break
        }
    }

    // AVPlayer handles ordinary audio interruptions via the system's playback
    // lifecycle. We don't repeatedly force activation over calls/other apps.
    // A user can explicitly retry if the player remains paused or fails.
    func restartAudio() {
        guard running, mode == .audio else { return }
        stopAudio()
        audioReset = false
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            audioSessionActive = true
            let name = quietAudio ? "quiet" : "silence"
            guard let url = Bundle.main.url(forResource: name, withExtension: "wav") else {
                throw CocoaError(.fileNoSuchFile)
            }
            let queue = AVQueuePlayer()
            let repeater = AVPlayerLooper(player: queue, templateItem: AVPlayerItem(url: url))
            player = queue
            looper = repeater
            queue.volume = 1 // quiet.wav itself has a low signal level.
            queue.play()
            audioStatus = "正在启动播放"
        } catch {
            stopAudio()
            audioStatus = "启动失败：\(error.localizedDescription)"
        }
    }

    func audioServicesReset() {
        guard running, mode == .audio else { return }
        stopAudio()
        audioReset = true
        audioStatus = "音频服务已重置，请点恢复后台音频"
    }

    private func refreshAudioStatus() {
        guard mode == .audio, !audioReset, let player else { return }
        if player.status == .failed || player.currentItem?.status == .failed || looper?.status == .failed {
            audioStatus = "播放失败：\(player.error?.localizedDescription ?? player.currentItem?.error?.localizedDescription ?? looper?.error?.localizedDescription ?? "未知错误")"
            return
        }
        switch player.timeControlStatus {
        case .playing: audioStatus = quietAudio ? "低音量音频播放中" : "无声音频播放中"
        case .paused: audioStatus = "音频暂停，可手动恢复"
        case .waitingToPlayAtSpecifiedRate: audioStatus = "等待音频播放"
        @unknown default: audioStatus = "音频状态未知"
        }
    }

    private func stopAudio() {
        player?.pause()
        looper?.disableLooping()
        player?.removeAllItems()
        looper = nil; player = nil
        if audioSessionActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
            audioSessionActive = false
        }
    }
}
