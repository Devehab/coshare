// Renders the HTML animation frame by frame (deterministic `renderAt(t)`) and pipes raw frames
// into ffmpeg. Usage:
//   Render <page-url> <out.mp4> [--fps 30] [--duration 60]
//   Render <page-url> --still <seconds> <out.jpg|png>
import AppKit
import WebKit

let width = 1920, height = 1080

@MainActor
final class Renderer: NSObject, WKNavigationDelegate {
    let web: WKWebView
    private let window: NSWindow
    private var loaded: CheckedContinuation<Void, Error>?

    override init() {
        let frame = NSRect(x: 0, y: 0, width: width, height: height)
        web = WKWebView(frame: frame, configuration: WKWebViewConfiguration())
        // WebKit only paints views that live in a window; park it off-screen.
        window = NSWindow(contentRect: frame.offsetBy(dx: -30000, dy: -30000), styleMask: [.borderless],
                          backing: .buffered, defer: false)
        window.contentView = web
        window.orderFrontRegardless()
        super.init()
        web.navigationDelegate = self
    }

    func load(_ url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            loaded = continuation
            web.load(URLRequest(url: url))
        }
        // Wait for web fonts and the first layout.
        for _ in 0..<200 {
            if (try? await web.evaluateJavaScript("window.READY === true")) as? Bool == true { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw NSError(domain: "Render", code: 1, userInfo: [NSLocalizedDescriptionKey: "page never became READY"])
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in self.loaded?.resume(); self.loaded = nil }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.loaded?.resume(throwing: error); self.loaded = nil }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.loaded?.resume(throwing: error); self.loaded = nil }
    }

    /// Renders time `t` and returns exactly 1920×1080 BGRA pixels.
    func frame(at t: Double) async throws -> CGImage {
        _ = try await web.evaluateJavaScript("renderAt(\(t)); 0")
        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = true
        let image = try await web.takeSnapshot(configuration: config)
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw NSError(domain: "Render", code: 2, userInfo: [NSLocalizedDescriptionKey: "snapshot failed"])
        }
        return cg
    }
}

/// Scales any snapshot (Retina gives 2×) into a reusable 1920×1080 BGRA buffer.
final class FrameBuffer {
    let context: CGContext
    init() {
        context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        context.interpolationQuality = .high
    }
    func draw(_ image: CGImage) -> Data {
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return Data(bytes: context.data!, count: width * height * 4)
    }
    func image() -> CGImage { context.makeImage()! }
}

func ffmpegPath() -> String {
    for path in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"] where FileManager.default.isExecutableFile(atPath: path) {
        return path
    }
    return "ffmpeg"
}

@MainActor
func run() async throws {
    var args = Array(CommandLine.arguments.dropFirst())
    guard args.count >= 2, let url = URL(string: args.removeFirst()) else {
        print("usage: Render <url> <out.mp4> [--fps 30] [--duration 60] | Render <url> --still <t> <out.jpg>")
        exit(2)
    }
    let renderer = Renderer()
    try await renderer.load(url)
    let buffer = FrameBuffer()

    if args.first == "--still" {
        let t = Double(args[1]) ?? 0
        let out = URL(fileURLWithPath: args[2])
        _ = buffer.draw(try await renderer.frame(at: t))
        let rep = NSBitmapImageRep(cgImage: buffer.image())
        let data = out.pathExtension.lowercased() == "png"
            ? rep.representation(using: .png, properties: [:])
            : rep.representation(using: .jpeg, properties: [.compressionFactor: 0.88])
        try data!.write(to: out)
        print("wrote \(out.path)")
        return
    }

    let out = args.removeFirst()
    var fps = 30.0, duration = 60.0
    while !args.isEmpty {
        let flag = args.removeFirst()
        if flag == "--fps", let v = Double(args.removeFirst()) { fps = v }
        if flag == "--duration", let v = Double(args.removeFirst()) { duration = v }
    }

    let ffmpeg = Process()
    ffmpeg.executableURL = URL(fileURLWithPath: ffmpegPath())
    ffmpeg.arguments = ["-y", "-loglevel", "error",
                        "-f", "rawvideo", "-pix_fmt", "bgra", "-s", "\(width)x\(height)", "-r", "\(fps)", "-i", "-",
                        "-c:v", "libx264", "-preset", "slow", "-crf", "18", "-pix_fmt", "yuv420p",
                        "-movflags", "+faststart", out]
    let pipe = Pipe()
    ffmpeg.standardInput = pipe
    try ffmpeg.run()

    let frames = Int((duration * fps).rounded())
    let started = Date()
    for i in 0..<frames {
        let t = Double(i) / fps
        let data = buffer.draw(try await renderer.frame(at: t))
        try pipe.fileHandleForWriting.write(contentsOf: data)
        if i % Int(fps * 5) == 0 {
            let elapsed = Date().timeIntervalSince(started)
            print(String(format: "  %5.1fs / %.0fs  (%.0f fps)", t, duration, Double(i + 1) / max(elapsed, 0.001)))
        }
    }
    try pipe.fileHandleForWriting.close()
    ffmpeg.waitUntilExit()
    guard ffmpeg.terminationStatus == 0 else { throw NSError(domain: "Render", code: 3, userInfo: [NSLocalizedDescriptionKey: "ffmpeg failed"]) }
    print("wrote \(out) in \(Int(Date().timeIntervalSince(started)))s")
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
Task { @MainActor in
    do {
        try await run()
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("render failed: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}
app.run()
