import ActivityKit
import AppIntents
import Foundation

private struct RelayIntentError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private func requireHostApp() throws {
    throw RelayIntentError(message: "请打开灵动网速，由主 App 处理接力。")
}

@available(iOS 17.0, *)
struct RelayIslandMainIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "立即接力"
    static var description = IntentDescription("创建新的网速活动，保留其余预约。")
    static var openAppWhenRun: Bool = false
    #if ISLANDSPEED_MAIN_TARGET_ROUTING
    @available(iOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
    #endif
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "当前活动标识") var activityID: String
    init() { activityID = "" }
    init(activityID: String) { self.activityID = activityID }

    @MainActor func perform() async throws -> some IntentResult {
        #if ISLANDSPEED_APP
        let monitor = SpeedMonitor.shared
        guard await monitor.renewFromIntent(activityID: activityID, request: { attributes, content in
            try Activity<SpeedAttributes>.request(attributes: attributes, content: content, pushType: nil)
        }) else { throw RelayIntentError(message: monitor.buttonResult) }
        #else
        try requireHostApp()
        #endif
        return .result()
    }
}

@available(iOS 17.0, *)
struct ReserveOneIslandIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "重排预约"
    static var description = IntentDescription("按当前网速活动的时间表补一个预约。")
    static var openAppWhenRun: Bool = false
    #if ISLANDSPEED_MAIN_TARGET_ROUTING
    @available(iOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
    #endif
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "当前活动标识") var activityID: String
    init() { activityID = "" }
    init(activityID: String) { self.activityID = activityID }

    #if ISLANDSPEED_APP
    @available(iOS 26.0, *)
    @MainActor static func schedule(_ attributes: SpeedAttributes, _ content: ActivityContent<SpeedAttributes.ContentState>,
                                    _ alert: AlertConfiguration, _ date: Date) throws -> Activity<SpeedAttributes> {
        if #available(iOS 27.0, *) {
            return try Activity.request(attributes: attributes, content: content, pushType: nil,
                style: .standard, alertConfiguration: alert, start: date)
        }
        // Keep the original entry point shipped in the iOS 26.0 SDK.
        return try Activity.request(attributes: attributes, content: content, pushType: nil,
            style: .standard, alertConfiguration: alert, startDate: date)
    }
    #endif

    @MainActor func perform() async throws -> some IntentResult {
        #if ISLANDSPEED_APP
        let monitor = SpeedMonitor.shared
        guard #available(iOS 26.0, *) else { throw RelayIntentError(message: "当前系统不支持预约活动。") }
        guard await monitor.reserveOneFromIntent(activityID: activityID, request: Self.schedule) else { throw RelayIntentError(message: monitor.standaloneResult) }
        #else
        try requireHostApp()
        #endif
        return .result()
    }
}
