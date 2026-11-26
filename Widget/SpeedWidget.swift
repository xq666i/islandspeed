import ActivityKit
import SwiftUI
import WidgetKit

@main struct SpeedWidgetBundle: WidgetBundle {
    var body: some Widget { SpeedWidget() }
}

struct SpeedWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SpeedAttributes.self) { context in
            HStack(spacing: 18) {
                detailed("下载", "arrow.down", context.state.down, .green, context.isStale)
                Spacer()
                detailed("上传", "arrow.up", context.state.up, .cyan, context.isStale)
            }.padding(18).activityBackgroundTint(.black).activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    detailed("下载", "arrow.down", context.state.down, .green, context.isStale)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    detailed("上传", "arrow.up", context.state.up, .cyan, context.isStale)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.isStale ? "数据过期 · 打开 App 检查" : "采样 " + context.state.sampledAt.formatted(.dateTime.hour().minute().second()))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } compactLeading: {
                compact("arrow.down", context.state.down, .green, context.isStale)
            } compactTrailing: {
                compact("arrow.up", context.state.up, .cyan, context.isStale)
            } minimal: {
                compact("arrow.down", context.state.down, .green, context.isStale)
            }.keylineTint(.green)
        }
    }
    private func compact(_ icon: String, _ value: Double, _ tint: Color, _ stale: Bool) -> some View {
        let p = RateText.parts(value)
        return HStack(spacing: 2) {
            Image(systemName: icon).font(.system(size: 9, weight: .bold)).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 0) {
                Text(stale ? "—" : p.0).font(.system(size: 12, weight: .semibold, design: .monospaced)).minimumScaleFactor(0.7).lineLimit(1)
                Text(stale ? "暂停" : p.1).font(.system(size: 8, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
            }
        }.foregroundStyle(.white)
    }
    private func detailed(_ title: String, _ icon: String, _ value: Double, _ tint: Color, _ stale: Bool) -> some View {
        let p = RateText.parts(value)
        return VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(tint)
            Text(stale ? "—" : "\(p.0) \(p.1)").font(.system(size: 21, weight: .semibold, design: .monospaced)).minimumScaleFactor(0.6).lineLimit(1).foregroundStyle(.white)
        }
    }
}
