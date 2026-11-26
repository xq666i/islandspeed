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
                    Toggle("实验性后台保活（默认开启）", isOn: $monitor.keepAlive)
                        .disabled(monitor.running || busy)
                    if monitor.keepAlive {
                        Toggle("低音量音频测试（可能听见）", isOn: $monitor.quietAudio)
                            .disabled(monitor.running || busy)
                    }
                    Text("默认循环播放无声本地音频。若退出 App 后仍冻结，可停止监控后开启低音量测试再试。音频可能增加耗电、影响其他播放，无法保证后台常驻。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button {
                        busy = true
                        Task {
                            if monitor.running { await monitor.stop() } else { await monitor.start() }
                            busy = false
                        }
                    } label: {
                        Text(monitor.running ? "停止灵动岛网速" : "开启灵动岛网速")
                            .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8)
                    }.buttonStyle(.borderedProminent).disabled(busy)
                    Text(monitor.status).font(.subheadline).foregroundStyle(.secondary)
                    if monitor.running && monitor.keepAlive {
                        Button("恢复后台音频") { monitor.restartAudio() }
                            .buttonStyle(.bordered).disabled(busy)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("后台诊断 · v1.0.1").font(.headline)
                        Text("音频：\(monitor.audioStatus)")
                        Text("有效采样：\(monitor.sampleCount) 次")
                        Text("更新调用返回：\(monitor.submitCount) 次")
                        Text("最近采样：\(stamp(monitor.lastSample))")
                        Text("最近提交返回：\(stamp(monitor.lastSubmit))")
                        Text("最近循环中断：\(String(format: "%.1f", monitor.lastGap)) 秒")
                        Text(monitor.backgroundReport)
                    }.font(.footnote).monospacedDigit()
                    Text("每秒采样，约每两秒提交最新网速；提交返回不代表灵动岛已渲染。单次实时活动最长 8 小时。")
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
