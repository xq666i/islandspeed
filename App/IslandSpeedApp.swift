import SwiftUI
import Foundation

@main @MainActor struct IslandSpeedApp: App {
    @StateObject private var monitor = SpeedMonitor.shared
    var body: some Scene { WindowGroup { ContentView(monitor: monitor) } }
}
struct ContentView: View {
    @ObservedObject var monitor: SpeedMonitor
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
                    Text("后台运行").font(.headline)
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
                        Task {
                            if monitor.running { monitor.stop() } else { await monitor.start() }
                        }
                    } label: {
                        Text(monitor.running ? "停止灵动岛网速" : "开启灵动岛网速")
                            .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8)
                    }.buttonStyle(.borderedProminent).disabled(monitor.starting)
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        Text("灵动岛刷新设置").font(.headline)
                        setting("最短提交间隔") {
                            Picker("最短提交间隔", selection: $monitor.refreshInterval) {
                                ForEach([1, 2, 3, 5, 10, 15], id: \.self) { Text("\($0) 秒").tag($0) }
                            }.labelsHidden().pickerStyle(.menu)
                        }
                        Text("读数变化时按选定间隔提交。开启预约后，回到 App 会重新排列整组预约，请等显示「已排好」再切出。")
                            .font(.footnote).foregroundStyle(.secondary)
                        if monitor.running {
                            Button("立即重建灵动岛（不停止采样）") { monitor.renewNow() }.buttonStyle(.bordered)
                        }
                        Text(monitor.status).font(.subheadline)
                    if let result = monitor.foregroundRecoveryStatus {
                        Text(result).font(.footnote).foregroundStyle(.secondary)
                    }
                        Divider()
                        Text("自动接力").font(.headline)
                        if SpeedMonitor.supportsReservations {
                            Toggle("预定活动接力", isOn: $monitor.relayEnabled).disabled(monitor.running || monitor.starting)
                        } else {
                            Text("预约接力需要 iOS 26 或更高版本。").font(.footnote)
                        }
                        if monitor.relayEnabled {
                            setting("接力间隔") {
                                Picker("接力间隔", selection: $monitor.relayInterval) {
                                    if monitor.relayInterval < RelaySchedule.minimumInterval {
                                        Text("\(monitor.relayInterval) 秒（旧会话）").tag(monitor.relayInterval)
                                    }
                                    ForEach(RelaySchedule.intervalOptions, id: \.self) { Text("\($0) 秒").tag($0) }
                                }.labelsHidden().pickerStyle(.menu).disabled(monitor.running || monitor.starting)
                            }
                            Text("最多预留 4 个预约，实际可用数量由系统决定。到时启动可能有提示音或短暂双活动。还有预约时可立即接力，满额时会先释放最远的预约。用完后点「打开并补齐」。也可以点「重排预约」每次补一个。")
                                .font(.footnote).foregroundStyle(.secondary)
                            if monitor.running {
                                Button("重排预约（前台）") { monitor.scheduleRelay() }.buttonStyle(.bordered)
                                if monitor.pendingCount > 0 {
                                    Button("取消剩余预约") { monitor.cancelRelay() }.buttonStyle(.bordered)
                                }
                            }
                        }

                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("接力诊断").font(.headline)
                        Text("本轮成功预约峰值：\(monitor.reservationPeak) 个").font(.subheadline.weight(.semibold))
                        Text("当前待接力：\(monitor.pendingCount)/4 个 · 累计接力：\(monitor.relayCount + monitor.renewCount) 次")
                        Text("最近探测：\(monitor.reservationProbe)")
                        Text("队列重置：\(monitor.queueResetStatus)").textSelection(.enabled)
                        Text("最近预约失败：\(monitor.reservationFailure)").textSelection(.enabled)
                        Divider()
                        Text("重排预约：\(monitor.standaloneAttempts) 次 · 成功 \(monitor.standaloneSuccesses) 次")
                        Text(monitor.standaloneResult).textSelection(.enabled)
                        Divider()
                        Text("按钮接力：\(monitor.buttonAttempts) 次 · 成功 \(monitor.buttonSuccesses) 次 · 失败 \(monitor.buttonFailures) 次 · 跳过 \(monitor.buttonSkipped) 次")
                        Text("执行阶段：\(monitor.buttonStage)")
                        Text("当前活动 ID：\(monitor.currentActivityID)").textSelection(.enabled)
                        Text("Intent 路由：\(monitor.intentRoutingMode)")
                        Text(monitor.buttonResult)
                        Button("复制诊断（含事件记录）") { monitor.copyDiagnostics() }.buttonStyle(.bordered)
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
                        Text("接力失败：\(monitor.renewFailures) 次")
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
                        Button("复制诊断") { monitor.copyDiagnostics() }.buttonStyle(.bordered)
                    }.font(.footnote).monospacedDigit()
                    Text("每 0.25 秒采样，按最近一秒的流量计算网速。网速稳定时约每分钟确认一次。若最新数据超过 90 秒，网速卡会标记过期。更新调用返回后，实际显示时间由系统决定。")
                        .font(.footnote).foregroundStyle(.secondary)
                }.padding(20)
            }.navigationTitle("灵动网速")
                .onAppear { monitor.sceneChanged(scenePhase) }
                .onChange(of: scenePhase) { phase in monitor.sceneChanged(phase) }
                .onOpenURL { monitor.openRelayRecovery($0) }
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
            Text(monitor.hasRecentReading ? p.0 : "—").font(.system(size: 32, weight: .semibold, design: .rounded)).monospacedDigit().minimumScaleFactor(0.5).lineLimit(1)
            Text(p.1).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }
}
