import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var engine: SyncEngine
    @EnvironmentObject private var history: HistoryStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var log: ActivityLog
    @EnvironmentObject private var keeper: BackgroundKeeper

    @State private var showSettings = false
    @State private var showLog = false
    @State private var copiedID: UUID?
    @State private var busy = false
    @State private var showGroups = false
    @State private var pendingInvite: GroupMembership?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    statusRow
                    backgroundRow
                    HStack(spacing: 10) {
                        Button {
                            run { _ = await engine.sendCurrentClipboard() }
                        } label: {
                            Label("إرسال الحافظة", systemImage: "arrow.up.doc.on.clipboard")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        Button {
                            run { _ = await engine.pullLatest() }
                        } label: {
                            Label("جلب آخر نسخ", systemImage: "arrow.down.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                    .disabled(busy)
                }

                Section {
                    if settings.groups.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("هالجهاز مش بأي مجموعة لهلق").font(.headline)
                            Text("أنشئ مجموعة جديدة بكلمة سر، أو انضم لمجموعة موجودة على نفس الشبكة.")
                                .font(.callout)
                                .foregroundColor(.secondary)
                            Button("إعداد المجموعات") { showGroups = true }
                                .buttonStyle(.borderedProminent)
                        }
                        .padding(.vertical, 4)
                    } else {
                        ForEach(engine.connectedPeers) { peer in
                            PeerRow(peer: peer, detail: peer.isDirect ? "اتصال مباشر" : "على نفس الشبكة")
                        }
                        Button {
                            showGroups = true
                        } label: {
                            Label("المجموعات (\(settings.groups.map(\.name).joined(separator: "، ")))", systemImage: "person.3")
                        }
                    }
                } header: {
                    Text("أجهزتي")
                } footer: {
                    if !engine.nearbyGroups.isEmpty && settings.groups.isEmpty {
                        Text("في \(engine.nearbyGroups.count) مجموعة على نفس الشبكة — افتح «إعداد المجموعات» لتنضم.")
                    }
                }

                Section {
                    if history.items.isEmpty {
                        Text("لا شيء بعد — انسخ أي نص أو صورة على أي جهاز وسيظهر هنا.")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(history.items) { item in
                            Button {
                                engine.copyToClipboard(item)
                                copiedID = item.id
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                                    if copiedID == item.id { copiedID = nil }
                                }
                            } label: {
                                HistoryRow(item: item, imageURL: history.imageURL(for: item), copied: copiedID == item.id)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        .onDelete { offsets in
                            offsets.map { history.items[$0] }.forEach(history.delete)
                        }
                    }
                } header: {
                    Text("آخر ٢٤ ساعة")
                } footer: {
                    Text("اضغط على أي عنصر لنسخه من جديد. الأقدم من يوم يُحذف تلقائياً.")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("CoShare")
            .refreshable { await engine.pullLatest() }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showLog = true } label: { Image(systemName: "list.bullet.rectangle") }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
                    .environmentObject(engine)
                    .environmentObject(history)
                    .environmentObject(settings)
                    .environmentObject(log)
                    .environmentObject(keeper)
            }
            .sheet(isPresented: $showLog) {
                LogView().environmentObject(log)
            }
            .sheet(isPresented: $showGroups) {
                GroupsView()
                    .environmentObject(engine)
                    .environmentObject(settings)
            }
            .alert("الانضمام لمجموعة «\(pendingInvite?.name ?? "")»؟",
                   isPresented: Binding(get: { pendingInvite != nil }, set: { if !$0 { pendingInvite = nil } }),
                   presenting: pendingInvite) { invite in
                Button("انضمام") { engine.join(invite: invite) }
                Button("إلغاء", role: .cancel) {}
            } message: { _ in
                Text("بعد الانضمام، كل اللي بتنسخه هون بيوصل لأجهزة هالمجموعة، واللي بينسخ عليها بيوصلك.")
            }
            .onOpenURL { url in
                if let invite = GroupInvite.parse(url) { pendingInvite = invite }
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
    }

    private var statusRow: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(settings.paused ? Color.gray : (engine.connectedPeers.isEmpty ? Color.orange : Color.green))
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle).font(.headline)
                if !engine.peers.isEmpty {
                    Text(engine.peers.map(\.name).joined(separator: "، "))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            Toggle("", isOn: Binding(get: { !settings.paused }, set: { settings.paused = !$0 }))
                .labelsHidden()
        }
    }

    private var statusTitle: String {
        if settings.paused { return "المزامنة متوقفة" }
        let count = engine.connectedPeers.count
        return count == 0 ? "بانتظار أجهزة على نفس الشبكة…" : "متصل بـ \(count) \(count == 1 ? "جهاز" : "أجهزة")"
    }

    private var backgroundRow: some View {
        HStack(spacing: 10) {
            Image(systemName: keeper.isRunning ? "bolt.horizontal.circle.fill" : "moon.zzz")
                .foregroundColor(keeper.isRunning ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(keeper.isRunning ? "يعمل بالخلفية باستمرار" : "يعمل فقط والتطبيق مفتوح")
                    .font(.subheadline)
                if let error = keeper.lastError {
                    Text(error).font(.caption).foregroundColor(.red)
                } else if !keeper.isRunning {
                    Text("فعّل «العمل الدائم بالخلفية» من الإعدادات").font(.caption).foregroundColor(.secondary)
                }
            }
        }
    }

    private func run(_ action: @escaping () async -> Void) {
        busy = true
        Task {
            await action()
            busy = false
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var engine: SyncEngine
    @EnvironmentObject private var history: HistoryStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var log: ActivityLog
    @EnvironmentObject private var keeper: BackgroundKeeper
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL


    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("مثلاً: آيفون إيهاب", text: $settings.deviceName)
                } header: {
                    Text("اسم هذا الجهاز")
                }

                Section {
                    Toggle("العمل الدائم بالخلفية", isOn: $settings.keepAlive)
                        .onValueChange(of: settings.keepAlive) { _ in keeper.applySetting() }
                    Toggle("مزامنة الصور ولقطات الشاشة", isOn: $settings.syncImages)
                } footer: {
                    Text("العمل الدائم يبقي التطبيق شغالاً بالخلفية (عبر صوت صامت) فيلتقط كل نسخ ويستقبل من الماك فوراً. لا تغلق التطبيق بالسحب من شاشة التطبيقات.")
                }

                Section {
                    Button("فتح إعدادات CoShare في النظام") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                } header: {
                    Text("مهم: السماح باللصق")
                } footer: {
                    Text("الإعدادات ← CoShare ← «اللصق من التطبيقات الأخرى» ← «السماح». بدونها سيسألك iOS في كل مرة ولن تعمل المزامنة بالخلفية.")
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("• نقر مزدوج على ظهر الآيفون: الإعدادات ← تسهيلات الاستخدام ← اللمس ← النقر على الظهر ← اختر اختصار «إرسال الحافظة للأجهزة».")
                        Text("• أكواد التحقق تلقائياً: تطبيق الاختصارات ← أتمتة ← رسالة ← تحتوي «code» أو «رمز» ← تشغيل فوري ← إجراء «إرسال نص للأجهزة» مع تفعيل «الكود فقط».")
                        Text("• بعد إعادة تشغيل الآيفون افتح CoShare مرة واحدة ليعود للعمل.")
                    }
                    .font(.callout)
                } header: {
                    Text("اختصارات مفيدة")
                }

                Section {
                    Button("إعادة الاتصال") { engine.restartNetwork() }
                    Button("مسح السجل والحافظة", role: .destructive) {
                        history.clear()
                        log.clear()
                    }
                }
            }
            .navigationTitle("الإعدادات")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("تم") { dismiss() }
                }
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
    }
}

