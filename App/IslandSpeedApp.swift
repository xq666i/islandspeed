import Foundation
import SwiftUI
import UIKit

@main @MainActor struct IslandSpeedApp: App {
    @StateObject private var monitor = SpeedMonitor.shared

    var body: some Scene {
        WindowGroup { ContentView(monitor: monitor) }
    }
}

@MainActor struct ContentView: View {
    @ObservedObject var monitor: SpeedMonitor
    @Environment(\.scenePhase) private var scenePhase
    @State private var page: Page = .monitor
    @State private var presentedSheet: Sheet?

    private enum Page: String, CaseIterable {
        case monitor = "监控"
        case settings = "设置"

        var symbol: String {
            self == .monitor ? "waveform.path.ecg.rectangle" : "slider.horizontal.3"
        }
    }

    private enum Sheet: String, Identifiable {
        case location = "为什么用到定位？"
        case appointments = "灵动岛接力"
        case activity = "网速卡操作"
        case stop = "停止监控？"
        case cancelAppointments = "取消剩余预约？"

        var id: Self { self }
    }

    private static let refreshOptions = [1, 2, 3, 5, 10, 15]
    private static let clockFormat = Date.FormatStyle(date: .omitted, time: .standard, locale: Locale(identifier: "en_GB"))

    init(monitor: SpeedMonitor) {
        self.monitor = monitor
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if page == .monitor {
                    header("灵动网速")
                    speedCard
                    locationCard
                    appointmentsCard
                } else {
                    header("设置", subtitle: "调整灵动岛更新、接力和后台定位")
                    settingsCards
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 24)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .id(page)
        .safeAreaInset(edge: .bottom, spacing: 0) { tabBar }
        .foregroundStyle(AppPalette.ink)
        .background(AppPalette.paper.ignoresSafeArea())
        .tint(AppPalette.coffee)
        .sheet(item: $presentedSheet) { sheet in
            sheetContent(sheet)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .onAppear { monitor.sceneChanged(scenePhase) }
        .onChange(of: scenePhase) { phase in monitor.sceneChanged(phase) }
        .onOpenURL { url in
            guard RelayRecoveryLink.activityID(from: url) != nil else { return }
            page = .monitor
            presentedSheet = nil
            monitor.openRelayRecovery(url)
        }
    }

    private func header(_ title: String, subtitle: String? = nil) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.largeTitle.weight(.bold)).accessibilityAddTraits(.isHeader)
                if let subtitle { note(subtitle) }
            }
            Spacer(minLength: 0)
            Image("SpeedMark").resizable().scaledToFill().frame(width: 39, height: 39)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)
        }
        .padding(.bottom, 4)
    }

    private var speedCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("实时网速").font(.subheadline.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 4)
                HStack(spacing: 6) {
                    Circle()
                        .fill(monitor.running ? AppPalette.down : AppPalette.oat)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                    Text(monitor.running ? "监控中" : monitor.starting ? "开启中" : "未开始")
                        .font(.caption2.weight(.semibold))
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(.white.opacity(0.12), in: Capsule())
            }
            HStack(spacing: 14) {
                rate("下载", symbol: "arrow.down", tint: AppPalette.down, value: monitor.down)
                Rectangle().fill(.white.opacity(0.17)).frame(width: 1, height: 55)
                    .accessibilityHidden(true)
                rate("上传", symbol: "arrow.up", tint: AppPalette.up, value: monitor.up)
            }
            Rectangle().fill(.white.opacity(0.17)).frame(height: 1).accessibilityHidden(true)
            Text(speedNote)
                .font(.footnote).foregroundStyle(AppPalette.heroMuted)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                if monitor.running { presentedSheet = .stop }
                else { Task { await monitor.start() } }
            } label: {
                Text(monitor.running ? "停止监控" : "开始监控")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .foregroundStyle(monitor.running ? AppPalette.heroText : AppPalette.heroBottom)
                    .background(monitor.running ? Color.clear : AppPalette.oat, in: RoundedRectangle(cornerRadius: 13))
                    .overlay {
                        RoundedRectangle(cornerRadius: 13)
                            .strokeBorder(monitor.running ? AppPalette.oat.opacity(0.36) : Color.clear)
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(monitor.starting)
            if !monitor.running && monitor.status == "请在设置中允许实时活动" {
                Button("打开系统设置", action: monitor.openSettings)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AppPalette.oat)
            }
        }
        .foregroundStyle(AppPalette.heroText)
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: 25)
                .fill(LinearGradient(colors: [AppPalette.heroTop, AppPalette.heroBottom],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        }
    }

    private func rate(_ title: String, symbol: String, tint: Color, value: Double) -> some View {
        let parts = RateText.parts(value)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.footnote.weight(.semibold)).foregroundStyle(tint)
                    .accessibilityHidden(true)
                Text(title).font(.caption).foregroundStyle(AppPalette.heroMuted)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(monitor.hasRecentReading ? parts.0 : "—")
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit().minimumScaleFactor(0.55).lineLimit(1)
                if monitor.hasRecentReading {
                    Text(parts.1).font(.caption2.weight(.medium))
                        .foregroundStyle(AppPalette.heroMuted).lineLimit(1).fixedSize()
                }
            }
            .contentTransition(.identity)
            .transaction { $0.animation = nil }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var speedNote: String {
        if monitor.running {
            if monitor.status != "监控中" { return monitor.status }
            if monitor.hasRecentReading, let lastSample = monitor.lastSample {
                return "最近采样 \(lastSample.formatted(Self.clockFormat)) · 切出后在灵动岛查看"
            }
            return "等待有效网速读数…"
        }
        if !["尚未开启", "已停止"].contains(monitor.status) { return monitor.status }
        return "开始监控后，切到其他 App 时可在灵动岛查看网速。"
    }

    private var locationCard: some View {
        card("后台定位", status: locationLabel, good: monitor.useLocation && monitor.canUseLocation) {
            note(locationExplanation)
            rowButton(monitor.canUseLocation ? "查看定位设置" : "设置后台定位") {
                presentedSheet = .location
            }
        }
    }

    private var locationLabel: String {
        if !monitor.useLocation { return "辅助已关闭" }
        return monitor.canUseLocation ? "已允许" : "未授权"
    }

    private var locationExplanation: String {
        if !monitor.useLocation { return "开启辅助后，App 可以借助定位在后台继续采样。" }
        if monitor.canUseLocation { return "定位辅助后台采样，位置不会保存或上传。" }
        return "定位是可选的。允许后，切到其他 App 时更容易继续采样。"
    }

    private var appointmentsCard: some View {
        card("灵动岛接力", status: queueLabel, good: monitor.running && monitor.queueIsReady && !monitor.arrangingAppointments) {
            if !SpeedMonitor.supportsReservations {
                note("预约接力需要 iOS 26 或更高版本。")
            } else if !monitor.relayEnabled {
                note("可在设置中开启自动接力。")
            } else if !monitor.running {
                note("同一张网速卡用久了，iOS 可能放慢刷新。开始监控后会预约最多 4 张新卡，到点自动接替，减少读数停更。")
            } else {
                appointmentTimeline
                if let next = monitor.appointmentDates.first {
                    let start = next.addingTimeInterval(-Double(monitor.relayInterval))
                    HStack(spacing: 6) {
                        Text("下次接力")
                        Text(timerInterval: start...next, countsDown: true, showsHours: false)
                            .monospacedDigit().fontWeight(.semibold)
                    }
                    .font(.footnote).foregroundStyle(AppPalette.muted)
                }
                note(queueExplanation)
            }
            if monitor.running {
                rowButton(monitor.relayEnabled ? "查看预约" : "网速卡操作") {
                    presentedSheet = monitor.relayEnabled ? .appointments : .activity
                }
            }
        }
    }

    private var queueLabel: String {
        if !SpeedMonitor.supportsReservations { return "系统不支持" }
        if !monitor.relayEnabled { return "已关闭" }
        if !monitor.running { return "待安排" }
        if monitor.arrangingAppointments { return "正在安排" }
        return "\(monitor.pendingCount)/\(RelaySchedule.capacity) 已预约"
    }

    private var queueExplanation: String {
        if monitor.arrangingAppointments { return "正在安排预约，请等排好后再切出。" }
        if monitor.queueIsReady { return "已排好，可切回其他 App。" }
        if monitor.pendingCount == 0 { return "当前无预约，可在「查看预约」中重新安排。" }
        return "可在「查看预约」中重排预约。"
    }

    private var appointmentTimeline: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("计划发起时间").font(.caption.weight(.medium)).foregroundStyle(AppPalette.muted)
            HStack(spacing: 5) {
                ForEach(0..<RelaySchedule.capacity, id: \.self) { index in
                    let date = index < monitor.appointmentDates.count ? monitor.appointmentDates[index] : nil
                    let isNext = date != nil && index == 0
                    VStack(spacing: 4) {
                        Rectangle()
                            .fill(date == nil ? AppPalette.line : isNext ? AppPalette.sage : AppPalette.segmentFilled)
                            .frame(height: 4)
                            .accessibilityHidden(true)
                        Text(date?.formatted(Self.clockFormat) ?? "—")
                            .font(.caption2.weight(.semibold)).monospacedDigit()
                            .lineLimit(1).minimumScaleFactor(0.6)
                            .padding(.horizontal, 2)
                            .padding(.bottom, 5)
                    }
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(isNext ? AppPalette.sage : AppPalette.muted)
                    .background(isNext ? AppPalette.sagePale : AppPalette.segment)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("第 \(index + 1) 次预约")
                    .accessibilityValue(date?.formatted(Self.clockFormat) ?? "未安排")
                }
            }
        }
    }

    private var settingsCards: some View {
        Group {
            card("网速更新") {
                intervalPicker("刷新间隔", selection: $monitor.refreshInterval, options: Self.refreshOptions)
                note("网速变化时，App 最快按所选间隔提交。画面何时刷新由 iOS 决定。")
            }
            card("灵动岛接力") {
                if SpeedMonitor.supportsReservations {
                    Toggle("自动接力", isOn: $monitor.relayEnabled)
                        .font(.subheadline.weight(.semibold))
                        .tint(AppPalette.sage)
                        .disabled(monitor.running || monitor.starting)
                    note("提前排好最多 4 次，到点换新的网速卡。")
                    if monitor.relayEnabled {
                        Divider()
                        intervalPicker("两次接力的间隔", selection: $monitor.relayInterval, options: RelaySchedule.intervalOptions)
                            .disabled(monitor.running || monitor.starting)
                    }
                    if monitor.running || monitor.starting { note("停止监控后可修改接力设置。") }
                } else {
                    note("预约接力需要 iOS 26 或更高版本。")
                }
            }
            card("后台定位") {
                Toggle("定位辅助", isOn: $monitor.useLocation)
                    .font(.subheadline.weight(.semibold)).tint(AppPalette.sage)
                note(locationExplanation)
                Divider()
                rowButton("定位权限 · \(locationLabel)") { presentedSheet = .location }
            }
        }
    }

    private func intervalPicker(_ title: String, selection: Binding<Int>, options: [Int]) -> some View {
        let current = selection.wrappedValue
        return HStack(spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold))
            Spacer(minLength: 4)
            Picker(title, selection: selection) {
                if !options.contains(current) { Text("\(current) 秒").tag(current) }
                ForEach(options, id: \.self) { seconds in Text("\(seconds) 秒").tag(seconds) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .background(AppPalette.segment, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var tabBar: some View {
        HStack(spacing: 6) {
            ForEach(Page.allCases, id: \.self) { tab in
                Button {
                    page = tab
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.symbol).font(.system(size: 17))
                        Text(tab.rawValue).font(.caption2.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .foregroundStyle(page == tab ? AppPalette.coffee : AppPalette.muted)
                    .background(page == tab ? AppPalette.selected : Color.clear, in: RoundedRectangle(cornerRadius: 13))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(page == tab ? .isSelected : [])
            }
        }
        .frame(maxWidth: 560)
        .padding(.horizontal, 13)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity)
        .background(AppPalette.bar.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) {
            Rectangle().fill(AppPalette.line).frame(height: 1).accessibilityHidden(true)
        }
    }

    private func sheetContent(_ sheet: Sheet) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(sheet.rawValue).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 8)
                    Button("关闭") { presentedSheet = nil }
                        .font(.subheadline.weight(.semibold)).frame(minHeight: 44)
                }
                switch sheet {
                case .location:
                    note("定位辅助用于让 App 切到后台后继续采样。你可以随时关闭。App 不保存、不上传位置。")
                    note("可以跳过授权直接开始监控。切到其他 App 后，iOS 可能暂停采样。")
                    Toggle("定位辅助", isOn: $monitor.useLocation).tint(AppPalette.sage)
                    note("当前权限 · \(monitor.permission)")
                    if monitor.useLocation && !monitor.authorized {
                        sheetAction(monitor.permissionButton, primary: true, action: monitor.requestPermission)
                        note(monitor.permissionHint)
                        if monitor.canUseLocation {
                            sheetAction("打开系统设置", action: monitor.openSettings)
                        }
                    } else {
                        sheetAction("打开系统设置", primary: true, action: monitor.openSettings)
                    }
                case .appointments:
                    note("当前有 \(monitor.pendingCount) 个预约。返回 App 后会重新安排，排好后再切出。")
                    ForEach(Array(monitor.appointmentDates.enumerated()), id: \.offset) { entry in
                        HStack {
                            Text("第 \(entry.offset + 1) 次").foregroundStyle(AppPalette.muted)
                            Spacer()
                            Text(entry.element.formatted(Self.clockFormat)).monospacedDigit()
                        }
                        .font(.subheadline).padding(.vertical, 3)
                    }
                    if monitor.running { note(queueExplanation) }
                    if monitor.renewStatus.contains("失败") { note(monitor.renewStatus) }
                    sheetAction("立即重建网速卡", primary: true) { monitor.renewNow() }
                        .disabled(!monitor.running || monitor.arrangingAppointments)
                    sheetAction("重排预约") { monitor.scheduleRelay() }
                        .disabled(!monitor.running || monitor.arrangingAppointments)
                    if monitor.pendingCount > 0 {
                        Button("取消剩余预约", role: .destructive) { presentedSheet = .cancelAppointments }
                            .font(.subheadline.weight(.semibold)).frame(minHeight: 44)
                            .disabled(monitor.arrangingAppointments)
                    }
                case .activity:
                    note("重建当前网速卡，采样继续运行。")
                    if monitor.renewStatus != "尚未重建" { note(monitor.renewStatus) }
                    sheetAction("立即重建网速卡", primary: true, action: monitor.renewNow)
                        .disabled(!monitor.running || monitor.editing)
                case .stop:
                    note("灵动岛网速卡将关闭，尚未开始的预约会一并取消。")
                    sheetAction("停止监控", primary: true) { monitor.stop(); presentedSheet = nil }
                case .cancelAppointments:
                    note("当前网速卡会继续工作。再次返回 App 或手动重排后，可重新预约。")
                    sheetAction("取消剩余预约", primary: true) { monitor.cancelRelay(); presentedSheet = nil }
                        .disabled(monitor.arrangingAppointments)
                }
            }
            .padding(20)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .foregroundStyle(AppPalette.ink)
        .tint(AppPalette.coffee)
        .background(AppPalette.card.ignoresSafeArea())
    }

    private func card<Content: View>(_ title: String, status: String? = nil, good: Bool = false,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.headline).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 4)
                if let status {
                    Text(status)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(good ? AppPalette.sage : AppPalette.muted)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(good ? AppPalette.sagePale : AppPalette.segment, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            content()
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppPalette.card, in: RoundedRectangle(cornerRadius: 19))
        .overlay { RoundedRectangle(cornerRadius: 19).strokeBorder(AppPalette.line) }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.footnote).foregroundStyle(AppPalette.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func rowButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.caption)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(AppPalette.coffee)
    }

    private func sheetAction(_ title: String, primary: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(MonitorSheetButtonStyle(primary: primary))
    }
}

