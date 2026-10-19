import SwiftUI
import ImageIO

extension View {
    /// `onChange` without the iOS 17 / macOS 14 deprecation warning, still working on iOS 16 / macOS 13.
    @ViewBuilder
    func onValueChange<V: Equatable>(of value: V, perform action: @escaping (V) -> Void) -> some View {
        if #available(iOS 17.0, macOS 14.0, *) {
            onChange(of: value) { _, newValue in action(newValue) }
        } else {
            onChange(of: value, perform: action)
        }
    }
}

enum Format {
    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "ar")
        formatter.unitsStyle = .short
        return formatter
    }()

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    static func ago(_ date: Date) -> String {
        Date().timeIntervalSince(date) < 10 ? "الآن" : relative.localizedString(for: date, relativeTo: Date())
    }

    static func time(_ date: Date) -> String { clock.string(from: date) }

    /// Wrapped in a left-to-right isolate so "125 KB" doesn't turn into "KB 125" inside Arabic text.
    static func bytes(_ count: Int) -> String {
        "\u{2066}" + ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file) + "\u{2069}"
    }
}

/// Small, cached thumbnails decoded with ImageIO so big screenshots never load in full.
enum Thumbnailer {
    private static let cache = NSCache<NSURL, CGImage>()

    static func image(for url: URL, maxPixel: Int = 160) -> CGImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        cache.setObject(image, forKey: url as NSURL)
        return image
    }
}

struct HistoryRow: View {
    let item: HistoryItem
    let imageURL: URL?
    var copied = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            thumbnail
                .frame(width: 42, height: 42)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.callout)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 4) {
                    Image(systemName: item.direction == .sent ? "arrow.up.forward" : "arrow.down.backward")
                    Text(subtitle)
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
            if copied {
                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
            }
        }
    }

    @ViewBuilder private var thumbnail: some View {
        if item.kind == .image, let url = imageURL, let image = Thumbnailer.image(for: url) {
            Image(decorative: image, scale: 1)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                Color.secondary.opacity(0.12)
                Image(systemName: item.kind == .image ? "photo" : "text.alignleft")
                    .foregroundColor(.secondary)
            }
        }
    }

    private var title: String {
        switch item.kind {
        case .text:
            let text = (item.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "(مسافات فارغة)" : text
        case .image:
            return "صورة · \(Format.bytes(item.byteCount))"
        }
    }

    private var subtitle: String {
        let source: String
        switch item.direction {
        case .sent:
            if let count = item.deliveredTo {
                source = count > 0 ? "من هذا الجهاز ← \(count) أجهزة" : "من هذا الجهاز (لم يصل لأحد)"
            } else {
                source = "من هذا الجهاز"
            }
        case .received:
            source = "من \(item.deviceName)"
        }
        return "\(source) · \(Format.ago(item.date))"
    }
}

struct PeerRow: View {
    let peer: Peer
    var detail: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: peer.platform.symbolName)
                .font(.title3)
                .frame(width: 28)
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(peer.name).font(.callout)
                Text(detail).font(.caption).foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
            Circle().fill(Color.green).frame(width: 8, height: 8)
        }
    }
}

/// QR code for a group invite; the phone camera opens CoShare and joins.
struct QRCodeImage: View {
    let url: URL

    var body: some View {
        if let image = GroupInvite.qrImage(for: url) {
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .padding(10)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

/// One of this device's groups: who is online, invite (QR + password) and leave.
struct GroupCard: View {
    @EnvironmentObject private var engine: SyncEngine
    let group: GroupMembership
    @State private var showInvite = false
    @State private var showPassword = false
    @State private var confirmLeave = false

    var body: some View {
        let members = engine.members(of: group)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "person.3.fill").foregroundColor(.accentColor)
                Text(group.name).font(.headline)
                Spacer()
                Text(members.isEmpty ? "لا أجهزة متصلة" : "\(members.count) متصل")
                    .font(.caption)
                    .foregroundColor(members.isEmpty ? .orange : .green)
            }
            if !members.isEmpty {
                Text(members.map(\.name).joined(separator: "، "))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            HStack(spacing: 10) {
                Button(showInvite ? "إخفاء الدعوة" : "دعوة جهاز") { showInvite.toggle() }
                Spacer()
                if confirmLeave {
                    Button("تأكيد المغادرة") { engine.leave(group) }.foregroundColor(.red)
                    Button("إلغاء") { confirmLeave = false }
                } else {
                    Button("مغادرة") { confirmLeave = true }.foregroundColor(.red)
                }
            }
            .buttonStyle(.borderless)
            .font(.callout)
            if showInvite {
                VStack(spacing: 8) {
                    QRCodeImage(url: engine.inviteURL(for: group)).frame(width: 180, height: 180)
                    Text("امسح الرمز بكاميرا الهاتف لينضم مباشرة، أو انضم من جهاز آخر بكلمة السر:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Text(showPassword ? group.password : String(repeating: "•", count: max(6, group.password.count)))
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                        Button { showPassword.toggle() } label: {
                            Image(systemName: showPassword ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.accentColor.opacity(0.08)))
    }
}

/// A group seen on the network: join it with its password.
struct NearbyGroupRow: View {
    @EnvironmentObject private var engine: SyncEngine
    let nearby: NearbyGroup
    @State private var expanded = false
    @State private var password = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "person.3").foregroundColor(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(nearby.group.name).font(.callout.weight(.semibold))
                    Text("فيها: " + nearby.memberNames.joined(separator: "، ")).font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                if !expanded {
                    Button("انضمام") { expanded = true }
                        .buttonStyle(.bordered)
                }
            }
            if expanded {
                HStack {
                    SecureField("كلمة سر المجموعة", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(join)
                    Button(busy ? "…" : "تأكيد", action: join)
                        .buttonStyle(.borderedProminent)
                        .disabled(password.isEmpty || busy)
                    Button("إلغاء") { expanded = false; password = ""; error = nil }
                        .buttonStyle(.borderless)
                }
                if let error {
                    Text(error).font(.caption).foregroundColor(.red)
                }
            }
        }
    }

    private func join() {
        guard !password.isEmpty, !busy else { return }
        busy = true
        error = nil
        Task {
            do {
                try await engine.join(nearby, password: password)
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}

/// Name + password → a new private group.
struct CreateGroupForm: View {
    @EnvironmentObject private var engine: SyncEngine
    @EnvironmentObject private var settings: AppSettings
    @State private var name = ""
    @State private var password = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("اسم المجموعة (مثلاً: أجهزة إيهاب)", text: $name)
                .textFieldStyle(.roundedBorder)
            SecureField("كلمة السر (\(GroupMembership.minimumPasswordLength) أحرف أو أكثر)", text: $password)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("إنشاء المجموعة") {
                    do {
                        try engine.createGroup(name: name, password: password)
                        name = ""
                        password = ""
                        error = nil
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty)
                Spacer()
            }
            if let error {
                Text(error).font(.caption).foregroundColor(.red)
            }
            Text("كل جهاز تدخل عليه نفس كلمة السر بيصير من المجموعة، وبيضل فيها حتى بعد إعادة التشغيل أو تغيير الشبكة.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct LogRow: View {
    let entry: ActivityLog.Entry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(Format.time(entry.date))
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
            Text(entry.text)
                .font(.caption)
                .foregroundColor(entry.isError ? .red : .primary)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
    }
}
