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

    private static func formatter(_ pattern: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.amSymbol = "AM"
        formatter.pmSymbol = "PM"
        formatter.dateFormat = pattern
        return formatter
    }

    private static let time12 = formatter("h:mm:ss a")
    private static let time24 = formatter("HH:mm:ss")
    private static let clock12 = formatter("h:mm a")
    private static let clock24 = formatter("HH:mm")

    static func ago(_ date: Date) -> String {
        Date().timeIntervalSince(date) < 10 ? "الآن" : relative.localizedString(for: date, relativeTo: Date())
    }

    /// Log times: "3:45:12 PM", or "15:45:12" with the 24-hour setting.
    static func time(_ date: Date, h24: Bool) -> String { ltr((h24 ? time24 : time12).string(from: date)) }

    /// "3:45 PM", or "15:45" with the 24-hour setting.
    static func clock(_ date: Date, h24: Bool) -> String { ltr((h24 ? clock24 : clock12).string(from: date)) }

    /// Keeps "3:45 PM" in that order inside Arabic text.
    private static func ltr(_ text: String) -> String { "\u{2066}" + text + "\u{2069}" }

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
    @EnvironmentObject private var settings: AppSettings
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
                Image(systemName: "checkmark.circle.fill").foregroundColor(.connected)
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
        return "\(source) · \(Format.clock(item.date, h24: settings.use24Hour)) · \(Format.ago(item.date))"
    }
}

/// "Kept for the last day — older items and their images are deleted automatically."
struct RetentionNote: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Text("يُحفظ آخر \(HistoryRetention.label(settings.historyRetentionHours)) فقط، والأقدم يُحذف تلقائياً مع صوره")
    }
}

/// Picker for how long history is kept (1 hour … 1 week).
struct RetentionPicker: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Picker("الاحتفاظ بالسجل", selection: $settings.historyRetentionHours) {
            ForEach(HistoryRetention.options, id: \.hours) { option in
                Text(option.hours == HistoryRetention.defaultHours ? option.label + " (افتراضي)" : option.label).tag(option.hours)
            }
        }
    }
}

/// 12-hour (AM/PM, default) or 24-hour times.
struct TimeFormatPicker: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Picker("صيغة الوقت", selection: $settings.use24Hour) {
            Text("١٢ ساعة (AM/PM)").tag(false)
            Text("٢٤ ساعة").tag(true)
        }
    }
}

/// Notify when a device of my groups comes in or goes out; each kind has its own switch.
struct DeviceNotificationToggles: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var notifier = PresenceNotifier.shared
    /// Opens this app's notification settings in the system (shown when they are turned off there).
    let openSystemSettings: () -> Void

    var body: some View {
        Group {
            Toggle("إشعارات الأجهزة", isOn: $settings.notifyDevices)
                .onValueChange(of: settings.notifyDevices) { on in notifier.prepare(enabled: on) }
            if settings.notifyDevices {
                Toggle("لما يدخل جهاز (ينضم أو يرجع متصل)", isOn: $settings.notifyJoins)
                Toggle("لما يطلع جهاز (ينقطع أو يوقّف)", isOn: $settings.notifyLeaves)
                if notifier.status == .denied {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("الإشعارات مسكّرة لـ CoShare من إعدادات النظام.")
                            .foregroundColor(.red)
                        Button("فتح إعدادات الإشعارات", action: openSystemSettings)
                    }
                }
            }
        }
        .onAppear { notifier.refreshStatus() }
    }
}

/// "You get a notification when …" — shared footer for the notification switches.
struct DeviceNotificationNote: View {
    var body: some View {
        Text("بيوصلك إشعار لما جهاز من مجموعاتك يتصل أو ينقطع، ومعه السبب إذا معروف. الجهاز اللي بينقطع وبيرجع خلال ثواني ما بيعمل إشعار.")
    }
}

/// A device in a group: icon, name, what it is and how it's connected.
struct DeviceRow: View {
    let symbol: String
    let name: String
    let detail: String
    var dot: Color = .connected

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: 30)
                .foregroundColor(.signal)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.callout).lineLimit(1)
                Text(detail).font(.caption).foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
            Circle().fill(dot).frame(width: 8, height: 8)
        }
        .padding(.vertical, 7)
    }
}

struct PeerRow: View {
    let peer: Peer
    var detail: String

