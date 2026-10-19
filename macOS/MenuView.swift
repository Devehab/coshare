import SwiftUI

struct MenuView: View {
    @EnvironmentObject private var engine: SyncEngine
    @EnvironmentObject private var history: HistoryStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var log: ActivityLog

    @State private var tab: Tab
    @State private var copiedID: UUID?
    @State private var scanningQR = false

    init(tab: Tab = .history) {
        _tab = State(initialValue: tab)
    }

    enum Tab: String, CaseIterable {
        case history = "الحافظة"
        case devices = "المجموعات"
        case log = "السجل"
        case settings = "الإعدادات"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)
            Picker("", selection: $tab) {
                // AppKit's segmented control ignores SwiftUI's RTL setting, so lay the tabs out right-to-left by hand.
                ForEach(Tab.allCases.reversed(), id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 14)
            Divider().padding(.top, 10)
            Group {
                switch tab {
                case .history: historyTab
                case .devices: devicesTab
                case .log: logTab
                case .settings: MacSettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        }
        .frame(width: 380, height: 540)
        .environment(\.layoutDirection, .rightToLeft)
    }

    // MARK: Header / footer

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.on.clipboard.fill")
                .font(.title2)
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("CoShare").font(.headline)
                HStack(spacing: 5) {
                    Circle().fill(statusColor).frame(width: 7, height: 7)
                    Text(statusText).font(.caption).foregroundColor(.secondary)
                }
            }
            Spacer()
            Button {
                settings.paused.toggle()
            } label: {
                Image(systemName: settings.paused ? "play.circle.fill" : "pause.circle")
                    .font(.title2)
            }
            .buttonStyle(.borderless)
            .help(settings.paused ? "استئناف المزامنة" : "إيقاف المزامنة مؤقتاً")
        }
    }

    private var statusText: String {
        if settings.paused { return "متوقف مؤقتاً" }
        let count = engine.connectedPeers.count
        return count == 0 ? "بانتظار أجهزة على نفس الشبكة…" : "متصل بـ \(count) \(count == 1 ? "جهاز" : "أجهزة")"
    }

    private var statusColor: Color {
        if settings.paused { return .gray }
        return engine.connectedPeers.isEmpty ? .orange : .green
    }

    private var footer: some View {
        HStack {
            Button("إرسال الحافظة الآن") {
                Task { await engine.sendCurrentClipboard() }
            }
            Spacer()
            Button("إنهاء CoShare") { NSApp.terminate(nil) }
        }
        .buttonStyle(.borderless)
        .font(.callout)
    }

    // MARK: Tabs

    @ViewBuilder private var historyTab: some View {
        if history.items.isEmpty {
            placeholder("doc.on.clipboard", "لا شيء بعد", "انسخ أي نص أو صورة على أي جهاز وسيظهر هنا.")
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(history.items) { item in
                        Button {
                            engine.copyToClipboard(item)
                            showCopied(item.id)
                        } label: {
                            HistoryRow(item: item, imageURL: history.imageURL(for: item), copied: copiedID == item.id)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(HoverRowStyle())
                        .contextMenu {
                            Button("نسخ") { engine.copyToClipboard(item); showCopied(item.id) }
                            Button("حذف") { history.delete(item) }
                        }
                        Divider().padding(.horizontal, 14)
                    }
                    Text("يُحفظ آخر ٢٤ ساعة فقط ويُحذف الأقدم تلقائياً")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(10)
                }
            }
        }
    }

    @ViewBuilder private var devicesTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if settings.groups.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("ابدأ من هون").font(.headline)
                        Text("هالجهاز مش بأي مجموعة لهلق. أنشئ مجموعة جديدة وحط إلها كلمة سر، أو انضم لمجموعة موجودة على نفس الشبكة.")
                            .font(.callout)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.12)))
                }
                if scanningQR {
                    sectionTitle("انضمام بمسح رمز QR")
                    QRJoinView { scanningQR = false }
                } else {
                    Button {
                        scanningQR = true
                    } label: {
                        Label("انضمام بمسح رمز QR بالكاميرا", systemImage: "qrcode.viewfinder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
                if !settings.groups.isEmpty {
                    sectionTitle("مجموعاتي")
                    ForEach(settings.groups) { GroupCard(group: $0) }
                }
                if !engine.nearbyGroups.isEmpty {
                    sectionTitle("مجموعات على نفس الشبكة")
                    ForEach(engine.nearbyGroups) { NearbyGroupRow(nearby: $0) }
                }
                sectionTitle(settings.groups.isEmpty ? "إنشاء مجموعة" : "إنشاء مجموعة أخرى")
                CreateGroupForm()
                if !engine.connectedPeers.isEmpty {
                    Divider()
                    sectionTitle("الأجهزة المتصلة (\(engine.connectedPeers.count))")
                    ForEach(engine.connectedPeers) { peer in
                        PeerRow(peer: peer, detail: peer.isDirect ? "اتصال مباشر" : "على نفس الشبكة")
                    }
                }
                Text("الجهاز ممكن يكون بأكتر من مجموعة، وكل نسخ بيوصل لكل مجموعاته.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(14)
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.caption.weight(.semibold)).foregroundColor(.secondary)
    }

    @ViewBuilder private var logTab: some View {
        if log.entries.isEmpty {
            placeholder("list.bullet.rectangle", "السجل فارغ", "")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(log.entries) { LogRow(entry: $0) }
                }
                .padding(14)
            }
        }
    }

    private func placeholder(_ symbol: String, _ title: String, _ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 34)).foregroundColor(.secondary)
            Text(title).font(.headline)
            if !message.isEmpty {
                Text(message).font(.callout).foregroundColor(.secondary).multilineTextAlignment(.center)
            }
        }
        .padding(24)
    }

    private func showCopied(_ id: UUID) {
        copiedID = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if copiedID == id { copiedID = nil }
        }
    }
}

