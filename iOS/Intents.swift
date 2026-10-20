// Shortcuts actions need iOS 16 (App Intents); on iOS 15 the app simply works without them.
import AppIntents

// Shortcuts actions. They run in the background without opening the app, so they can be
// bound to Back Tap, the Action button, Control Center, Siri or a personal automation
// (e.g. "when a message containing 'code' arrives → send it to my Macs").

@available(iOS 16.0, *)
struct SendClipboardIntent: AppIntent {
    static let title: LocalizedStringResource = "إرسال الحافظة للأجهزة"
    static let description = IntentDescription("يرسل النص أو الصورة الموجودة في حافظة الآيفون الآن إلى كل أجهزتك على نفس الشبكة.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let engine = SyncEngine.shared
        engine.start()
        let count = await engine.sendCurrentClipboard()
        let message = count > 0 ? "أُرسل إلى \(count) أجهزة" : "لم يصل لأي جهاز — تأكد أن الأجهزة على نفس الشبكة"
        return .result(dialog: IntentDialog(stringLiteral: message))
    }
}

@available(iOS 16.0, *)
struct SendTextIntent: AppIntent {
    static let title: LocalizedStringResource = "إرسال نص للأجهزة"
    static let description = IntentDescription("يرسل نصاً (مثل رسالة كود التحقق) إلى كل الأجهزة ويضعه في حافظتها. فعّل «الكود فقط» لاستخراج رمز التحقق من الرسالة تلقائياً.")
    static let openAppWhenRun = false

    @Parameter(title: "النص")
    var text: String

    @Parameter(title: "الكود فقط", default: false)
    var onlyCode: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("أرسل \(\.$text) للأجهزة") {
            \.$onlyCode
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let value = onlyCode ? (CodeExtractor.firstCode(in: text) ?? text) : text
        let engine = SyncEngine.shared
        engine.start()
        let count = await engine.send(.text(value), copyLocally: true)
        return .result(value: value, dialog: IntentDialog(stringLiteral: "«\(value)» أُرسل إلى \(count) أجهزة"))
    }
}

@available(iOS 16.0, *)
struct FetchLatestIntent: AppIntent {
    static let title: LocalizedStringResource = "جلب آخر نسخ من الأجهزة"
    static let description = IntentDescription("يجلب آخر شيء نُسخ على أي جهاز ويضعه في حافظة الآيفون لتلصقه مباشرة.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let engine = SyncEngine.shared
        engine.start()
        let updated = await engine.pullLatest()
        let latest = engine.history.items.first
        let text = latest?.kind == .text ? (latest?.text ?? "") : ""
        let message: String
        if !updated {
            message = "الحافظة محدّثة أصلاً"
        } else if text.isEmpty {
            message = "تم جلب صورة إلى الحافظة"
        } else {
            message = "تم الجلب: \(text.prefix(60))"
        }
        return .result(value: text, dialog: IntentDialog(stringLiteral: message))
    }
}

@available(iOS 16.0, *)
struct CoShareShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SendClipboardIntent(),
                    phrases: ["Send clipboard with \(.applicationName)"],
                    shortTitle: "إرسال الحافظة",
                    systemImageName: "arrow.up.doc.on.clipboard")
        AppShortcut(intent: FetchLatestIntent(),
                    phrases: ["Get latest clip with \(.applicationName)"],
                    shortTitle: "جلب آخر نسخ",
                    systemImageName: "arrow.down.circle")
    }
}