    var body: some View {
        DeviceRow(symbol: peer.platform.symbolName, name: peer.name, detail: detail)
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

// MARK: - Groups

/// Screens inside "Groups": the list is the root, these open on top of it.
enum GroupsRoute: Hashable {
    case create
    case join
    case group(String)

    var title: String {
        switch self {
        case .create: return "إنشاء مجموعة"
        case .join: return "انضمام لمجموعة"
        case .group: return "المجموعة"
        }
    }
}

extension Color {
    static var panel: Color {
        #if os(iOS)
        Color(uiColor: .secondarySystemGroupedBackground)
        #else
        Color.secondary.opacity(0.08)
        #endif
    }

    // CoShare's palette, shared with the website: one signal colour for actions and selection,
    // teal for connected/secure, amber while waiting for devices, warm grey while paused.
    static let signal = adaptive(light: 0xd24a22, dark: 0xff6b3d)
    static let connected = adaptive(light: 0x0f7067, dark: 0x3fc3b2)
    static let waiting = adaptive(light: 0xd9971c, dark: 0xf2b23c)
    static let paused = adaptive(light: 0x857d6e, dark: 0x9a9182)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        func rgb(_ hex: UInt32) -> (CGFloat, CGFloat, CGFloat) {
            (CGFloat(hex >> 16 & 0xff) / 255, CGFloat(hex >> 8 & 0xff) / 255, CGFloat(hex & 0xff) / 255)
        }
        #if os(iOS)
        return Color(uiColor: UIColor { traits in
            let (r, g, b) = rgb(traits.userInterfaceStyle == .dark ? dark : light)
            return UIColor(red: r, green: g, blue: b, alpha: 1)
        })
        #else
        return Color(nsColor: NSColor(name: nil) { appearance in
            let (r, g, b) = rgb(appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light)
            return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        })
        #endif
    }
}

/// The CoShare mark (website/assets/logo.svg): two paper documents on the signal square.
struct BrandMark: View {
    var size: CGFloat = 28

    var body: some View {
        Canvas { context, canvas in
            let s = canvas.width / 64
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }
            let vermilion = Color(red: 0.824, green: 0.290, blue: 0.133)
            let paper = Color(red: 0.961, green: 0.941, blue: 0.910)

            context.fill(Path(roundedRect: CGRect(x: 0, y: 0, width: 64 * s, height: 64 * s), cornerRadius: 16 * s),
                         with: .color(vermilion))
            context.fill(Path(roundedRect: CGRect(x: 25 * s, y: 12 * s, width: 24 * s, height: 31 * s), cornerRadius: 5 * s),
                         with: .color(paper.opacity(0.5)))
            var front = Path()
            front.move(to: p(19.5, 21))
            front.addLine(to: p(32, 21))
            front.addLine(to: p(40, 29))
            front.addArc(tangent1End: p(40, 52), tangent2End: p(36, 52), radius: 4 * s)
            front.addArc(tangent1End: p(15.5, 52), tangent2End: p(15.5, 48), radius: 4 * s)
            front.addArc(tangent1End: p(15.5, 21), tangent2End: p(19.5, 21), radius: 4 * s)
            front.closeSubpath()
            context.fill(front, with: .color(paper))
            var fold = Path()
            fold.move(to: p(32, 21))
            fold.addArc(tangent1End: p(32, 29), tangent2End: p(40, 29), radius: 2.5 * s)
            fold.addLine(to: p(40, 29))
            context.stroke(fold, with: .color(vermilion), style: StrokeStyle(lineWidth: 2.4 * s, lineJoin: .round))
            var lines = Path()
            lines.move(to: p(22, 38.5)); lines.addLine(to: p(33, 38.5))
            lines.move(to: p(22, 44)); lines.addLine(to: p(29, 44))
            context.stroke(lines, with: .color(vermilion), style: StrokeStyle(lineWidth: 2.6 * s, lineCap: .round))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

extension View {
    /// Rounded panel used on the groups screens.
    func panel(padding: CGFloat = 12) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.panel))
    }
}

struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.caption.weight(.semibold)).foregroundColor(.secondary).padding(.horizontal, 4)
    }
}

/// Hint text under a section.
struct Hint: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }
}

struct GroupBadge: View {
    var size: CGFloat = 36

    var body: some View {
        Image(systemName: "person.3.fill")
            .font(.system(size: size * 0.36, weight: .semibold))
            .foregroundColor(.white)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .fill(Color.signal)
            )
    }
}

/// Big button with an icon and a one-line explanation.
struct ActionTile: View {
    let symbol: String
    let title: String
    let subtitle: String
    var selected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(selected ? .white : .signal)
                Text(title).font(.callout.weight(.semibold))
                Text(subtitle)
                    .font(.caption2)
                    .foregroundColor(selected ? .white.opacity(0.85) : .secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundColor(selected ? .white : .primary)
            .padding(.vertical, 14)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 100)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(selected ? Color.signal : Color.panel))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.signal.opacity(selected ? 0 : 0.35), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// "Active · 2 devices connected", "Active · waiting for devices", or paused.
