import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main struct SpeedWidgetBundle: WidgetBundle {
    var body: some Widget { SpeedWidget() }
}

struct SpeedWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SpeedAttributes.self) { context in
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 18) {
                    detailed("下载", "arrow.down", context.state.down, .green, unavailable(context))
                    Spacer()
                    detailed("上传", "arrow.up", context.state.up, .cyan, unavailable(context))
                }
                sampleInfo(context)
            }.padding(18).activityBackgroundTint(.black).activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    detailed("下载", "arrow.down", context.state.down, .green, unavailable(context))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    detailed("上传", "arrow.up", context.state.up, .cyan, unavailable(context))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 4) {
                        sampleInfo(context)
                        if #available(iOS 17.0, *) {
                            Button(intent: RelayIslandIntent()) {
                                Label("立即接力", systemImage: "arrow.clockwise")
                                    .font(.caption.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                            }.buttonStyle(.bordered).tint(.white)
                        }
                    }.onAppear {
                        if context.attributes.expandRelay == true { RelaySignal.post() }
                    }
                }
            } compactLeading: {
                compact("arrow.down", context.state.down, .green, unavailable(context))
            } compactTrailing: {
                compact("arrow.up", context.state.up, .cyan, unavailable(context))
            } minimal: {
                compact("arrow.down", context.state.down, .green, unavailable(context), minimal: true)
            }.keylineTint(.green)
        }
    }

    private func unavailable(_ context: ActivityViewContext<SpeedAttributes>) -> String? {
        if context.state.sampleNumber == 0 { return "待采样" }
        return context.isStale ? "过期" : nil
    }

    private func sampleInfo(_ context: ActivityViewContext<SpeedAttributes>) -> some View {
        let state = context.state
        let stamp = state.sampledAt.formatted(.dateTime.hour().minute().second())
        let label = state.sampleNumber.map { "样本 #\($0)" } ?? "采样"
        let note = state.sampleNumber == 0 ? "等待首个有效样本" : "\(context.isStale ? "上次" : "")\(label) · \(stamp)"
        return VStack(alignment: .leading, spacing: 2) {
            Text(note).contentTransition(.identity)
            HStack(spacing: 4) {
                Text("系统计时对照")
                Text(context.attributes.startedAt, style: .timer).monospacedDigit()
            }
            HStack(spacing: 6) {
                Text("剩余预约 \(state.pendingRelays ?? 0) · 接力 \(state.totalRelays ?? 0)")
                if let next = state.nextRelay {
                    Text("下次")
                    Text(timerInterval: min(context.attributes.startedAt, next)...next, countsDown: true)
                        .monospacedDigit()
                }
            }
        }.font(.caption2).foregroundStyle(.secondary)
    }

    private func compact(_ icon: String, _ value: Double, _ tint: Color, _ unavailable: String?, minimal: Bool = false) -> some View {
        let p = RateText.parts(value)
        let column: CGFloat = minimal ? 27 : 38
        return HStack(spacing: 2) {
            Image(systemName: icon).font(.system(size: 9, weight: .bold)).foregroundStyle(tint)
                .frame(width: 10, height: 12)
            VStack(alignment: .leading, spacing: 0) {
                Text(unavailable == nil ? p.0 : "—")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .monospacedDigit().minimumScaleFactor(0.6).lineLimit(1)
                    .frame(width: column, height: 14, alignment: .leading)
                Text(unavailable ?? p.1).font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.secondary).minimumScaleFactor(0.65).lineLimit(1)
                    .frame(width: column, height: 10, alignment: .leading)
            }.contentTransition(.identity)
        }.frame(width: column + 12, height: 24, alignment: .leading)
            .foregroundStyle(.white).transaction { $0.animation = nil }
    }

    private func detailed(_ title: String, _ icon: String, _ value: Double, _ tint: Color, _ unavailable: String?) -> some View {
        let p = RateText.parts(value)
        return VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(tint)
            Text(unavailable ?? "\(p.0) \(p.1)").font(.system(size: 21, weight: .semibold, design: .monospaced))
                .minimumScaleFactor(0.6).lineLimit(1).foregroundStyle(.white).contentTransition(.identity)
                .frame(width: 108, height: 26, alignment: .leading)
        }.frame(width: 108, alignment: .leading).transaction { $0.animation = nil }
    }
}
