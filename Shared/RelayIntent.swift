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
struct RelayIslandIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "立即接力"
    static var description = IntentDescription("尝试更新网速实时活动并补足预约，不打开 App。")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "当前活动标识") var activityID: String

    init() { activityID = "" }
    init(activityID: String) { self.activityID = activityID }

    @MainActor func perform() async throws -> some IntentResult {
        #if ISLANDSPEED_APP
        // Request runs directly in the system-authorized intent execution path.
        // Avoid an unstructured Task or a different monitor instance.
        _ = await SpeedMonitor.shared.renewFromIntent(activityID: activityID) { attributes, content in
            try Activity<SpeedAttributes>.request(attributes: attributes, content: content, pushType: nil)
        }
        #else
        // The system should dispatch LiveActivityIntent to the main app.
        // Do not pretend that the extension can start a new Live Activity.
        RelaySignal.postButtonFallback()
        #endif
        return .result()
    }
}