struct GroupStatusLabel: View {
    @EnvironmentObject private var engine: SyncEngine
    let group: GroupMembership

    var body: some View {
        let status = self.status
        HStack(spacing: 5) {
            Circle().fill(status.color).frame(width: 7, height: 7)
            Text(status.text).font(.caption).foregroundColor(.secondary).lineLimit(1)
        }
    }

    private var status: (text: String, color: Color) {
        switch engine.presence {
        case .paused: return ("متوقفة — CoShare موقوف على هالجهاز", .paused)
        case .quiet: return ("متوقفة — وقت الإيقاف", .paused)
        case .online:
            let count = engine.members(of: group).count
            if count == 0 { return ("فعّالة · بانتظار أجهزة", .waiting) }
            return ("فعّالة · " + (count == 1 ? "جهاز متصل" : "\(count) أجهزة متصلة"), .connected)
        }
    }
}

struct GroupRow: View {
    let group: GroupMembership

    var body: some View {
        HStack(spacing: 12) {
            GroupBadge(size: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(group.name).font(.callout.weight(.semibold)).foregroundColor(.primary).lineLimit(1)
                GroupStatusLabel(group: group)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.forward").font(.caption.weight(.semibold)).foregroundColor(.secondary)
        }
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }
}

/// Root of "Groups": create / join at the top, then this device's groups.
struct GroupsHome: View {
    @EnvironmentObject private var engine: SyncEngine
    @EnvironmentObject private var settings: AppSettings
    let open: (GroupsRoute) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if settings.groups.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("ابدأ من هون").font(.headline)
                    Text("هالجهاز مش بأي مجموعة لهلق. أنشئ مجموعة جديدة لأجهزتك، أو انضم لمجموعة موجودة.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .panel()
            }
            HStack(spacing: 10) {
                ActionTile(symbol: "plus.circle.fill", title: "إنشاء مجموعة", subtitle: "مجموعة جديدة بكلمة سر") { open(.create) }
                ActionTile(symbol: "person.crop.circle.badge.plus", title: "انضمام لمجموعة", subtitle: "من الشبكة أو برمز QR") {
                    open(.join)
                }
            }
            if settings.groups.isEmpty && !engine.nearbyGroups.isEmpty {
                Hint("في \(engine.nearbyGroups.count) مجموعة ظاهرة على هالشبكة — اضغط «انضمام لمجموعة».")
            }
            if !settings.groups.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    SectionTitle("مجموعاتي (\(settings.groups.count))")
                    VStack(spacing: 0) {
                        ForEach(Array(settings.groups.enumerated()), id: \.element.id) { index, group in
                            if index > 0 { Divider() }
                            Button { open(.group(group.id)) } label: { GroupRow(group: group) }
                                .buttonStyle(.plain)
                        }
                    }
                    .panel(padding: 4)
                    Hint("اضغط على المجموعة لتشوف أجهزتها، أو لتضيف جهاز جديد برمز QR. الجهاز ممكن يكون بأكتر من مجموعة، وكل نسخ بيوصل لكل مجموعاته.")
                }
            }
        }
    }
}

/// One group: its connected devices, a QR code to add another device, and leaving.
struct GroupDetailView: View {
    @EnvironmentObject private var engine: SyncEngine
    @EnvironmentObject private var settings: AppSettings
    let group: GroupMembership
    var onLeave: () -> Void

    @State private var showInvite: Bool
    @State private var showPassword = false
    @State private var confirmLeave = false

    init(group: GroupMembership, showInvite: Bool = false, onLeave: @escaping () -> Void) {
        self.group = group
        self.onLeave = onLeave
        _showInvite = State(initialValue: showInvite)
    }

