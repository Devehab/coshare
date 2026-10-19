import AVFoundation
import UIKit

/// Keeps the app alive in the background by playing silence through a mixable audio session
/// (the "audio" background mode). This is what lets the iPhone notice copies and receive clips
/// while you are in other apps. Not allowed on the App Store — fine for a personal, developer-installed app.
@MainActor
final class BackgroundKeeper: ObservableObject {
    static let shared = BackgroundKeeper()

    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String?

    private let audio = SilentAudio()
    private var observers: [NSObjectProtocol] = []
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    private init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let type = raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            Task { @MainActor in BackgroundKeeper.shared.handleInterruption(type) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { _ in
            // The audio daemon restarted: every audio object is dead and must be rebuilt.
            Task { @MainActor in BackgroundKeeper.shared.restart(rebuild: true) }
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { _ in
            Task { @MainActor in BackgroundKeeper.shared.restart(rebuild: false) }
        })
    }

    private var log: ActivityLog { SyncEngine.shared.log }

    /// Starts or stops according to the user's setting. Safe to call repeatedly.
    func applySetting() {
        if SyncEngine.shared.settings.keepAlive {
            start()
        } else {
            stop()
        }
    }

    func start() {
        audio.start { error in
            Task { @MainActor in BackgroundKeeper.shared.didStart(error) }
        }
    }

    func stop() {
        audio.stop { wasRunning in
            Task { @MainActor in BackgroundKeeper.shared.didStop(wasRunning) }
        }
    }

    private func didStart(_ error: Error?) {
        if let error {
            isRunning = false
            lastError = error.localizedDescription
            log.add("تعذّر تفعيل العمل بالخلفية: \(error.localizedDescription)", isError: true)
        } else if !isRunning {
            isRunning = true
            lastError = nil
            log.add("العمل الدائم بالخلفية مفعّل")
        }
    }

    private func didStop(_ wasRunning: Bool) {
        isRunning = false
        if wasRunning { log.add("العمل الدائم بالخلفية متوقف") }
    }

    private func restart(rebuild: Bool) {
        isRunning = false
        audio.markStopped(rebuild: rebuild)
        applySetting()
    }

    private func handleInterruption(_ type: AVAudioSession.InterruptionType?) {
        switch type {
        case .began:
            // A phone call or Siri took over the audio; the engine is stopped for us.
            isRunning = false
            audio.markStopped(rebuild: false)
            log.add("توقف العمل بالخلفية مؤقتاً (مكالمة أو تطبيق صوت)")
        case .ended:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.applySetting() }
        default:
            break
        }
    }

    /// Without keep-alive, ask iOS for ~30 s more so a copy made right after leaving the app still goes out.
    func beginGracePeriod() {
        guard !isRunning, backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "CoShare.flush") { [weak self] in
            self?.endGracePeriod()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in self?.endGracePeriod() }
    }

    func endGracePeriod() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}

/// Owns the audio engine. Everything runs on one serial queue, because activating an
/// AVAudioSession can block for a while and must not run on the main thread.
private final class SilentAudio: @unchecked Sendable {
    private let queue = DispatchQueue(label: "coshare.audio", qos: .userInitiated)
    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private var configured = false
    private var running = false

    func start(_ completion: @escaping @Sendable (Error?) -> Void) {
        queue.async { [self] in
            guard !running else { completion(nil); return }
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
                try session.setActive(true)
                if !configured {
                    let format = AVAudioFormat(standardFormatWithSampleRate: 22_050, channels: 1)
                    engine.attach(player)
                    engine.connect(player, to: engine.mainMixerNode, format: format)
                    configured = true
                }
                let format = player.outputFormat(forBus: 0)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate)) else {
                    throw NSError(domain: "CoShare", code: 1, userInfo: [NSLocalizedDescriptionKey: "تعذّر تجهيز الصوت الصامت"])
                }
                buffer.frameLength = buffer.frameCapacity
                if let channels = buffer.floatChannelData {
                    for channel in 0..<Int(format.channelCount) {
                        channels[channel].update(repeating: 0, count: Int(buffer.frameLength))
                    }
                }
                if !engine.isRunning { try engine.start() }
                player.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
                player.play()
                running = true
                completion(nil)
            } catch {
                completion(error)
            }
        }
    }

    /// Reports whether it was running before the call.
    func stop(_ completion: @escaping @Sendable (Bool) -> Void) {
        queue.async { [self] in
            guard running else { completion(false); return }
            player.stop()
            engine.stop()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            running = false
            completion(true)
        }
    }

    /// Call when the system stopped the engine behind our back (interruption, route change, reset).
    func markStopped(rebuild: Bool) {
        queue.async { [self] in
            player.stop()
            engine.stop()
            running = false
            if rebuild {
                engine = AVAudioEngine()
                player = AVAudioPlayerNode()
                configured = false
            }
        }
    }
}
