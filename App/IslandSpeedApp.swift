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
                    Text("后台定位 · 实验模式").font(.headline)
                    Text("仅在监控期间请求后台定位更新以测试持续运行。不保存或上传坐标，可关闭精确位置。系统可能显示定位指示，也可能暂停后台执行。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("权限：\(monitor.permission)").font(.subheadline)
                    if !monitor.authorized {
                        Button("申请 / 升级定位权限") { monitor.requestPermission() }.buttonStyle(.bordered)
                        Button("打开系统设置") { monitor.openSettings() }.buttonStyle(.bordered)
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
                    }.buttonStyle(.borderedProminent).disabled(busy || (!monitor.running && !monitor.authorized))
                    Picker("提交间隔", selection: $monitor.refreshInterval) {
                        Text("1 秒").tag(1); Text("2 秒").tag(2); Text("3 秒").tag(3)
                    }.pickerStyle(.segmented)
                    Toggle("60 秒活动续期实验", isOn: $monitor.autoRenew)
                    if monitor.running {
                        Button("立即重建灵动岛（不停止采样）") { monitor.renewNow() }.buttonStyle(.bordered)
                    }
                    Text(monitor.status).font(.subheadline)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("后台诊断").font(.headline)
                        Text("定位：\(monitor.locationStatus)")
                        Text("活动已运行：\(monitor.activityAge) 秒 · 重建 \(monitor.renewCount) 次")
                        Text(monitor.renewStatus)
                        Text("更新调用发起：\(monitor.attemptCount) 次 · 最近返回耗时 \(String(format: "%.2f", monitor.lastLatency)) 秒")
                        Text("有效采样：\(monitor.sampleCount) 次")
                        Text("更新调用返回：\(monitor.submitCount) 次")
                        Text("最近采样：\(stamp(monitor.lastSample))")
                        Text("最近提交返回：\(stamp(monitor.lastSubmit))")
                        Text("最近循环中断：\(String(format: "%.1f", monitor.lastGap)) 秒")
                        Text(monitor.backgroundReport)
                    }.font(.footnote).monospacedDigit()
                    Text("每 0.25 秒采样，最近 4 个有效样本平均。按选定间隔提交，显示值不变时最多每 5 秒保活更新一次。后台重建若被拒绝，本轮不再后台重试；返回 App 时可自动续期。长按网速卡可查看样本编号。")
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
