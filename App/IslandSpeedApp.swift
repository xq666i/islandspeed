import SwiftUI
import Foundation

@main struct IslandSpeedApp: App {
    @StateObject private var monitor = SpeedMonitor()
    var body: some Scene { WindowGroup { ContentView(monitor: monitor) } }
}
struct ContentView: View {
    @ObservedObject var monitor: SpeedMonitor
    @State private var busy = false
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 12) {
                        rate("下载", "arrow.down", monitor.down, .green)
                        rate("上传", "arrow.up", monitor.up, .cyan)
                    }
                    Group {
                    Text("后台保活 · 对照实验").font(.headline)
                    Toggle("定位辅助", isOn: $monitor.useLocation)
                    Text("定位权限为可选，无需授权即可开启网速。允许定位后可辅助后台运行，不保存或上传坐标，可关闭精确位置。无定位辅助时系统可能较快暂停采样。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("权限：\(monitor.permission)").font(.subheadline)
                    if !monitor.authorized {
                        Button(monitor.permissionButton) { monitor.requestPermission() }.buttonStyle(.bordered)
                        Button("打开系统设置") { monitor.openSettings() }.buttonStyle(.bordered)
                        Text(monitor.permissionHint).font(.footnote).foregroundStyle(.secondary)
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
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("PiP 画中画辅助 · 实验").font(.headline)
                        Picker("底层方案", selection: $monitor.pipMode) {
                            ForEach(PiPMode.allCases) { Text($0.rawValue).tag($0) }
                        }.disabled(monitor.pipOccupied)
                        Picker("音频会话", selection: $monitor.pipAudio) {
                            ForEach(PiPAudioMode.allCases) { Text($0.rawValue).tag($0) }
                        }.disabled(monitor.pipOccupied)
                        Picker("内容驱动 FPS", selection: $monitor.pipFPS) {
                            ForEach([5, 15, 30, 60], id: \.self) { Text("\($0) fps").tag($0) }
                        }.disabled(monitor.pipOccupied)
                        Toggle("尝试隐藏 PiP 控件（私有接口）", isOn: $monitor.pipHide).disabled(monitor.pipOccupied)
                        Picker("请求高度", selection: $monitor.pipHeight) {
                            Text("0.1 pt").tag(0.1); Text("1 pt").tag(1.0); Text("40 pt").tag(40.0)
                        }.pickerStyle(.segmented)
                            .onChange(of: monitor.pipHeight) { _ in monitor.changePiPHeight() }
                            .disabled(!monitor.pipMode.videoCall)
                        Button(monitor.pipOccupied ? "停止画中画辅助" : "开启画中画辅助") { monitor.togglePiP() }
                            .buttonStyle(.bordered)
                        Text(monitor.pipStatus).font(.footnote)
                        Text(monitor.pipPrivateStatus).font(.footnote)
                        Text("可先开启 PiP 再启动网速，测试启动顺序。VideoCall 可调高度；普通视频及 SampleBuffer 由系统控制大小。PlayerLayer 的视频固定 15fps，此处 FPS 为回调频率。更换底层前先停止 PiP。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Group {
                    Text("ActivityKit 更新实验").font(.headline)
                    Picker("提交间隔", selection: $monitor.refreshInterval) {
                        ForEach([1, 2, 3, 5, 10, 15], id: \.self) { Text("\($0) 秒").tag($0) }
                    }
                    Picker("相同读数心跳", selection: $monitor.heartbeat) {
                        ForEach([5, 10, 15, 30, 60], id: \.self) { Text("\($0) 秒").tag($0) }
                    }
                    Toggle("自适应更新节流", isOn: $monitor.adaptive)
                    Toggle("低流量合并（上下行均低于 1 KB/s）", isOn: $monitor.lowTrafficGate)
                    Toggle("使用带时间戳的更新 API", isOn: $monitor.timestamped)
                    Picker("过期时间", selection: $monitor.staleSeconds) {
                        ForEach([30, 60, 120], id: \.self) { Text("\($0) 秒").tag($0) }
                    }
                    Picker("活动相关性", selection: $monitor.relevance) {
                        ForEach([0, 50, 100], id: \.self) { Text("\($0)").tag($0) }
                    }
                    }
                    Group {
                    Toggle("定时后台续期实验", isOn: $monitor.autoRenew)
                    Toggle("返回前台自动续期", isOn: $monitor.foregroundRenew)
                    Picker("尝试续期年龄", selection: $monitor.renewalSeconds) {
                        ForEach([60, 120, 180, 300, 600], id: \.self) { Text("\($0) 秒").tag($0) }
                    }
                    Text("两个自动续期均默认关闭，避免污染测试结果。也可通过快捷指令运行「重建灵动网速」实验。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if monitor.running {
                        Button("立即重建灵动岛（不停止采样）") { monitor.renewNow() }.buttonStyle(.bordered)
                    }
                    Text(monitor.status).font(.subheadline)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("后台诊断").font(.headline)
                        Text("定位：\(monitor.locationStatus)")
                        Text("PiP 回调：\(monitor.pipFrames) 次 · SampleBuffer 入队：\(monitor.pipSentFrames)")
                        Text("活动状态：\(monitor.activityState) · 当前间隔：\(monitor.effectiveInterval)s")
                        Text(monitor.pipBackgroundReport)
                        Text("活动已运行：\(monitor.activityAge) 秒 · 重建 \(monitor.renewCount) 次")
                        Text(monitor.renewStatus)
                        Text("更新调用发起：\(monitor.attemptCount) 次 · 最近返回耗时 \(String(format: "%.2f", monitor.lastLatency)) 秒")
                        Text("有效采样：\(monitor.sampleCount) 次")
                        Text("更新调用返回：\(monitor.submitCount) 次")
                        Text("最近采样：\(stamp(monitor.lastSample))")
                        Text("最近提交返回：\(stamp(monitor.lastSubmit))")
                        Text("最近循环中断：\(String(format: "%.1f", monitor.lastGap)) 秒")
                        Text(monitor.backgroundReport)
                        Button("复制实验诊断") { monitor.copyDiagnostics() }.buttonStyle(.bordered)
                    }.font(.footnote).monospacedDigit()
                    Text("每 0.25 秒采样，最近 4 个有效样本平均。按选定间隔提交，心跳可独立配置。后台普通重建若被拒绝，本轮不再普通后台重试。更新调用返回不等于系统已渲染。长按网速卡可查看样本编号。")
                        .font(.footnote).foregroundStyle(.secondary)
                }.padding(20)
            }.navigationTitle("灵动网速")
                .onChange(of: scenePhase) { phase in monitor.sceneChanged(phase) }
        }
    }
    private func stamp(_ date: Date?) -> String { date?.formatted(.dateTime.hour().minute().second()) ?? "—" }
    private func rate(_ title: String, _ icon: String, _ value: Double, _ color: Color) -> some View {
        let p = RateText.parts(value)
        return VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).foregroundStyle(color)
            Text(p.0).font(.system(size: 32, weight: .semibold, design: .rounded)).monospacedDigit().minimumScaleFactor(0.5).lineLimit(1)
            Text(p.1).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }
}
