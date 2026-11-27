import ActivityKit
import AppIntents
import Foundation
import SwiftUI
import WidgetKit

@main struct SpeedWidgetBundle: WidgetBundle {
    var body: some Widget { SpeedWidget() }
}

struct SpeedWidget: Widget {
    private static let clockFormat = Date.FormatStyle(date: .omitted, time: .standard, locale: Locale(identifier: "en_GB"))
    private static let timingColumnWidth: CGFloat = 86

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SpeedAttributes.self) { context in
            lockCard(context)
                .activityBackgroundTint(IslandPalette.lockBackground)
                .activitySystemActionForegroundColor(IslandPalette.text)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.bottom) {
                    expandedCard(context)
                }
            } compactLeading: {
                compact("下载", "arrow.down", context.state.down, IslandPalette.down, unavailable(context))
            } compactTrailing: {
                compact("上传", "arrow.up", context.state.up, IslandPalette.up, unavailable(context))
            } minimal: {
                compact("下载", "arrow.down", context.state.down, IslandPalette.down, unavailable(context), minimal: true)
            }
            .contentMargins(.horizontal, 26, for: .expanded)
            .contentMargins(.bottom, 13, for: .expanded)
        }
    }

    private func expandedCard(_ context: ActivityViewContext<SpeedAttributes>) -> some View {
        VStack(spacing: 3) {
            measures(context, expanded: true)
            activityDetails(context, onLockScreen: false)
            if #available(iOS 17.0, *) {
                relayActions(context)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func lockCard(_ context: ActivityViewContext<SpeedAttributes>) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image("SpeedMark").resizable().scaledToFill().frame(width: 16, height: 16)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .accessibilityHidden(true)
                Text("灵动网速").font(.caption.weight(.semibold)).foregroundStyle(IslandPalette.text)
                Spacer(minLength: 6)
                stableText(context.state.sampleNumber.flatMap { $0 > 0 ? "样本 #\($0)" : nil } ?? "样本 —")
                    .font(.caption2).foregroundStyle(IslandPalette.secondary)
            }
            measures(context)
            Rectangle().fill(IslandPalette.rule).frame(height: 1).accessibilityHidden(true)
            activityDetails(context, onLockScreen: true)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity)
    }

    private func measures(_ context: ActivityViewContext<SpeedAttributes>, expanded: Bool = false) -> some View {
        let availability = unavailable(context)
        return HStack(spacing: 12) {
            detailed("下载", "arrow.down", context.state.down, IslandPalette.down, availability, expanded: expanded)
            Rectangle().fill(IslandPalette.rule).frame(width: 1, height: expanded ? 31 : 38)
                .accessibilityHidden(true)
            detailed("上传", "arrow.up", context.state.up, IslandPalette.up, availability, expanded: expanded)
        }
    }

    private func activityDetails(_ context: ActivityViewContext<SpeedAttributes>, onLockScreen: Bool) -> some View {
        let state = context.state
        let queueEnabled = state.alignedRelays != nil
        let count = state.pendingRelays ?? 0
        let runs = "接力 \(state.totalRelays ?? 0) 次"
        let reservations = queueEnabled ? "预约 \(count)/4 · \(runs)" : runs
        let reading = lastUpdated(context, onLockScreen: onLockScreen)
        return VStack(spacing: 1) {
            HStack(spacing: 8) {
                stableText(reading).frame(maxWidth: .infinity, alignment: .leading)
                timingRow("运行", value: Text(context.attributes.startedAt, style: .timer))
            }
            HStack(spacing: 8) {
                stableText(reservations).frame(maxWidth: .infinity, alignment: .leading)
                if let next = state.nextRelay {
                    timingRow("下次", value: Text(timerInterval: min(context.attributes.startedAt, next)...next,
                                                 countsDown: true, showsHours: false))
                } else if queueEnabled && state.pendingRelays == 0 {
                    Text("预约已用完")
                        .frame(width: Self.timingColumnWidth, alignment: .leading)
                }
            }
        }
        .font(.system(size: onLockScreen ? 11 : 10.5))
        .foregroundStyle(IslandPalette.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.75)
    }

    private func timingRow(_ title: String, value: Text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(title).fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 4)
            value.monospacedDigit().frame(width: 57, alignment: .trailing)
        }
        .frame(width: Self.timingColumnWidth, alignment: .leading)
    }

    private func lastUpdated(_ context: ActivityViewContext<SpeedAttributes>, onLockScreen: Bool) -> String {
        if let missing = unavailable(context) {
            if onLockScreen && (context.state.lostSample == true || context.isStale) {
                return "上次 \(context.state.sampledAt.formatted(Self.clockFormat))"
            }
            return missing == "待采样" ? "等待采样" : missing == "过期" ? "读数已过期" : "暂无有效读数"
        }
        return "更新 \(context.state.sampledAt.formatted(Self.clockFormat))"
    }

    @available(iOS 17.0, *)
    private func relayActions(_ context: ActivityViewContext<SpeedAttributes>) -> some View {
        let relayEnabled = context.state.alignedRelays != nil
        return HStack(spacing: 8) {
            if #available(iOS 26.0, *), relayEnabled {
                let full = (context.state.pendingRelays ?? 0) >= 4
                Button(intent: ReserveOneIslandIntent(activityID: context.activityID)) {
                    RelayPill(title: full ? "预约已满" : "新增预约")
                }
                .disabled(full)
            }
            if relayEnabled, context.state.pendingRelays == 0,
               let url = RelayRecoveryLink.url(activityID: context.activityID) {
                Link(destination: url) {
                    RelayPill(title: "打开并补齐")
                }
            } else {
                Button(intent: RelayIslandMainIntent(activityID: context.activityID)) {
                    RelayPill(title: relayEnabled ? "立即接力" : "刷新")
                }
            }
        }
        .buttonStyle(RelayPressStyle())
        .frame(maxWidth: 278)
        .frame(maxWidth: .infinity)
    }

    private func unavailable(_ context: ActivityViewContext<SpeedAttributes>) -> String? {
        if context.state.sampleNumber == 0 { return context.state.lostSample == true ? "无样本" : "待采样" }
        return context.isStale ? "过期" : nil
    }

    private func compact(_ title: String, _ icon: String, _ value: Double, _ tint: Color,
                         _ unavailable: String?, minimal: Bool = false) -> some View {
        let parts = RateText.parts(value)
        let number = unavailable == nil ? parts.0 : "—"
        let unit = unavailable ?? parts.1
        let column: CGFloat = minimal ? 27 : 38
        return HStack(spacing: 2) {
            Image(systemName: icon).font(.system(size: 9, weight: .bold)).foregroundStyle(tint)
                .frame(width: 10, height: 12)
            VStack(alignment: .leading, spacing: 0) {
                stableText(number)
                    .font(.system(size: minimal ? 11 : 12, weight: .semibold, design: .monospaced))
                    .minimumScaleFactor(0.6).lineLimit(1)
                    .frame(width: column, height: 14, alignment: .leading)
                stableText(unit).font(.system(size: 8, weight: .medium))
                    .foregroundStyle(IslandPalette.secondary).minimumScaleFactor(0.65).lineLimit(1)
                    .frame(width: column, height: 10, alignment: .leading)
            }
        }
        .frame(width: column + 12, height: 24, alignment: .leading)
        .foregroundStyle(IslandPalette.text).transition(.identity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(unavailable ?? "\(number) \(unit)")
    }

    private func detailed(_ title: String, _ icon: String, _ value: Double, _ tint: Color,
                          _ unavailable: String?, expanded: Bool) -> some View {
        let parts = RateText.parts(value)
        let number = unavailable == nil ? parts.0 : "—"
        let unit = unavailable ?? parts.1
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 11, weight: .bold)).foregroundStyle(tint)
                    .accessibilityHidden(true)
                Text(title).font(.system(size: expanded ? 11 : 12)).foregroundStyle(IslandPalette.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                stableText(number).font(.system(size: expanded ? 20 : 23, weight: .semibold, design: .rounded))
                    .foregroundStyle(unavailable == nil ? tint : IslandPalette.text)
                    .minimumScaleFactor(0.55)
                stableText(unit).font(.system(size: expanded ? 9 : 10, weight: .medium))
                    .foregroundStyle(IslandPalette.secondary)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .frame(height: expanded ? 22 : 25, alignment: .leading)
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.identity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(unavailable ?? "\(number) \(unit)")
    }

    private func stableText(_ text: String) -> some View {
        Text(text).monospacedDigit()
            .contentTransition(.identity).transition(.identity)
            .animation(nil, value: text)
    }
}

