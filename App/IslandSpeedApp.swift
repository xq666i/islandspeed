import SwiftUI
import AVFoundation
import Combine
import Foundation

@main struct IslandSpeedApp: App {
    @StateObject private var monitor = SpeedMonitor()
    var body: some Scene {
        WindowGroup { ContentView(monitor: monitor) }
    }
}

struct ContentView: View {
    @ObservedObject var monitor: SpeedMonitor
    @State private var busy = false
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(spacing: 12) {
                        rate("下载", "arrow.down", monitor.down, .green)
                        rate("上传", "arrow.up", monitor.up, .cyan)
                    }
                    Picker("运行模式", selection: $monitor.mode) {
                        ForEach(MonitoringMode.available, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }.pickerStyle(.segmented).disabled(monitor.running || busy)
                    if monitor.mode == .system {
                        Picker("测量时长", selection: $monitor.minutes) {
                            ForEach([5, 30, 60], id: \.self) { minutes in
                                Text("约 \(minutes) 分钟").tag(minutes)
                            }
                        }.disabled(monitor.running || busy)
                        Text("目标每秒采样 \(SpeedMonitor.samplesPerSecond) 次，本轮约 \(monitor.minutes) 分钟。看到“后台测量已启动”再切到其他 App。若灵动岛显示系统进度圈，可长按查看上下行网速。")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else if monitor.mode == .audio {
                        Toggle("使用低音量音频（可能听见）", isOn: $monitor.quietAudio)
                            .disabled(monitor.running || busy)
                        Text("此模式会循环播放本地音频，可能增加耗电或影响其他播放。iOS 仍可能暂停后台更新。")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Text("切到其他 App 后，系统可能挂起本次采样。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Button {
                        busy = true
                        Task {
                            if monitor.running { monitor.stop() } else { await monitor.start() }
                            busy = false
                        }
                    } label: {
                        Text(monitor.running ? "停止灵动岛网速" : "开启灵动岛网速")
                            .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8)
                    }.buttonStyle(.borderedProminent).disabled(busy)
                    Text(monitor.running && monitor.mode == .system ? monitor.backgroundStatus : monitor.status)
                        .font(.subheadline).foregroundStyle(.secondary)
                    if monitor.running && monitor.mode == .audio {
                        Button("恢复后台音频") { monitor.restartAudio() }
                            .buttonStyle(.bordered).disabled(busy)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("后台诊断 · 快速刷新").font(.headline)
                        if monitor.running { Text(monitor.status) }
                        if monitor.mode == .audio { Text("音频：\(monitor.audioStatus)") }
                        Text("有效采样：\(monitor.sampleCount) 次")
                        Text("更新调用返回：\(monitor.submitCount) 次")
                        Text("最近采样：\(stamp(monitor.lastSample))")
                        Text("最近提交返回：\(stamp(monitor.lastSubmit))")
                        Text("最近循环中断：\(String(format: "%.1f", monitor.lastGap)) 秒")
                        Text(monitor.backgroundReport)
                    }.font(.footnote).monospacedDigit()
                    Text("目标每秒采样 \(SpeedMonitor.samplesPerSecond) 次，显示值变化时立即提交。读数相同时约每秒更新一次采样时间。长按网速卡可查看样本编号。")
                        .font(.footnote).foregroundStyle(.secondary)
                }.padding(20)
            }.navigationTitle("灵动网速")
                .onChange(of: scenePhase) { phase in monitor.sceneChanged(phase) }
                .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.mediaServicesWereResetNotification)) { _ in
                    monitor.audioServicesReset()
                }
        }
    }
    private func stamp(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(.dateTime.hour().minute().second())
    }
    private func rate(_ title: String, _ icon: String, _ value: Double, _ color: Color) -> some View {
        let p = RateText.parts(value)
        return VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).foregroundStyle(color)
            Text(p.0).font(.system(size: 32, weight: .semibold, design: .rounded)).monospacedDigit().minimumScaleFactor(0.5).lineLimit(1)
            Text(p.1).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }
}
