import SwiftUI

struct MenuView: View {
    @EnvironmentObject private var engine: SyncEngine
    @EnvironmentObject private var history: HistoryStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var log: ActivityLog

    @State private var tab: Tab
    @State private var copiedID: UUID?
    @State private var groupsRoute: GroupsRoute?
    /// A group just created: its page opens with the QR code showing.
    @State private var newGroupID: String?

    private let height: CGFloat

    init(tab: Tab = .history, route: GroupsRoute? = nil, inviteFor: String? = nil, height: CGFloat = 540) {
        _tab = State(initialValue: tab)
        _groupsRoute = State(initialValue: route)
        _newGroupID = State(initialValue: inviteFor)
        self.height = height
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
            PresenceBanner()
                .padding(.horizontal, 14)
                .padding(.top, engine.presence.isOnline ? 0 : 10)
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
        .frame(width: 380, height: height)
        .environment(\.layoutDirection, .rightToLeft)
    }

    // MARK: Header / footer

    private var header: some View {
        HStack(spacing: 10) {
            BrandMark(size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text("CoShare").font(.headline)
                HStack(spacing: 5) {
                    Circle().fill(statusColor).frame(width: 7, height: 7)
                    Text(statusText).font(.caption).foregroundColor(.secondary)
                }
            }
            Spacer()
            Button {
                if engine.presence.isOnline { settings.paused = true } else { engine.resumeToday() }
            } label: {
                Image(systemName: engine.presence.isOnline ? "pause.circle" : "play.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.borderless)
            .help(engine.presence.isOnline ? "إيقاف وفصل CoShare عن الشبكة" : "استئناف")
        }
    }

    private var statusText: String {
        switch engine.presence {
        case .paused: return "متوقف — منفصل عن الشبكة"
        case .quiet(let until): return "وقت الإيقاف حتى \(Format.clock(until, h24: settings.use24Hour))"
        case .online: break
        }
        let count = engine.connectedPeers.count
        return count == 0 ? "بانتظار أجهزة على نفس الشبكة…" : "متصل بـ \(count) \(count == 1 ? "جهاز" : "أجهزة")"
    }

    private var statusColor: Color {
        if !engine.presence.isOnline { return .paused }
        return engine.connectedPeers.isEmpty ? .waiting : .connected
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
                    RetentionNote()
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
                if let route = groupsRoute {
                    Button { groupsRoute = nil } label: {
                        Label("المجموعات", systemImage: "chevron.backward").font(.callout)
                    }
                    .buttonStyle(.borderless)
                    groupsScreen(route)
                } else {
                    GroupsHome { groupsRoute = $0 }
                }
            }
            .padding(14)
        }
        .id(groupsRoute)
    }

    @ViewBuilder private func groupsScreen(_ route: GroupsRoute) -> some View {
        switch route {
        case .create:
            Text("إنشاء مجموعة").font(.title3.weight(.bold))
            CreateGroupView { group in
                newGroupID = group.id
                groupsRoute = .group(group.id)
            }
        case .join:
            Text("انضمام لمجموعة").font(.title3.weight(.bold))
            JoinGroupView(onJoined: { groupsRoute = .group($0.id) }, onCancel: { groupsRoute = nil })
        case .group(let id):
            if let group = settings.groups.first(where: { $0.id == id }) {
                GroupDetailView(group: group, showInvite: newGroupID == id) { groupsRoute = nil }
            } else {
                Color.clear.onAppear { groupsRoute = nil }
            }
        }
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
                QuietScheduleEditor()
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    RetentionPicker().pickerStyle(.menu)
                    Text("الحافظة والسجل، مع الصور ولقطات الشاشة المنسوخة، بينحذفوا تلقائياً بعد هالمدة (الحد الأقصى أسبوع).")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    TimeFormatPicker().pickerStyle(.menu)
                }
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    DeviceNotificationToggles {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    DeviceNotificationNote()
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                Toggle("مزامنة الصور ولقطات الشاشة", isOn: $settings.syncImages)
                Toggle("تجاهل كلمات السر المنسوخة من مدير كلمات السر", isOn: $settings.skipConcealed)
                Toggle("إظهار CoShare في الـ Dock", isOn: $settings.showInDock)
                Text("افتح CoShare من أي مكان بالاختصار \(GlobalShortcut.display)، أو من الـ Dock أو Spotlight.")
                    .font(.caption)
                    .foregroundColor(.secondary)
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
                    Color.signal.opacity(configuration.isPressed ? 0.25 : (hovering ? 0.1 : 0))
                )
                .onHover { hovering = $0 }
        }
    }
}