private struct MonitorSheetButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    let primary: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(primary ? AppPalette.onCoffee : AppPalette.coffee)
            .background(primary ? AppPalette.coffee : AppPalette.segment, in: RoundedRectangle(cornerRadius: 13))
            .opacity(enabled ? (configuration.isPressed ? 0.82 : 1) : 0.48)
    }
}

private enum AppPalette {
    static let paper = adaptive(0xf7f3ed, 0x211a15)
    static let card = adaptive(0xfffdf9, 0x2d241e)
    static let ink = adaptive(0x28231f, 0xf2e6d8)
    static let muted = adaptive(0x685e54, 0xc9bcaf)
    static let line = adaptive(0xe9e1d6, 0x46392f)
    static let bar = adaptive(0xfbf7f0, 0x2a211b)
    static let coffee = adaptive(0x513c2e, 0xe4c4a8)
    static let onCoffee = adaptive(0xfff9ee, 0x302219)
    static let selected = adaptive(0xecdfcf, 0x493629)
    static let segment = adaptive(0xf5efe6, 0x3c3027)
    static let segmentFilled = adaptive(0x789581, 0x739784)
    static let sage = adaptive(0x30644e, 0xb5d2bd)
    static let sagePale = adaptive(0xe9f1e9, 0x2e4135)
    static let heroTop = Color(uiColor: rgb(0x443327))
    static let heroBottom = Color(uiColor: rgb(0x37291f))
    static let heroText = Color(uiColor: rgb(0xf9f1e7))
    static let heroMuted = Color(uiColor: rgb(0xecdfd1))
    static let oat = Color(uiColor: rgb(0xefdfcc))
    static let down = Color(uiColor: rgb(0xcfdfc7))
    static let up = Color(uiColor: rgb(0xe9bb91))

    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in rgb(traits.userInterfaceStyle == .dark ? dark : light) })
    }

    private static func rgb(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 255) / 255,
                green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
}
