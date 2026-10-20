import AVFoundation
import Vision
import SwiftUI

/// Camera + Vision QR reader, shared by the iPhone (back camera) and the Mac (built-in camera).
final class QRScanner: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    enum State: Equatable {
        case idle
        case starting
        case running
        case denied
        case unavailable
    }

    @Published private(set) var state: State = .idle
    let session = AVCaptureSession()

    private let queue = DispatchQueue(label: "coshare.qr", qos: .userInitiated)
    private var configured = false
    private var onCode: ((String) -> Void)?
    private var lastPayload: String?
    private var frameIndex = 0

    /// Starts the camera (asking for permission the first time) and reports every new QR payload.
    func start(onCode: @escaping (String) -> Void) {
        self.onCode = onCode
        lastPayload = nil
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            run()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { granted ? self.run() : (self.state = .denied) }
            }
        default:
            state = .denied
        }
    }

    func stop() {
        onCode = nil
        queue.async { if self.session.isRunning { self.session.stopRunning() } }
        state = .idle
    }

    /// Lets the same code be read again (e.g. after showing an error for it).
    func allowRescan() {
        queue.async { self.lastPayload = nil }
    }

    private func run() {
        state = .starting
        queue.async {
            if !self.configured {
                guard self.configure() else {
                    DispatchQueue.main.async { self.state = .unavailable }
                    return
                }
                self.configured = true
            }
            if !self.session.isRunning { self.session.startRunning() }
            DispatchQueue.main.async { self.state = self.session.isRunning ? .running : .unavailable }
        }
    }

    private func configure() -> Bool {
        #if os(iOS)
        let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(for: .video)
        #else
        let device = AVCaptureDevice.default(for: .video)
        #endif
        guard let device, let input = try? AVCaptureDeviceInput(device: device) else { return false }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
        guard session.canAddInput(input) else { return false }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { return false }
        session.addOutput(output)
        return true
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        frameIndex += 1
        guard frameIndex % 3 == 0, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        guard let payload = Self.detect(in: VNImageRequestHandler(cvPixelBuffer: pixels, options: [:])),
              payload != lastPayload
        else { return }
        lastPayload = payload
        DispatchQueue.main.async { self.onCode?(payload) }
    }

    /// First QR payload Vision finds in an image (also used to test decoding without a camera).
    static func detect(in handler: VNImageRequestHandler) -> String? {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try? handler.perform([request])
        return request.results?.compactMap(\.payloadStringValue).first
    }
}

/// Camera view that joins the group from a scanned CoShare invite.
struct QRJoinView: View {
    @EnvironmentObject private var engine: SyncEngine
    @StateObject private var scanner = QRScanner()
    /// Called with the joined group, or nil when cancelled.
    var onDone: (GroupMembership?) -> Void

    @State private var message: String?
    @State private var joinedName: String?

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Color.black
                if scanner.state == .running || scanner.state == .starting {
                    CameraPreview(session: scanner.session)
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 3, dash: [14, 10]))
                        .padding(36)
                }
                if let joinedName {
                    VStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 54)).foregroundColor(.green)
                        Text("انضممت لمجموعة «\(joinedName)»").font(.headline).foregroundColor(.white)
                    }
                } else if scanner.state == .denied {
                    statusText("ما في إذن للكاميرا. فعّله من إعدادات النظام ← الخصوصية ← الكاميرا ← CoShare.")
                } else if scanner.state == .unavailable {
                    statusText("ما لقينا كاميرا على هالجهاز.")
                }
            }
            .aspectRatio(4 / 3, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            Text(joinedName != nil ? "كل نسخ صار يوصل لأجهزة هالمجموعة." :
                    message ?? "وجّه الكاميرا على رمز الدعوة: من جهاز بالمجموعة افتح المجموعة واضغط «إظهار رمز QR لإضافة جهاز».")
                .font(.callout)
                .foregroundColor(message == nil || joinedName != nil ? .secondary : .red)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if joinedName == nil {
                Button("إلغاء") {
                    scanner.stop()
                    onDone(nil)
                }
                .buttonStyle(.bordered)
            }
        }
        .onAppear { scanner.start(onCode: handle) }
        .onDisappear { scanner.stop() }
    }

    private func statusText(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundColor(.white)
            .multilineTextAlignment(.center)
            .padding(24)
    }

    private func handle(_ payload: String) {
        guard joinedName == nil else { return }
        guard let url = URL(string: payload), let invite = GroupInvite.parse(url) else {
            message = "هاد الرمز مش دعوة CoShare."
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { scanner.allowRescan() }
            return
        }
        engine.join(invite: invite)
        joinedName = invite.name
        message = nil
        scanner.stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { onDone(invite) }
    }
}
