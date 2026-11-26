import AppIntents
import ActivityKit
import Foundation
import CoreFoundation

// Darwin fallback cannot confer system Intent execution rights.
enum RelaySignal {
    static var fallbackName: CFNotificationName {
        CFNotificationName(rawValue: "com.islandspeed.local.button-fallback.v118" as CFString)
    }
    static func postButtonFallback() {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), fallbackName, nil, nil, true)
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
        _ = await SpeedMonitor.shared.renewFromIntent(activityID: activityID, route: "系统 Intent 主程序", scheduleRequest: { attributes, content, alert, date in
            #if ISLANDSPEED_MAIN_TARGET_ROUTING
            if #available(iOS 27.0, *) {
                return try Activity<SpeedAttributes>.request(attributes: attributes, content: content, pushType: nil,
                    style: .standard, alertConfiguration: alert, start: date)
            }
            #endif
            #if compiler(>=6.2)
            if #available(iOS 26.0, *) {
                return try Activity<SpeedAttributes>.request(attributes: attributes, content: content, pushType: nil,
                    style: .standard, alertConfiguration: alert, startDate: date)
            }
            #endif
            throw NSError(domain: "IslandSpeed", code: 26, userInfo: [NSLocalizedDescriptionKey: "预约接口不可用"])
        }) { attributes, content in
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

@available(iOS 17.0, *)
struct ReserveOneIslandIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "补约测试"
    static var description = IntentDescription("独立测试后台预约一个活动，不立即接力、不取消旧预约。")
    static var openAppWhenRun: Bool = false
    #if ISLANDSPEED_MAIN_TARGET_ROUTING
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
        SpeedMonitor.shared.reserveOneFromIntent(activityID: activityID) { attributes, content, alert, date in
            #if ISLANDSPEED_MAIN_TARGET_ROUTING
            if #available(iOS 27.0, *) {
                return try Activity<SpeedAttributes>.request(attributes: attributes, content: content, pushType: nil,
                    style: .standard, alertConfiguration: alert, start: date)
            }
            #endif
            #if compiler(>=6.2)
            if #available(iOS 26.0, *) {
                return try Activity<SpeedAttributes>.request(attributes: attributes, content: content, pushType: nil,
                    style: .standard, alertConfiguration: alert, startDate: date)
            }
            #endif
            throw NSError(domain: "IslandSpeed", code: 26, userInfo: [NSLocalizedDescriptionKey: "预约接口不可用"])
        }
        #endif
        return .result()
    }
}
