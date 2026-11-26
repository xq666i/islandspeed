import BackgroundTasks
import Foundation

// One user-initiated job owns one concrete identifier. A late launch or expiration
// from a cancelled job must never start or stop the next measurement.
@MainActor
final class BackgroundMeasurement {
    let target: Int
    private let durationSeconds: Int
    private let identifier: String
    private var awaitingLaunch = false
    private var task: BGTask?
    private var launchTimeout: Task<Void, Never>?
    private var deadline: ContinuousClock.Instant?

    init(minutes: Int, samplesPerSecond: Int, bundleID: String) {
        durationSeconds = minutes * 60
        target = durationSeconds * samplesPerSecond
        identifier = "\(bundleID).measurement.\(UUID().uuidString)"
    }

    @available(iOS 26.0, *)
    func request(
        onStart: @escaping @MainActor () -> Void,
        onStop: @escaping @MainActor (String) -> Void
    ) throws {
        if let bundleID = Bundle.main.bundleIdentifier {
            let allowed = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? []
            let matches = allowed.contains {
                $0 == identifier || ($0.hasSuffix(".*") && identifier.hasPrefix(String($0.dropLast())))
            }
            guard matches else {
                throw MeasurementError.signedBundleID(bundleID)
            }
        }
        let scheduler = BGTaskScheduler.shared
        let registered = scheduler.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] rawTask in
            MainActor.assumeIsolated {
                guard let self, self.awaitingLaunch, let job = rawTask as? BGContinuedProcessingTask else {
                    rawTask.setTaskCompleted(success: false)
                    return
                }
                self.awaitingLaunch = false
                self.launchTimeout?.cancel()
                self.launchTimeout = nil
                self.task = job
                job.expirationHandler = { [weak self] in
                    Task { @MainActor in
                        guard let self, self.task != nil else { return }
                        onStop("后台测量已被系统或用户中止")
                    }
                }
                job.progress.totalUnitCount = Int64(self.target)
                job.progress.completedUnitCount = 0
                // Bound even a run in which the interfaces disappear or the device sleeps.
                self.deadline = ContinuousClock.now.advanced(by: .seconds(self.durationSeconds + 5))
                onStart()
            }
        }
        guard registered else { throw MeasurementError.registration }
        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier, title: "灵动网速 · 后台采样", subtitle: "准备采集 \(target) 个样本"
        )
        request.strategy = .fail
        awaitingLaunch = true
        do {
            try scheduler.submit(request)
        } catch {
            awaitingLaunch = false
            throw error
        }
        launchTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(12)) } catch { return }
            guard let self, self.awaitingLaunch else { return }
            onStop("系统未启动后台测量，请回到前台重新开启")
        }
    }

    var reachedDeadline: Bool {
        guard let deadline else { return false }
        return ContinuousClock.now >= deadline
    }

    func record(count: Int) {
        guard #available(iOS 26.0, *), let job = task as? BGContinuedProcessingTask else { return }
        job.progress.completedUnitCount = Int64(min(count, target))
    }

    // The system's own progress card can also show rates, even when it occupies
    // the island instead of the app's custom activity.
    func showRates(_ subtitle: String) {
        guard #available(iOS 26.0, *), let job = task as? BGContinuedProcessingTask else { return }
        job.updateTitle(job.title, subtitle: subtitle)
    }

    func finish(success: Bool) {
        launchTimeout?.cancel()
        launchTimeout = nil
        if awaitingLaunch {
            awaitingLaunch = false
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        }
        guard let job = task else { return }
        task = nil
        job.expirationHandler = nil
        job.setTaskCompleted(success: success)
    }

    enum MeasurementError: LocalizedError {
        case registration
        case signedBundleID(String)

        var errorDescription: String? {
            switch self {
            case .registration:
                return "后台任务注册失败，请检查签名后的 App 是否保留了后台处理模式和任务标识。"
            case let .signedBundleID(id):
                return "签名后的主 App 包名为 \(id)。请在 project.yml 中将 ISLANDSPEED_TASK_BUNDLE_ID 设为这个包名，重新构建并签名。"
            }
        }
    }
}
