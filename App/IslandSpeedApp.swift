import SwiftUI
import Foundation

@main @MainActor struct IslandSpeedApp: App {
    @StateObject private var monitor = SpeedMonitor.shared
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
                        Text("仅在实际显示值变化时提交；不足 500 KB/s 保留原精度，高 KB/s 和 MB/s 自动防抖。返回前台时当前活动满 60 秒自动接力。")
                            .font(.footnote).foregroundStyle(.secondary)
                        if monitor.running {
                            Button("立即重建灵动岛（不停止采样）") { monitor.renewNow() }.buttonStyle(.bordered)
                        }
                        Text(monitor.status).font(.subheadline)
                        Divider()
                        Text("刷新时长实验").font(.headline)
                        Toggle("预定活动接力", isOn: $monitor.relayEnabled).disabled(monitor.running)
                        if monitor.relayEnabled {
                            setting("接力间隔") {
                                Picker("接力间隔", selection: $monitor.relayInterval) {
                                    ForEach([60, 90, 120, 180, 300], id: \.self) { Text("\($0) 秒").tag($0) }
                                }.labelsHidden().pickerStyle(.menu).disabled(monitor.pendingCount > 0)
                            }
                            Text("默认预约4次（实测上限），系统可能提前拒绝。到时启动可能有提示音或短暂双活动。点击立即接力会尝试重新补满。")
                                .font(.footnote).foregroundStyle(.secondary)
                            if monitor.running {
                                Button("补充预约（前台）") { monitor.scheduleRelay() }.buttonStyle(.bordered)
                                if monitor.pendingCount > 0 {
                                    Button("取消剩余预约") { monitor.cancelRelay() }.buttonStyle(.bordered)
                                }
                            }
                        }
                        Toggle("长按自动接力实验", isOn: $monitor.expandRelay).disabled(monitor.running)
                        Text("仅尝试监听展开视图出现的信号；可能不触发、提前触发或被系统拒绝。运行满 60 秒才尝试，每个活动最多一次。请在开启监控前设置。")
                            .font(.footnote).foregroundStyle(.secondary)

                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("接力实验结果").font(.headline)
                        Text("本轮成功预约峰值：\(monitor.reservationPeak) 个").font(.subheadline.weight(.semibold))
                        Text("当前待接力：\(monitor.pendingCount)/4 个 · 自动接力成功：\(monitor.relayCount) 次")
                        Text("最近探测：\(monitor.reservationProbe)")
                        Text("最近预约失败：\(monitor.reservationFailure)").textSelection(.enabled)
                        Divider()
                        Text("长按自动接力实验").font(.subheadline.weight(.semibold))
                        Text("展开信号 \(monitor.expandSignals) 次 · 跳过 \(monitor.expansionSkipped) 次")
                        Text("接力尝试 \(monitor.expansionAttempts) 次 · 成功 \(monitor.expansionSuccesses) 次 · 失败 \(monitor.expansionFailures) 次")
                        Text("最近信号：\(monitor.expansionResult)")
                        Text("最近接力：\(monitor.expansionLastAttempt)")
                        Text("0 次信号表示主程序没有收到展开信号，不代表没有长按。接力成功只表示创建新活动，实际刷新速度仍需观察。")
                            .foregroundStyle(.secondary)
                        Divider()
                        Text("按钮接力：\(monitor.buttonAttempts) 次 · 成功 \(monitor.buttonSuccesses) 次 · 失败 \(monitor.buttonFailures) 次")
                        Text("执行阶段：\(monitor.buttonStage)")
                        Text("当前活动 ID：\(monitor.currentActivityID)").textSelection(.enabled)
                        Text("扩展侧 Intent 信号：\(monitor.buttonFallbackSignals) 次（正常应为0）")
                        Text(monitor.buttonResult)
                        Button("复制实验诊断（含事件记录）") { monitor.copyDiagnostics() }.buttonStyle(.bordered)
                        DisclosureGroup("接力事件记录（最近 \(monitor.relayEvents.count) 条）") {
                            ForEach(Array(monitor.relayEvents.suffix(120).reversed().enumerated()), id: \.offset) { entry in
                                Text(entry.element).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                                Divider()
                            }
                            Button("清除事件记录", role: .destructive) { monitor.clearRelayEvents() }.buttonStyle(.bordered)
                        }
                        Text("事件记录仅保存在本机；停止监控、重新打开软件后仍可查看。")
                            .foregroundStyle(.secondary)
                    }.font(.footnote).monospacedDigit()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("后台诊断").font(.headline)
                        Text("定位：\(monitor.locationStatus)")
                        Text("活动状态：\(monitor.activityState) · 当前间隔：\(monitor.effectiveInterval)s")
                        Text("活动已运行：\(monitor.activityAge) 秒 · 重建 \(monitor.renewCount) 次")
                        Text(monitor.renewStatus)
                        Text("接力失败：\(monitor.renewFailures) 次 · 展开信号：\(monitor.expandSignals) 次")
                        Text("更新调用发起：\(monitor.attemptCount) 次 · 最近返回耗时 \(String(format: "%.2f", monitor.lastLatency)) 秒")
                        Text("有效采样：\(monitor.sampleCount) 次")
                        Text("相同显示值跳过检查：\(monitor.unchangedChecks) 次")
                        Text("最近发起显示值：\(monitor.lastPublishedValue)")
                        Text("防抖抑制检查：\(monitor.suppressedCount) 次")
                        Text("当前活动发起：\(monitor.activityAttempts) 次 · 内容观察：\(monitor.observedCount) 次")
                        Text("最近内容观察：\(stamp(monitor.observedAt))")
                        Text("预约接力：\(monitor.relayCount) 次 · 待启动 \(monitor.pendingCount) 个")
                        Text(monitor.relayStatus)
                        Text("更新调用返回：\(monitor.submitCount) 次")
                        Text("最近采样：\(stamp(monitor.lastSample))")
                        Text("最近提交返回：\(stamp(monitor.lastSubmit))")
                        Text("最近循环中断：\(String(format: "%.1f", monitor.lastGap)) 秒")
                        Text(monitor.backgroundReport)
                        Button("复制实验诊断") { monitor.copyDiagnostics() }.buttonStyle(.bordered)
                    }.font(.footnote).monospacedDigit()
                    Text("每 0.25 秒采样，最近 4 个有效样本平均。仅在实际显示值变化时按选定最短间隔提交；不发相同读数心跳。更新调用返回不等于系统已渲染。长按网速卡可查看样本编号。")
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
