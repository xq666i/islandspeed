import AppIntents
import Foundation

// System-invoked user action, not a timer calling perform() directly.
@available(iOS 17.0, *)
struct RenewIslandIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "重建灵动网速"
    static var description = IntentDescription("在不打开主 App 的情况下，尝试重建正在监控的网速实时活动。")
    static var openAppWhenRun: Bool = false
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let monitor = SpeedMonitor.current, monitor.running else { return .result(dialog: "网速监控进程不在运行，请先打开 App 开始监控。") }
        if monitor.renewFromIntent() { return .result(dialog: "已请求新的网速实时活动。") }
        return .result(dialog: "重建未成功，旧活动保留。请查看 App 中的诊断。")
    }
}
@available(iOS 17.0, *)
struct IslandShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: RenewIslandIntent(), phrases: ["重建\(.applicationName)"], shortTitle: "重建灵动网速", systemImageName: "arrow.clockwise")
    }
}
