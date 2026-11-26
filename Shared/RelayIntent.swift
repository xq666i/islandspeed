import AppIntents
import Foundation
import CoreFoundation

// Darwin notifications are only an experimental appearance hint. They do not
// launch the app or confer the execution rights of a system-invoked intent.
enum RelaySignal {
    static var name: CFNotificationName {
        CFNotificationName(rawValue: "com.islandspeed.local.expanded-relay.v118" as CFString)
    }
    static func post() {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), name, nil, nil, true)
    }
}

@available(iOS 17.0, *)
struct RelayIslandIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "立即接力"
    static var description = IntentDescription("尝试更新网速实时活动并补足预约，不打开 App。")
    static var openAppWhenRun: Bool = false

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        #if ISLANDSPEED_APP
        guard let monitor = SpeedMonitor.current, monitor.running else {
            return .result(dialog: "网速监控进程未运行，请先打开 App 开始监控。")
        }
        if await monitor.renewFromIntent() {
            return .result(dialog: "已创建新活动；预约结果见诊断。")
        }
        return .result(dialog: "接力未完成，原活动保留或正在接力。")
        #else
        // Same intent type is compiled into the widget for Button(intent:).
        // LiveActivityIntent is expected to execute in the app process.
        return .result(dialog: "请通过主 App 执行接力。")
        #endif
    }
}