struct GroupsView: View {
    @EnvironmentObject private var engine: SyncEngine
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if !settings.groups.isEmpty {
                    Section("مجموعاتي") {
                        ForEach(settings.groups) { GroupCard(group: $0).listRowInsets(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)) }
                    }
                }
                Section {
                    if engine.nearbyGroups.isEmpty {
                        Text("ما في مجموعات تانية ظاهرة على هالشبكة لهلق.").foregroundColor(.secondary)
                    }
                    ForEach(engine.nearbyGroups) { NearbyGroupRow(nearby: $0) }
                } header: {
                    Text("مجموعات على نفس الشبكة")
                } footer: {
                    Text("انضم بكلمة سر المجموعة، أو امسح رمز الدعوة (QR) من جهاز بالمجموعة بكاميرا الآيفون.")
                }
                Section(settings.groups.isEmpty ? "إنشاء مجموعة" : "إنشاء مجموعة أخرى") {
                    CreateGroupForm()
                }
            }
            .navigationTitle("المجموعات")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("تم") { dismiss() }
                }
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
    }
}

struct LogView: View {
    @EnvironmentObject private var log: ActivityLog
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if log.entries.isEmpty {
                    Text("السجل فارغ").foregroundColor(.secondary)
                }
                ForEach(log.entries) { LogRow(entry: $0) }
            }
            .listStyle(.plain)
            .navigationTitle("سجل آخر ٢٤ ساعة")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("تم") { dismiss() }
                }
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
    }
}
