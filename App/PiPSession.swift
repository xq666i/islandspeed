import AVKit
import AVFoundation
import CoreMedia
import CoreVideo
import UIKit
import QuartzCore

enum PiPMode: String, CaseIterable, Identifiable {
    case videoCall = "VideoCall 原生"
    case internalType = "VideoCall 内部类型实验"
    case player = "PlayerLayer 视频"
    case sampleBuffer = "SampleBuffer 实时帧"
    var id: String { rawValue }
    var videoCall: Bool { self == .videoCall || self == .internalType }
}
enum PiPAudioMode: String, CaseIterable, Identifiable {
    case none = "不激活音频会话"
    case temporary = "启动后释放"
    case retained = "保持混音会话"
    var id: String { rawValue }
}
@MainActor final class PiPSession: NSObject, AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate {
    private var controller: AVPictureInPictureController?
    private var content: AVPictureInPictureVideoCallViewController?
    private var source: UIView?
    private var surface: CALayer?
    private var link: CADisplayLink?
    private var startup: Task<Void, Never>?
    private var privateTask: Task<Void, Never>?
    private var audioPrepared = false
    private var stopping = false
    private var generation = UUID()
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var playerLayer: AVPlayerLayer?
    private var bufferLayer: AVSampleBufferDisplayLayer?
    private var bufferPaused = false
    private var mode: PiPMode = .videoCall
    private var audioMode: PiPAudioMode = .temporary
    private var fps = 30
    private var hide = false
    private(set) var frames = 0
    private(set) var sentFrames = 0
    private(set) var status = "未开启"
    private(set) var privateStatus = "未启用"
    var onChange: (() -> Void)?
    var active: Bool { controller?.isPictureInPictureActive == true }
    var occupied: Bool { controller != nil }
    var suspended: Bool { controller?.isPictureInPictureSuspended == true }
    private func report(_ value: String) { status = value; onChange?() }
    func start(height: Double, mode: PiPMode, audioMode: PiPAudioMode, fps: Int, hide: Bool) {
        guard !occupied else { return }
        guard AVPictureInPictureController.isPictureInPictureSupported() else { report("系统不支持画中画"); return }
        guard UIApplication.shared.applicationState == .active,
              let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .filter({ $0.activationState == .foregroundActive }).flatMap({ $0.windows }).first(where: { $0.isKeyWindow }) else {
            report("请在 App 前台开启画中画"); return
        }
        self.mode = mode; self.audioMode = audioMode; self.fps = fps; self.hide = hide
        stopping = false; frames = 0; sentFrames = 0; bufferPaused = false; generation = UUID(); privateStatus = "未启用"
        let anchor = UIView(frame: CGRect(x: (window.bounds.width - 160) / 2, y: 100, width: 160, height: 90))
        anchor.backgroundColor = .clear; anchor.isOpaque = false; anchor.isUserInteractionEnabled = false
        window.addSubview(anchor); source = anchor
        let cs: AVPictureInPictureController.ContentSource
        if mode.videoCall {
            let vc = AVPictureInPictureVideoCallViewController()
            let size = CGSize(width: 300, height: CGFloat(height))
            vc.preferredContentSize = size; vc.view.frame = CGRect(origin: .zero, size: size)
            vc.view.backgroundColor = .clear; vc.view.isOpaque = false; vc.view.clipsToBounds = true
            let layer = CALayer(); layer.frame = vc.view.bounds
            layer.backgroundColor = UIColor(white: 1, alpha: 0.02).cgColor
            vc.view.layer.addSublayer(layer); surface = layer; content = vc
            cs = .init(activeVideoCallSourceView: anchor, contentViewController: vc)
        } else if mode == .player {
            guard let url = Bundle.main.url(forResource: "pip-test", withExtension: "mp4") else { clear("缺少 PiP 视频资源"); return }
            let q = AVQueuePlayer(); q.isMuted = true; q.volume = 0
            q.preventsDisplaySleepDuringVideoPlayback = false
            q.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
            let loop = AVPlayerLooper(player: q, templateItem: AVPlayerItem(url: url))
            let layer = AVPlayerLayer(player: q); layer.frame = anchor.bounds; layer.videoGravity = .resizeAspect
            anchor.layer.addSublayer(layer); player = q; looper = loop; playerLayer = layer
            cs = .init(playerLayer: layer)
        } else {
            let layer = AVSampleBufferDisplayLayer(); layer.frame = anchor.bounds; layer.videoGravity = .resizeAspect
            anchor.layer.addSublayer(layer); bufferLayer = layer
            cs = .init(sampleBufferDisplayLayer: layer, playbackDelegate: self)
            enqueueFrame()
        }
        let pip = AVPictureInPictureController(contentSource: cs)
        controller = pip; pip.delegate = self; pip.canStartPictureInPictureAutomaticallyFromInline = false; pip.requiresLinearPlayback = true
        if hide { privateStatus = PiPPrivateExperiment.hideControls(pip) ? "控件隐藏已请求" : "控件接口不支持" }
        if audioMode != .none {
            do { let audio = AVAudioSession.sharedInstance(); try audio.setCategory(.playback, mode: .default, options: [.mixWithOthers]); try audio.setActive(true); audioPrepared = true }
            catch { privateStatus += " · 音频会话失败：\(error.localizedDescription)" }
        }
        player?.play()
        // Start the sample buffer feed before AVKit readiness is tested.
        if mode == .sampleBuffer { startLink() }
        report("准备 \(mode.rawValue)，请暂留前台")
        let token = generation
        startup = Task { [weak self] in
            for _ in 0..<40 {
                guard let self, !Task.isCancelled, self.generation == token, self.controller === pip else { return }
                if pip.isPictureInPicturePossible {
                    pip.startPictureInPicture(); self.report("已请求启动画中画")
                    do { try await Task.sleep(for: .seconds(8)) } catch { return }
                    if self.generation == token, !pip.isPictureInPictureActive, !pip.isPictureInPictureSuspended { self.stop(reason: "画中画启动超时") }
                    return
                }
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            }
            guard let self, self.generation == token else { return }; self.stop(reason: "系统未允许启动画中画；可换音频会话策略")
        }
    }
    func setHeight(_ height: Double) { content?.preferredContentSize = CGSize(width: 300, height: CGFloat(height)) }
    private func releaseAudio() { if audioPrepared { audioPrepared = false; try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation]) } }
    private func startLink() {
        guard link == nil, fps > 0 else { return }
        let dl = CADisplayLink(target: self, selector: #selector(frame(_:))); dl.preferredFramesPerSecond = fps; dl.add(to: .main, forMode: .common); link = dl
    }
    private func clear(_ message: String) {
        generation = UUID(); startup?.cancel(); startup = nil; privateTask?.cancel(); privateTask = nil
        link?.invalidate(); link = nil; controller?.delegate = nil; controller = nil
        player?.pause(); looper?.disableLooping(); player?.removeAllItems(); looper = nil; player = nil
        playerLayer?.removeFromSuperlayer(); playerLayer = nil; bufferLayer?.flushAndRemoveImage(); bufferLayer?.removeFromSuperlayer(); bufferLayer = nil
        source?.removeFromSuperview(); source = nil; surface?.removeFromSuperlayer(); surface = nil; content = nil
        releaseAudio(); stopping = false; report(message)
    }
    func stop(reason: String = "已停止") {
        guard let pip = controller else { report(reason); return }
        startup?.cancel(); startup = nil; privateTask?.cancel(); privateTask = nil; link?.invalidate(); link = nil
        if pip.isPictureInPictureActive || pip.isPictureInPictureSuspended { stopping = true; pip.stopPictureInPicture(); report("正在停止画中画") }
        else { clear(reason) }
    }
    func pictureInPictureControllerDidStartPictureInPicture(_ pip: AVPictureInPictureController) {
        guard controller === pip else { return }; if stopping { pip.stopPictureInPicture(); return }
        startup?.cancel(); startup = nil
        if audioMode == .temporary { releaseAudio() }
        startLink()
        if hide { _ = PiPPrivateExperiment.hideControls(pip) }
        report("\(mode.rawValue) 运行中 · \(audioMode.rawValue)")
        if mode == .internalType {
            let token = generation
            privateTask = Task { [weak self, weak pip] in
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, let pip, self.generation == token, self.active, !self.stopping else { return }
                self.privateStatus = PiPPrivateExperiment.request(pip); self.onChange?()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard self.generation == token else { return }
                self.privateStatus += " · 本地读回：\(PiPPrivateExperiment.current(pip).map(String.init) ?? "未知")"; self.onChange?()
            }
        }
    }
    @objc private func frame(_ sender: CADisplayLink) {
        guard let controller, !stopping else { return }
        if mode == .sampleBuffer, !bufferPaused, !controller.isPictureInPictureSuspended { enqueueFrame() }
        guard controller.isPictureInPictureActive, !controller.isPictureInPictureSuspended else { return }
        frames += 1
        guard let surface, let view = content?.view else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true); surface.frame = view.bounds
        surface.backgroundColor = UIColor(white: 1, alpha: frames.isMultiple(of: 2) ? 0.01 : 0.025).cgColor; CATransaction.commit()
    }
    private func enqueueFrame() {
        guard let layer = bufferLayer else { return }
        if layer.status == .failed { layer.flush() }
        guard layer.isReadyForMoreMediaData else { return }
        var pixel: CVPixelBuffer?
        let options = [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, 320, 48, kCVPixelFormatType_32BGRA, options, &pixel) == kCVReturnSuccess, let pixel else { return }
        CVPixelBufferLockBaseAddress(pixel, [])
        if let base = CVPixelBufferGetBaseAddress(pixel) {
            let row = CVPixelBufferGetBytesPerRow(pixel)
            for y in 0..<48 {
                let p = base.advanced(by: y * row).assumingMemoryBound(to: UInt32.self)
                for x in 0..<320 { p[x] = (x < 2 + sentFrames % 316 && y >= 22 && y < 26) ? 0xff404040 : 0xff101010 }
            }
        }
        CVPixelBufferUnlockBaseAddress(pixel, [])
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel, formatDescriptionOut: &format) == noErr, let format else { return }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(max(1, fps))), presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else { return }
        if let array = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(array) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(array, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        layer.enqueue(sample); sentFrames += 1
    }
    func pictureInPictureController(_ pip: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) { guard controller === pip else { return }; clear("启动失败：\(error.localizedDescription)") }
    func pictureInPictureControllerDidStopPictureInPicture(_ pip: AVPictureInPictureController) { guard controller === pip else { return }; clear("画中画已停止，网速监控继续") }
    func pictureInPictureController(_ pip: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) { completionHandler(true) }
    func pictureInPictureController(_ pip: AVPictureInPictureController, setPlaying playing: Bool) { bufferPaused = !playing; pip.invalidatePlaybackState() }
    func pictureInPictureControllerTimeRangeForPlayback(_ pip: AVPictureInPictureController) -> CMTimeRange { CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity) }
    func pictureInPictureControllerIsPlaybackPaused(_ pip: AVPictureInPictureController) -> Bool { bufferPaused }
    func pictureInPictureController(_ pip: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}
    func pictureInPictureController(_ pip: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) { completionHandler() }
}
