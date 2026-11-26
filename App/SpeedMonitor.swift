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
    @Published var keepAlive = false
    private var meter = NetworkMeter()
    private var activity: Activity<SpeedAttributes>?
    private var loop: Task<Void, Never>?
    private var player: AVAudioPlayer?

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
        do {
            let state = SpeedAttributes.ContentState(down: 0, up: 0, sampledAt: Date())
            activity = try Activity.request(attributes: SpeedAttributes(startedAt: Date()), content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(6)), pushType: nil)
        } catch { status = "启动失败：\(error.localizedDescription)"; return }
        running = true
        status = "采样中"
        if keepAlive {
            do { try startAudio() }
            catch { status = "后台音频启动失败，前台仍可采样" }
        }
        _ = meter.sample()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { break }
                guard let self else { break }
                await self.tick()
            }
        }
    }

    func stop() async {
        loop?.cancel(); loop = nil
        stopAudio()
        let old = activity; activity = nil
        running = false; status = "已停止"
        if let old { await old.end(nil, dismissalPolicy: .immediate) }
    }

    private func tick() async {
        guard running, let activity else { return }
        if activity.activityState == .ended || activity.activityState == .dismissed {
            await stop(); status = "实时活动已结束，请重新开启"; return
        }
        guard let result = meter.sample() else { return }
        down = result.down; up = result.up
        let state = SpeedAttributes.ContentState(down: down, up: up, sampledAt: Date())
        await activity.update(ActivityContent(state: state, staleDate: Date().addingTimeInterval(6)))
    }

    private func startAudio() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try session.setActive(true)
        guard let url = Bundle.main.url(forResource: "silence", withExtension: "wav") else { throw CocoaError(.fileNoSuchFile) }
        let audio = try AVAudioPlayer(contentsOf: url)
        audio.numberOfLoops = -1
        audio.prepareToPlay()
        guard audio.play() else { throw CocoaError(.fileReadUnknown) }
        player = audio
    }

    private func stopAudio() {
        guard player != nil else { return }
        player?.stop(); player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}
