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
                    VStack(alignment: .leading, spacing: 14) {
                        Text("灵动岛刷新设置").font(.headline)
                        setting("最短提交间隔") {
                            Picker("最短提交间隔", selection: $monitor.refreshInterval) {
                                ForEach([1, 2, 3, 5, 10, 15], id: \.self) { Text("\($0) 秒").tag($0) }
                            }.labelsHidden().pickerStyle(.menu)
                        }
                        setting("相同读数心跳") {
                            Picker("相同读数心跳", selection: $monitor.heartbeat) {
                                Text("关闭").tag(0)
                                ForEach([5, 10, 15, 30, 60], id: \.self) { Text("\($0) 秒").tag($0) }
                            }.labelsHidden().pickerStyle(.menu)
                        }
                        Text("默认关闭心跳：上下行实际显示值均未变化时不提交。KB/s 保留原精度，不合并低流量。关闭心跳时不使用定时过期标记，长按网速卡可核对最后发布的样本时间。")
                            .font(.footnote).foregroundStyle(.secondary)
                        Toggle("自适应更新节流", isOn: $monitor.adaptive)
                        Toggle("使用带时间戳的更新 API", isOn: $monitor.timestamped)
                        if monitor.heartbeat > 0 {
                            setting("数据过期时间（至少）") {
                                Picker("数据过期时间", selection: $monitor.staleSeconds) {
                                    ForEach([30, 60, 120], id: \.self) { Text("\($0) 秒").tag($0) }
                                }.labelsHidden().pickerStyle(.menu)
                            }
                        }
                        setting("活动相关性") {
                            Picker("活动相关性", selection: $monitor.relevance) {
                                ForEach([0, 50, 100], id: \.self) { Text("\($0)").tag($0) }
                            }.labelsHidden().pickerStyle(.menu)
                        }
                        Toggle("返回前台自动续期（60 秒）", isOn: $monitor.foregroundRenew)
                        Text("返回 App 时，当前活动年龄达到 60 秒即重建；不停止采样。")
                            .font(.footnote).foregroundStyle(.secondary)
                        if monitor.running {
                            Button("立即重建灵动岛（不停止采样）") { monitor.renewNow() }.buttonStyle(.bordered)
                        }
                        Text(monitor.status).font(.subheadline)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("后台诊断").font(.headline)
                        Text("定位：\(monitor.locationStatus)")
                        Text("活动状态：\(monitor.activityState) · 当前间隔：\(monitor.effectiveInterval)s")
                        Text("活动已运行：\(monitor.activityAge) 秒 · 重建 \(monitor.renewCount) 次")
                        Text(monitor.renewStatus)
                        Text("更新调用发起：\(monitor.attemptCount) 次 · 最近返回耗时 \(String(format: "%.2f", monitor.lastLatency)) 秒")
                        Text("有效采样：\(monitor.sampleCount) 次")
                        Text("相同显示值跳过检查：\(monitor.unchangedChecks) 次")
                        Text("最近发起显示值：\(monitor.lastPublishedValue)")
                        Text("更新调用返回：\(monitor.submitCount) 次")
                        Text("最近采样：\(stamp(monitor.lastSample))")
                        Text("最近提交返回：\(stamp(monitor.lastSubmit))")
                        Text("最近循环中断：\(String(format: "%.1f", monitor.lastGap)) 秒")
                        Text(monitor.backgroundReport)
                        Button("复制实验诊断") { monitor.copyDiagnostics() }.buttonStyle(.bordered)
                    }.font(.footnote).monospacedDigit()
                    Text("每 0.25 秒采样，最近 4 个有效样本平均。仅在实际显示值变化时按选定最短间隔提交；可选心跳。更新调用返回不等于系统已渲染。长按网速卡可查看样本编号。")
                        .font(.footnote).foregroundStyle(.secondary)
                }.padding(20)
            }.navigationTitle("灵动网速")
                .onChange(of: scenePhase) { phase in monitor.sceneChanged(phase) }
        }
    }
    private func setting<Control: View>(_ title: String, @ViewBuilder control: () -> Control) -> some View {
        HStack { Text(title); Spacer(minLength: 8); control() }
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