private struct RelayPressedKey: EnvironmentKey {
    static let defaultValue = false
}

private extension EnvironmentValues {
    var relayPressed: Bool {
        get { self[RelayPressedKey.self] }
        set { self[RelayPressedKey.self] = newValue }
    }
}

private struct RelayPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .environment(\.relayPressed, configuration.isPressed)
            .animation(configuration.isPressed ? nil : .easeOut(duration: 0.24), value: configuration.isPressed)
    }
}

private struct RelayPill: View {
    @Environment(\.relayPressed) private var pressed
    let title: String

    var body: some View {
        Text(title).font(.system(size: 12, weight: .semibold))
            .lineLimit(1).minimumScaleFactor(0.8)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .foregroundStyle(pressed ? IslandPalette.pressedInk : IslandPalette.buttonText)
            .background(pressed ? IslandPalette.pressedFill : IslandPalette.buttonFill, in: Capsule())
            .padding(.horizontal, 4)
            .frame(height: 44)
            .contentShape(Rectangle())
    }
}

private enum IslandPalette {
    static let text = rgb(0xffffff)
    static let secondary = rgb(0xffffff)
    static let rule = Color.white.opacity(0.15)
    static let down = rgb(0x76e7a2)
    static let up = rgb(0x82ccff)
    static let lockBackground = rgb(0x000000)
    static let buttonText = rgb(0xffffff)
    static let buttonFill = rgb(0x262626)
    static let pressedInk = rgb(0x33251a)
    static let pressedFill = rgb(0xeadbc8)

    private static func rgb(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 255) / 255,
              green: Double((hex >> 8) & 255) / 255,
              blue: Double(hex & 255) / 255)
    }
}
