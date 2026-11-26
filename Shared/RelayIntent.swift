import AppIntents
import ActivityKit
import Foundation
import CoreFoundation

// Darwin notifications are only an experimental appearance hint. They do not
// launch the app or confer the execution rights of a system-invoked intent.
enum RelaySignal {
    static var name: CFNotificationName {
        CFNotificationName(rawValue: "com.islandspeed.local.expanded-relay.v118" as CFString)
    }
    static var fallbackName: CFNotificationName {
        CFNotificationName(rawValue: "com.islandspeed.local.button-fallback.v118" as CFString)
    }
    static func postButtonFallback() {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), fallbackName, nil, nil, true)
    }
    static func post() {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), name, nil, nil, true)
    }
}

@available(iOS 17.0, *)
struct RelayIslandMainIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "立即接力"
    static var description = IntentDescription("尝试更新网速实时活动并补足预约，不打开 App。")
    static var openAppWhenRun: Bool = false
    #if ISLANDSPEED_MAIN_TARGET_ROUTING
    // iOS 27 explicitly restricts the process executing this intent. The
    // property must be present in both targets' metadata, not just the app.
    @available(iOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
    #endif
    #if compiler(>=6.2)
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .background }
    #endif

    @Parameter(title: "当前活动标识") var activityID: String

    init() { activityID = "" }
    init(activityID: String) { self.activityID = activityID }

    @MainActor func perform() async throws -> some IntentResult {
        #if ISLANDSPEED_APP
        // Request runs directly in the system-authorized intent execution path.
        // Avoid an unstructured Task or a different monitor instance.
        _ = await SpeedMonitor.shared.renewFromIntent(activityID: activityID, route: "系统 Intent 主程序") { attributes, content in
            try Activity<SpeedAttributes>.request(attributes: attributes, content: content, pushType: nil)
        }
        #else
        // The system should dispatch LiveActivityIntent to the main app.
        // Signal the already running app; this does NOT transfer Intent authorization.
        RelaySignal.postButtonFallback()
        #endif
        return .result()
    }
}