private struct MacSettingsView: View {
    @EnvironmentObject private var engine: SyncEngine
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var history: HistoryStore
    @EnvironmentObject private var log: ActivityLog

    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                field("اسم الجهاز") {
                    TextField("مثلاً: MacBook المكتب", text: $settings.deviceName)
                        .textFieldStyle(.roundedBorder)
                }
                Divider()
                Toggle("مزامنة الصور ولقطات الشاشة", isOn: $settings.syncImages)
                Toggle("تجاهل كلمات السر المنسوخة من مدير كلمات السر", isOn: $settings.skipConcealed)
                Toggle("التشغيل تلقائياً عند بدء الجهاز", isOn: $launchAtLogin)
                    .onValueChange(of: launchAtLogin) { enabled in
                        do {
                            try LoginItem.setEnabled(enabled)
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                            launchAtLogin = LoginItem.isEnabled
                        }
                    }
                if let loginError {
                    Text(loginError).font(.caption).foregroundColor(.red)
                }
                Divider()
                HStack {
                    Button("مسح السجل والحافظة") {
                        history.clear()
                        log.clear()
                    }
                    Spacer()
                    Button("إعادة الاتصال") { engine.restartNetwork() }
                }
                Text("يعمل CoShare فقط على الشبكة المحلية، وكل البيانات مشفّرة بكلمة سر المجموعة.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
        }
        .onAppear { launchAtLogin = LoginItem.isEnabled }
    }

    private func field<Content: View>(_ title: String, note: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundColor(.secondary)
            content()
            if let note {
                Text(note).font(.caption2).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct HoverRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverRow(configuration: configuration)
    }

    private struct HoverRow: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(
                    Color.accentColor.opacity(configuration.isPressed ? 0.25 : (hovering ? 0.1 : 0))
                )
                .onHover { hovering = $0 }
        }
    }
}
