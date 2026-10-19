import UIKit
import UniformTypeIdentifiers

typealias PlatformPasteboard = IOSPasteboard

extension DevicePlatform {
    @MainActor static var current: DevicePlatform {
        UIDevice.current.userInterfaceIdiom == .pad ? .ipad : .iphone
    }

    /// iOS 16+ no longer exposes the user-assigned device name, so start generic; it can be renamed in Settings.
    @MainActor static var defaultDeviceName: String {
        current == .ipad ? "iPad" : "iPhone"
    }
}

final class IOSPasteboard: PasteboardBridge {
    private static let imageTypes = [UTType.png, .jpeg, .heic, .tiff, .gif].map(\.identifier)

    var changeCount: Int { UIPasteboard.general.changeCount }
    private(set) var lastReadProblem: String?

    func read(includeImages: Bool, maxImageBytes: Int, skipConcealed: Bool) -> ClipContent? {
        let content = readContent(includeImages: includeImages, maxImageBytes: maxImageBytes)
        let pasteboard = UIPasteboard.general
        if content == nil, pasteboard.hasStrings || pasteboard.hasURLs || (includeImages && pasteboard.hasImages) {
            let state = UIApplication.shared.applicationState == .active ? "" : " (التطبيق بالخلفية)"
            lastReadProblem = "iOS منع قراءة الحافظة\(state) — الإعدادات ← CoShare ← «اللصق من التطبيقات الأخرى» ← «السماح»"
        } else {
            lastReadProblem = nil
        }
        return content
    }

    private func readContent(includeImages: Bool, maxImageBytes: Int) -> ClipContent? {
        let pasteboard = UIPasteboard.general
        // hasStrings / hasImages do not trigger the iOS "Allow Paste" prompt; only the reads below do.
        if pasteboard.hasStrings, let string = pasteboard.string, !string.isEmpty,
           !(includeImages && pasteboard.hasImages && Self.looksLikeURL(string)) {
            return .text(string)
        }
        if includeImages, pasteboard.hasImages {
            for uti in Self.imageTypes {
                guard let data = pasteboard.data(forPasteboardType: uti), !data.isEmpty else { continue }
                guard data.count <= maxImageBytes else { return nil }
                if uti == UTType.tiff.identifier || uti == UTType.gif.identifier {
                    return UIImage(data: data)?.pngData().map { .image($0, uti: UTType.png.identifier) }
                }
                return .image(data, uti: uti)
            }
            if let png = pasteboard.image?.pngData(), png.count <= maxImageBytes {
                return .image(png, uti: UTType.png.identifier)
            }
        }
        if pasteboard.hasURLs, let url = pasteboard.url {
            return .text(url.absoluteString)
        }
        return nil
    }

    func write(_ content: ClipContent) {
        // localOnly keeps Apple's Universal Clipboard from echoing the clip back to other devices.
        switch content {
        case .text(let string):
            UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: string]], options: [.localOnly: true])
        case .image(let data, let uti):
            UIPasteboard.general.setItems([[uti: data]], options: [.localOnly: true])
        }
    }

    private static func looksLikeURL(_ string: String) -> Bool {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count < 2048 && !trimmed.contains(" ") && trimmed.hasPrefix("http")
    }
}