    var body: some View {
        let members = engine.members(of: group)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                GroupBadge(size: 48)
                VStack(alignment: .leading, spacing: 4) {
                    Text(group.name).font(.title3.weight(.bold)).lineLimit(2)
                    GroupStatusLabel(group: group)
                }
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionTitle("الأجهزة المتصلة (\(members.count + 1))")
                VStack(spacing: 0) {
                    DeviceRow(symbol: DevicePlatform.current.symbolName, name: settings.deviceName, detail: "هذا الجهاز",
                              dot: engine.presence.isOnline ? .connected : .paused)
                    ForEach(members) { peer in
                        Divider()
                        DeviceRow(symbol: peer.platform.symbolName, name: peer.name,
                                  detail: peer.platform.displayName + " · " + (peer.isDirect ? "اتصال مباشر" : "على نفس الشبكة"))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.panel))
                if members.isEmpty {
                    Hint("ما في أجهزة تانية متصلة هلق. تأكد إن CoShare شغّال عليها وإنها على نفس الشبكة، أو أضف جهاز جديد من تحت.")
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionTitle("إضافة جهاز جديد")
                VStack(spacing: 10) {
                    if showInvite {
                        QRCodeImage(url: engine.inviteURL(for: group)).frame(width: 190, height: 190)
                        Text("على الجهاز الجديد: افتح CoShare ← «انضمام لمجموعة» ← «مسح رمز QR» ووجّه الكاميرا على هالرمز. أو امسحه بكاميرا الآيفون مباشرة.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 6) {
                            Text("كلمة السر:").font(.caption).foregroundColor(.secondary)
                            Text(showPassword ? group.password : String(repeating: "•", count: max(6, group.password.count)))
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                            Button { showPassword.toggle() } label: {
                                Image(systemName: showPassword ? "eye.slash" : "eye")
                            }
                            .buttonStyle(.borderless)
                        }
                        Button("إخفاء الرمز") { showInvite = false; showPassword = false }
                            .buttonStyle(.borderless)
                            .font(.callout)
                    } else {
                        Button { showInvite = true } label: {
                            Label("إظهار رمز QR لإضافة جهاز", systemImage: "qrcode").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        Text("الجهاز الجديد بيمسح الرمز وبينضم فوراً، بدون ما تكتب كلمة السر.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity)
                .panel()
            }

            VStack(spacing: 10) {
                if confirmLeave {
                    Text("بعد المغادرة ما رح يوصلك نسخ أجهزة «\(group.name)»، ولا رح يوصلها نسخك.")
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Button(role: .destructive) {
                            engine.leave(group)
                            onLeave()
                        } label: {
                            Text("مغادرة المجموعة").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        Button { confirmLeave = false } label: { Text("إلغاء").frame(maxWidth: .infinity) }
                            .buttonStyle(.bordered)
                    }
                } else {
                    Button(role: .destructive) { confirmLeave = true } label: {
                        Label("مغادرة المجموعة", systemImage: "rectangle.portrait.and.arrow.right")
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

/// Join: pick a group seen on the network (with its password), or scan an invite QR code.
struct JoinGroupView: View {
    enum Method { case nearby, scan }

    @EnvironmentObject private var engine: SyncEngine
    @State private var method: Method
    let onJoined: (GroupMembership) -> Void
    let onCancel: () -> Void

    init(method: Method = .nearby, onJoined: @escaping (GroupMembership) -> Void, onCancel: @escaping () -> Void) {
        _method = State(initialValue: method)
        self.onJoined = onJoined
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ActionTile(symbol: "dot.radiowaves.left.and.right", title: "المجموعات القريبة", subtitle: "على نفس الشبكة",
                           selected: method == .nearby) { method = .nearby }
                ActionTile(symbol: "qrcode.viewfinder", title: "مسح رمز QR", subtitle: "بالكاميرا، بدون كلمة سر",
                           selected: method == .scan) { method = .scan }
            }
            switch method {
            case .nearby:
                nearby
            case .scan:
                QRJoinView { joined in
                    if let joined { onJoined(joined) } else { method = .nearby }
                }
            }
        }
    }

    @ViewBuilder private var nearby: some View {
        let groups = engine.nearbyGroups
        if groups.isEmpty {
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("عم ندوّر على مجموعات على نفس الشبكة…").font(.callout)
                Text("لازم يكون CoShare شغّال على جهاز بالمجموعة، وعلى نفس الواي فاي أو الـ Hotspot. إذا ما ظهرت، استعمل «مسح رمز QR».")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .panel(padding: 18)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle("اختر مجموعة وادخل كلمة سرها")
                VStack(spacing: 0) {
                    ForEach(Array(groups.enumerated()), id: \.element.id) { index, nearby in
                        if index > 0 { Divider() }
                        NearbyGroupRow(nearby: nearby, onJoined: onJoined)
                    }
                }
                .panel()
            }
        }
    }
}

/// A group seen on the network: join it with its password.
struct NearbyGroupRow: View {
    @EnvironmentObject private var engine: SyncEngine
    let nearby: NearbyGroup
    var onJoined: (GroupMembership) -> Void
    @State private var expanded = false
    @State private var password = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                GroupBadge(size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(nearby.group.name).font(.callout.weight(.semibold))
                    Text("فيها: " + nearby.memberNames.joined(separator: "، ")).font(.caption).foregroundColor(.secondary).lineLimit(2)
                }
                Spacer()
                if !expanded {
                    Button("انضمام") { expanded = true }
                        .buttonStyle(.borderedProminent)
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
        .padding(.vertical, 6)
    }

    private func join() {
        guard !password.isEmpty, !busy else { return }
        busy = true
        error = nil
        Task {
            do {
                let group = try await engine.join(nearby, password: password)
                onJoined(group)
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}

/// Name + password → a new private group, then straight to its QR code.
struct CreateGroupView: View {
    @EnvironmentObject private var engine: SyncEngine
    let onCreated: (GroupMembership) -> Void
    @State private var name = ""
    @State private var password = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("اسم المجموعة").font(.caption).foregroundColor(.secondary)
                    TextField("مثلاً: أجهزة إيهاب", text: $name)
                        .textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("كلمة السر").font(.caption).foregroundColor(.secondary)
                    SecureField("\(GroupMembership.minimumPasswordLength) أحرف أو أكثر", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(create)
                }
                Button(action: create) {
                    Text("إنشاء المجموعة").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty)
                if let error {
                    Text(error).font(.caption).foregroundColor(.red)
                }
            }
            .panel()
            Hint("بعد الإنشاء بيطلعلك رمز QR: امسحه من أجهزتك التانية لتنضم. كل جهاز بالمجموعة بيضل فيها حتى بعد إعادة التشغيل أو تغيير الشبكة، وكلمة السر بتشفّر كل شي بينكم.")
        }
    }

    private func create() {
        do {
            let group = try engine.createGroup(name: name, password: password)
            error = nil
            onCreated(group)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct LogRow: View {
    @EnvironmentObject private var settings: AppSettings
    let entry: ActivityLog.Entry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(Format.time(entry.date, h24: settings.use24Hour))
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

/// Days + from/to for the quiet hours.
struct QuietScheduleEditor: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("إيقاف تلقائي بأوقات محددة", isOn: $settings.quietEnabled)
            if settings.quietEnabled {
                HStack(spacing: 5) {
                    ForEach(QuietSchedule.dayOrder, id: \.self) { day in
                        let isOn = settings.quietSchedule.days.contains(day)
                        Button {
                            if isOn { settings.quietSchedule.days.remove(day) } else { settings.quietSchedule.days.insert(day) }
                        } label: {
                            Text(QuietSchedule.dayNames[day] ?? "")
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 7)
                                .background(Capsule().fill(isOn ? Color.signal : Color.secondary.opacity(0.15)))
                                .foregroundColor(isOn ? .white : .primary)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                HStack(spacing: 8) {
                    Text("من")
                    DatePicker("", selection: time(\.start), displayedComponents: .hourAndMinute).labelsHidden()
                    Text("إلى")
                    DatePicker("", selection: time(\.end), displayedComponents: .hourAndMinute).labelsHidden()
                    Spacer(minLength: 0)
                }
                .environment(\.locale, Locale(identifier: settings.use24Hour ? "en_GB" : "en_US"))
                Text("بهالأوقات CoShare بيوقف كلياً على هالجهاز: ما بيقرأ الحافظة، ولا بيبعت ولا بيستقبل، ولا بيظهر على الشبكة. وأجهزتك التانية بتعرف جدوله، فما بتحاول تتصل فيه.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func time(_ keyPath: WritableKeyPath<QuietSchedule, Int>) -> Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(byAdding: .minute, value: settings.quietSchedule[keyPath: keyPath],
                                      to: Calendar.current.startOfDay(for: Date())) ?? Date()
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                settings.quietSchedule[keyPath: keyPath] = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }
        )
    }
}

/// "Off the network until …" with the way back.
struct PresenceBanner: View {
    @EnvironmentObject private var engine: SyncEngine
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        switch engine.presence {
        case .online:
            EmptyView()
        case .paused:
            banner(symbol: "pause.circle.fill", text: "متوقف — CoShare منفصل تماماً عن الشبكة", button: "استئناف")
        case .quiet(let until):
            banner(symbol: "moon.zzz.fill",
                   text: "وقت الإيقاف حتى \(Format.clock(until, h24: settings.use24Hour)) — منفصل تماماً عن الشبكة",
                   button: "استئناف اليوم")
        }
    }

    private func banner(symbol: String, text: String, button: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundColor(.signal)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(button) { engine.resumeToday() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.signal.opacity(0.1)))
    }
}
