import AVKit
import Foundation
import ObjectiveC.runtime

// Independent, bounded runtime experiment inspired by GlobalRefresh-PiP.
// No swizzling, no class-wide hooks, no writes unless the ABI and original type match.
@MainActor enum PiPPrivateExperiment {
    private typealias Getter = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
    private typealias IntGetter = @convention(c) (AnyObject, Selector) -> Int
    private typealias IntSetter = @convention(c) (AnyObject, Selector, Int) -> Void
    private typealias Mutation = @convention(block) (AnyObject) -> Void
    private typealias Updater = @convention(c) (AnyObject, Selector, Mutation) -> Void
    private static func checked(_ object: AnyObject, _ name: String, _ result: String, _ args: [String] = []) -> Method? {
        guard let cls = object_getClass(object), let m = class_getInstanceMethod(cls, NSSelectorFromString(name)),
              method_getNumberOfArguments(m) == UInt32(args.count + 2) else { return nil }
        let r = method_copyReturnType(m)
        defer { free(r) }
        guard String(cString: r) == result else { return nil }
        for (i, expected) in args.enumerated() {
            guard let a = method_copyArgumentType(m, UInt32(i + 2)) else { return nil }
            let actual = String(cString: a); free(a)
            guard actual == expected else { return nil }
        }
        return m
    }
    private static func object(_ o: AnyObject, _ name: String) -> NSObject? {
        guard let m = checked(o, name, "@") else { return nil }
        return unsafeBitCast(method_getImplementation(m), to: Getter.self)(o, NSSelectorFromString(name))?.takeUnretainedValue() as? NSObject
    }
    private static func proxy(_ c: AVPictureInPictureController) -> NSObject? {
        guard let a = object(c, "platformAdapter") else { return nil }; return object(a, "pegasusProxy")
    }
    static func current(_ c: AVPictureInPictureController) -> Int? {
        guard let p = proxy(c), let s = object(p, "playbackState"), let m = checked(s, "contentType", "q") else { return nil }
        return unsafeBitCast(method_getImplementation(m), to: IntGetter.self)(s, NSSelectorFromString("contentType"))
    }
    static func request(_ c: AVPictureInPictureController) -> String {
        guard c.isPictureInPictureActive, let p = proxy(c), let s = object(p, "playbackState"),
              let original = current(c), [3, 4].contains(original),
              let m = checked(p, "updatePlaybackStateUsingBlock:", "v", ["@?"]),
              checked(s, "setContentType:", "v", ["q"]) != nil else { return "内部类型实验跳过：接口或初始类型不匹配" }
        // The block can be delivered asynchronously. Never use it after this session ends.
        let stateClass = object_getClass(s)
        let mutation: Mutation = { [weak c] state in
            guard Thread.isMainThread else { return }
            MainActor.assumeIsolated {
                guard let c, c.isPictureInPictureActive, object_getClass(state) === stateClass,
                      let setter = checked(state, "setContentType:", "v", ["q"]) else { return }
                unsafeBitCast(method_getImplementation(setter), to: IntSetter.self)(state, NSSelectorFromString("setContentType:"), 6)
            }
        }
        unsafeBitCast(method_getImplementation(m), to: Updater.self)(p, NSSelectorFromString("updatePlaybackStateUsingBlock:"), mutation)
        return "已请求内部类型 \(original) → 6（不代表系统接受）"
    }
    static func hideControls(_ c: AVPictureInPictureController) -> Bool {
        guard let m = checked(c, "setControlsStyle:", "v", ["q"]) else { return false }
        unsafeBitCast(method_getImplementation(m), to: IntSetter.self)(c, NSSelectorFromString("setControlsStyle:"), 2)
        return true
    }
}
