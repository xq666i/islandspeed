import ActivityKit
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
                DynamicIslandExpandedRegion(.bottom) { sampleInfo(context) }
            } compactLeading: {
                compact("arrow.down", context.state.down, .green, unavailable(context))
            } compactTrailing: {
                compact("arrow.up", context.state.up, .cyan, unavailable(context))
            } minimal: {
                compact("arrow.down", context.state.down, .green, unavailable(context))
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
        return Text(note).font(.caption2).foregroundStyle(.secondary)
    }

    private func compact(_ icon: String, _ value: Double, _ tint: Color, _ unavailable: String?) -> some View {
        let p = RateText.parts(value)
        return HStack(spacing: 2) {
            Image(systemName: icon).font(.system(size: 9, weight: .bold)).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 0) {
                Text(unavailable == nil ? p.0 : "—").font(.system(size: 12, weight: .semibold, design: .monospaced)).minimumScaleFactor(0.7).lineLimit(1)
                Text(unavailable ?? p.1).font(.system(size: 8, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
            }
        }.foregroundStyle(.white)
    }

    private func detailed(_ title: String, _ icon: String, _ value: Double, _ tint: Color, _ unavailable: String?) -> some View {
        let p = RateText.parts(value)
        return VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(tint)
            Text(unavailable ?? "\(p.0) \(p.1)").font(.system(size: 21, weight: .semibold, design: .monospaced)).minimumScaleFactor(0.6).lineLimit(1).foregroundStyle(.white)
        }
    }
}
