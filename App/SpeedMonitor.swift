import ActivityKit
import AVFoundation
import Foundation
import SwiftUI
import UIKit

@MainActor final class SpeedMonitor: ObservableObject {
    @Published private(set) var down: Double = 0
    @Published private(set) var up: Double = 0
    @Published private(set) var running = false
    @Published private(set) var status = "尚未开启"
    // Start is an explicit user action; the UI explains the audio mode.
    @Published var keepAlive = true
    @Published var quietAudio = false
    @Published private(set) var audioStatus = "未启动"
    @Published private(set) var sampleCount = 0
    @Published private(set) var submitCount = 0
    @Published private(set) var lastSample: Date?
    @Published private(set) var lastSubmit: Date?
    @Published private(set) var backgroundReport = "尚未进行后台测试"
    @Published private(set) var lastGap: Double = 0
    private var meter = NetworkMeter()
    private var activity: Activity<SpeedAttributes>?
    private var loop: Task<Void, Never>?
    private var updateTask: Task<Void, Never>?
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var audioSessionActive = false
    private var lastTick: TimeInterval?
    private var lastPublishStart: TimeInterval?
    private var backgroundBaseline: (count: Int, uptime: TimeInterval)?
    private var lastSampleUptime: TimeInterval?
    private var audioReset = false

    func start() async {
        guard !running else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            status = "请在设置中允许实时活动"; return
        }
        for old in Activity<SpeedAttributes>.activities {
            await old.end(nil, dismissalPolicy: .immediate)
        }
        meter = NetworkMeter()
        down = 0; up = 0
        sampleCount = 0; submitCount = 0
        lastSample = nil; lastSubmit = nil; lastSampleUptime = nil
        lastGap = 0; lastTick = nil; lastPublishStart = nil
        backgroundBaseline = nil; backgroundReport = "尚未进行后台测试"
        audioReset = false
        do {
            let state = SpeedAttributes.ContentState(down: 0, up: 0, sampledAt: Date())
            activity = try Activity.request(attributes: SpeedAttributes(startedAt: Date()), content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(8)), pushType: nil)
        } catch { status = "启动失败：\(error.localizedDescription)"; return }
        running = true
        status = "采样中"
        if keepAlive { restartAudio() } else { audioStatus = "保活关闭" }
        _ = meter.sample()
        lastTick = ProcessInfo.processInfo.systemUptime
        loop = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { break }
                guard !Task.isCancelled, let self else { break }
                self.tick()
            }
        }
    }

    func stop() async {
        running = false
        loop?.cancel(); loop = nil
        updateTask?.cancel(); updateTask = nil
        stopAudio()
        audioStatus = "已停止"
        let old = activity; activity = nil
        backgroundBaseline = nil
        status = "已停止"
        if let old { await old.end(nil, dismissalPolicy: .immediate) }
    }

    // No await here: ActivityKit's asynchronous submission must not stall sampling.
    private func tick() {
        guard running, let activity else { return }
        if activity.activityState == .ended || activity.activityState == .dismissed {
            let id = activity.id
            loop?.cancel()
            Task { [weak self] in
                guard let self, self.activity?.id == id else { return }
                await self.stop()
                if !self.running { self.status = "实时活动已结束，请重新开启" }
            }
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if let lastTick, now - lastTick > 3 {
            lastGap = now - lastTick
        }
        lastTick = now
        refreshAudioStatus()
        guard let result = meter.sample() else {
            status = "正在重建采样基线"
            return
        }
        down = result.down; up = result.up
        let sampledAt = Date()
        lastSample = sampledAt; lastSampleUptime = now
        sampleCount += 1
        if updateTask != nil, let lastPublishStart, now - lastPublishStart > 5 {
            status = "采样正常，ActivityKit 提交尚未返回"
        } else {
            status = "采样中"
        }
        // Coalesce by taking the latest sample at the next tick. Never queue
        // multiple outstanding updates or submit old samples after a delay.
        guard updateTask == nil else { return }
        if let lastPublishStart, now - lastPublishStart < 1.9 { return }
        lastPublishStart = now
        let state = SpeedAttributes.ContentState(down: down, up: up, sampledAt: sampledAt)
        let content = ActivityContent(state: state, staleDate: sampledAt.addingTimeInterval(8))
        let id = activity.id
        updateTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            await activity.update(content)
            guard !Task.isCancelled, let self, self.running, self.activity?.id == id else { return }
            self.submitCount += 1
            self.lastSubmit = Date()
            self.updateTask = nil
        }
    }

    func sceneChanged(_ phase: ScenePhase) {
        guard running else { return }
        let now = ProcessInfo.processInfo.systemUptime
        switch phase {
        case .background:
            if backgroundBaseline == nil { backgroundBaseline = (sampleCount, now) }
        case .active:
            if let baseline = backgroundBaseline {
                let elapsed = max(0, now - baseline.uptime)
                let age = lastSampleUptime.map { String(format: "%.1f 秒", max(0, now - $0)) } ?? "无"
                backgroundReport = "离开约 \(Int(elapsed)) 秒，新增 \(sampleCount - baseline.count) 次采样；返回时距上次采样 \(age)"
                backgroundBaseline = nil
            }
            refreshAudioStatus()
        default: break
        }
    }

    // AVPlayer handles ordinary audio interruptions via the system's playback
    // lifecycle. We don't repeatedly force activation over calls/other apps.
    // A user can explicitly retry if the player remains paused or fails.
    func restartAudio() {
        guard running, keepAlive else { return }
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
        guard running, keepAlive else { return }
        stopAudio()
        audioReset = true
        audioStatus = "音频服务已重置，请点恢复后台音频"
    }

    private func refreshAudioStatus() {
        guard keepAlive, !audioReset, let player else { return }
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
