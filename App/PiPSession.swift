import AVKit
import AVFoundation
import UIKit
import QuartzCore

// Independent experiment using public AVKit APIs. See README for references.
@MainActor final class PiPSession: NSObject, AVPictureInPictureControllerDelegate {
    private var controller: AVPictureInPictureController?
    private var content: AVPictureInPictureVideoCallViewController?
    private var source: UIView?
    private var surface: CALayer?
    private var link: CADisplayLink?
    private var startup: Task<Void, Never>?
    private var audioPrepared = false
    private var stopping = false
    private var generation = UUID()
    private(set) var frames = 0
    private(set) var status = "未开启"
    var onChange: (() -> Void)?
    var active: Bool { controller?.isPictureInPictureActive == true }
    var occupied: Bool { controller != nil }
    var suspended: Bool { controller?.isPictureInPictureSuspended == true }

    private func report(_ value: String) { status = value; onChange?() }
    func start(height: Double) {
        guard !occupied else { return }
        guard AVPictureInPictureController.isPictureInPictureSupported() else { report("系统不支持画中画"); return }
        guard UIApplication.shared.applicationState == .active,
              let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .filter({ $0.activationState == .foregroundActive }).flatMap({ $0.windows }).first(where: { $0.isKeyWindow }) else {
            report("请在 App 前台开启画中画"); return
        }
        let anchor = UIView(frame: CGRect(x: (window.bounds.width - 160) / 2, y: 100, width: 160, height: 90))
        anchor.backgroundColor = .clear; anchor.isOpaque = false; anchor.isUserInteractionEnabled = false
        window.addSubview(anchor)
        source = anchor
        let vc = AVPictureInPictureVideoCallViewController()
        let size = CGSize(width: 300, height: CGFloat(height))
        vc.preferredContentSize = size
        vc.view.frame = CGRect(origin: .zero, size: size)
        vc.view.backgroundColor = .clear; vc.view.isOpaque = false; vc.view.clipsToBounds = true
        let layer = CALayer(); layer.frame = vc.view.bounds
        layer.backgroundColor = UIColor(white: 1, alpha: 0.02).cgColor
        vc.view.layer.addSublayer(layer); surface = layer; content = vc
        let source = AVPictureInPictureController.ContentSource(activeVideoCallSourceView: anchor, contentViewController: vc)
        let pip = AVPictureInPictureController(contentSource: source)
        controller = pip; pip.delegate = self
        pip.canStartPictureInPictureAutomaticallyFromInline = false
        pip.requiresLinearPlayback = true
        stopping = false; frames = 0; generation = UUID()
        let token = generation
        // No audio player, no recording. A temporary mixed playback session can help AVKit start.
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try audio.setActive(true)
            audioPrepared = true
        } catch { /* Continue and expose the AVKit startup result. */ }
        report("准备画中画，请暂留前台")
        startup = Task { [weak self] in
            for _ in 0..<30 {
                guard let self, !Task.isCancelled, self.generation == token, self.controller === pip else { return }
                if pip.isPictureInPicturePossible {
                    pip.startPictureInPicture()
                    self.report("已请求启动画中画")
                    do { try await Task.sleep(for: .seconds(8)) } catch { return }
                    if self.generation == token, !pip.isPictureInPictureActive, !pip.isPictureInPictureSuspended {
                        self.stop(reason: "画中画启动超时")
                    }
                    return
                }
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            }
            guard let self, self.generation == token else { return }
            self.stop(reason: "系统未允许启动画中画")
        }
    }
    func setHeight(_ height: Double) {
        content?.preferredContentSize = CGSize(width: 300, height: CGFloat(height))
    }
    private func releaseAudio() {
        if audioPrepared {
            audioPrepared = false
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        }
    }
    private func clear(_ message: String) {
        generation = UUID(); startup?.cancel(); startup = nil
        link?.invalidate(); link = nil
        controller?.delegate = nil; controller = nil
        source?.removeFromSuperview(); source = nil
        surface?.removeFromSuperlayer(); surface = nil; content = nil
        releaseAudio(); stopping = false; report(message)
    }
    func stop(reason: String = "已停止") {
        guard let pip = controller else { report(reason); return }
        startup?.cancel(); startup = nil; link?.invalidate(); link = nil
        if pip.isPictureInPictureActive || pip.isPictureInPictureSuspended {
            stopping = true; pip.stopPictureInPicture(); report("正在停止画中画")
        } else { clear(reason) }
    }
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        guard controller === pictureInPictureController else { return }
        if stopping { pictureInPictureController.stopPictureInPicture(); return }
        startup?.cancel(); startup = nil
        releaseAudio()
        let dl = CADisplayLink(target: self, selector: #selector(frame(_:)))
        dl.preferredFramesPerSecond = 30; dl.add(to: .main, forMode: .common); link = dl
        report("画中画运行中（仅 PiP，无音频播放）")
    }
    @objc private func frame(_ sender: CADisplayLink) {
        guard let controller, controller.isPictureInPictureActive, !controller.isPictureInPictureSuspended else { return }
        frames += 1
        guard let surface, let view = content?.view else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        surface.frame = view.bounds
        surface.backgroundColor = UIColor(white: 1, alpha: frames.isMultiple(of: 2) ? 0.01 : 0.025).cgColor
        CATransaction.commit()
    }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        guard controller === pictureInPictureController else { return }
        clear("启动失败：\(error.localizedDescription)")
    }
    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        guard controller === pictureInPictureController else { return }
        clear("画中画已停止，网速监控继续")
    }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }
}
