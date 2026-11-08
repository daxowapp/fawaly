import SwiftUI
import Darwin

struct APIServicesView: View {
    @EnvironmentObject private var model: AppModel
    let configured: Set<EngineAgent>
    let configure: (EngineAgent) -> Void
    var body: some View {
        WorkshopCard {
            VStack(alignment: .leading, spacing: 14) {
                Text(model.text("أضف مساعدًا", "Add an assistant")).font(.headline)
                Text(model.text("اربط مفتاح خدمتك أو موديل شغّال على الماك، وبعدها عيّنه مستشار أو فواعلي. المفتاح في Keychain، ومفيش تحويل مدفوع تلقائي لو خدمة وقفت.", "Connect your service key or a model running on this Mac, then assign it as advisor or worker. Keys stay in Keychain. A failure never triggers automatic paid fallback.")).font(.caption).foregroundStyle(.secondary)
                ForEach(EngineAgent.allCases.filter { !$0.isNative && !configured.contains($0) }, id: \.self) { agent in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(agent.label).font(.callout.weight(.semibold))
                            ServiceAccessLinks(agent: agent, arabic: model.arabic, endpoint: APIAssistant.preset(agent).endpoint)
                        }
                        Spacer()
                        Button(model.text("إضافة…", "Add…")) { configure(agent) }.disabled(model.busy || model.setup.busy).accessibilityLabel(model.text("إضافة \(agent.label)", "Add \(agent.label)"))
                    }
                }
            }
        }
    }
}

struct APIServiceEditor: View {
    let agent: EngineAgent
    let root: URL
    let arabic: Bool
    let changed: (Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var endpoint = ""
    @State private var model = ""
    @State private var key = ""
    @State private var format = APIAssistant.Format.openAI
    @State private var limitText = "100"
    @State private var roundsText = "12"
    @State private var enabled = true
    @State private var hasSavedKey = false
    @State private var working = false
    @State private var issue: String?
    @State private var operation: Task<Void, Never>?
    @State private var saved: APIAssistant?
    @State private var availableModels: [String] = []
    @State private var modelSearch = ""
    @State private var authorizedKey = false
    @State private var signInFeedback: String?
    private var displayedModels: [String] {
        let matches = availableModels.filter { modelSearch.isEmpty || $0.localizedCaseInsensitiveContains(modelSearch) }
        return Array(Set(matches + (model.isEmpty ? [] : [model]))).sorted()
    }
    private var localSettingsOnly: Bool {
        guard let saved else { return false }
        return key.isEmpty && URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) == saved.endpoint && model.trimmingCharacters(in: .whitespacesAndNewlines) == saved.model && format == saved.format
    }
    private func text(_ ar: String, _ en: String) -> String { WorkshopCopy.text(ar, en, arabic: arabic) }
    private var keyPlaceholder: String {
        if hasSavedKey { return text("مفتاح جديد اختياري؛ المحفوظ يفضل في Keychain", "Optional replacement key; saved key stays in Keychain") }
        if agent == .minimax { return text("مفتاح اشتراك MiniMax أو خدمة API", "MiniMax subscription or API key") }
        if [.zai, .deepseek, .openrouter].contains(agent) { return text("مفتاح خدمة API", "API key") }
        return text("مفتاح الخدمة؛ اختياري للسيرفر المحلي", "Service key; optional for a local server")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
          ScrollView {
           VStack(alignment: .leading, spacing: 14) {
            Text(agent.label).font(.title2.weight(.semibold))
            if agent == .zai {
                Text(text("GLM Coding Plan له مفتاح من Personal Coding Plan ← Plan Overview، واستخدامه الرسمي محصور في أدوات مدعومة مثل Claude Code وZCode. الربط المباشر هنا لخدمة API برصيد مستقل؛ الفواعلي مش ضمن قائمة أدوات الاشتراك المدعومة حاليًا.", "GLM Coding Plan keys are under Personal Coding Plan → Plan Overview and are limited to supported tools such as Claude Code and ZCode. This direct connection is for a separately billed API account; Fawaly is not currently listed as a supported subscription tool.")).font(.caption).foregroundStyle(.secondary)
            } else if agent == .minimax {
                Text(text("لاستخدام اشتراك MiniMax، هات مفتاح M Plan / Coding Plan من صفحة الخطة. مفتاح الاشتراك منفصل عن مفتاح API العادي؛ الفواعلي ما بيحوّلش بينهم تلقائيًا.", "For your MiniMax subscription, use the M Plan / Coding Plan key from your plan page. It is separate from a pay-as-you-go API key; Fawaly never switches between them automatically.")).font(.caption).foregroundStyle(.secondary)
            }
            ServiceAccessLinks(agent: agent, arabic: arabic, endpoint: URL(string: endpoint))
            if agent == .openrouter {
                Button(text("تسجيل الدخول إلى OpenRouter…", "Sign in to OpenRouter…")) { signInToOpenRouter() }.buttonStyle(WorkshopPrimaryButtonStyle())
                Text(text("اربط من المتصفح أو أدخل مفتاحك. الطلبات تُحسب من رصيد OpenRouter، وليس اشتراكات المواقع الأخرى. القائمة تعرض موديلات نصية تدعم أدوات الفواعلي، ومفيش اختيار تلقائي لموديل بديل.", "Connect in your browser or enter a key. Requests use your OpenRouter credits, not other website subscriptions. The list shows text models supporting Fawaly's tools. No alternative model is selected automatically.")).font(.caption).foregroundStyle(.secondary)
                if let signInFeedback { Text(signInFeedback).font(.caption) }
            }
            TextField(text("رابط الطلب الكامل", "Full request endpoint"), text: $endpoint).textFieldStyle(.roundedBorder).environment(\.layoutDirection, .leftToRight)
            if [.openAIAPI, .anthropicAPI].contains(agent) {
                Picker(text("صيغة الخدمة", "API format"), selection: $format) {
                    Text("OpenAI-compatible").tag(APIAssistant.Format.openAI)
                    Text("Anthropic-compatible").tag(APIAssistant.Format.anthropic)
                }
            }
            TextField(text("معرّف الموديل", "Model ID"), text: $model).textFieldStyle(.roundedBorder).environment(\.layoutDirection, .leftToRight)
            if !availableModels.isEmpty {
                TextField(text("ابحث باسم الموديل أو الشركة", "Search model or provider"), text: $modelSearch).textFieldStyle(.roundedBorder)
                Picker(text("الموديلات المتاحة", "Available models"), selection: $model) {
                    Text(text("اختار موديل…", "Choose a model…")).tag("")
                    ForEach(displayedModels, id: \.self) { Text($0).tag($0) }
                }
                Text(text("\(displayedModels.count) موديل في القائمة", "\(displayedModels.count) models listed")).font(.caption).foregroundStyle(.secondary)
            }
            SecureField(keyPlaceholder, text: $key).textFieldStyle(.roundedBorder)
            if format == .openAI {
                Button(text("اقرأ الموديلات المتاحة", "Load available models")) { loadModels() }
                Text(text("قراءة القائمة مش مهمة للموديل. للمساعد المحلي افتح Ollama أو LM Studio وحمّل موديل الأول.", "Listing models is not a generation task. For local assistants, open Ollama or LM Studio and load a model first.")).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text(text("حد طلبات الموديل في اليوم (UTC)", "Daily model request cap (UTC)")); Spacer()
                TextField("100", text: $limitText).textFieldStyle(.roundedBorder).frame(width: 90).accessibilityLabel(text("حد الطلبات اليومي", "Daily request cap"))
            }
            HStack {
                Text(text("أقصى جولات للمهمة", "Maximum rounds per task")); Spacer()
                TextField("12", text: $roundsText).textFieldStyle(.roundedBorder).frame(width: 90).accessibilityLabel(text("أقصى جولات للمهمة", "Maximum task rounds"))
            }
            Toggle(text("فعّل المساعد", "Enable assistant"), isOn: $enabled)
            Text(text("الحفظ والاختبار هيبعتوا طلبًا نصيًا قصيرًا للرابط ده ويُحسبوا من حسابك. عند تعيين المساعد لشغل مشروع، السياق والملفات المصرّح بها تتبعت للخدمة. حد الطلبات محلي، مش حد مصاريف بالدولار. السيرفر المحلي ممكن يستخدم موديلات سحابية حسب إعداداته.", "Save & test sends a short text request to this endpoint using your account. Assigned project work sends authorized context and files to the service. The request cap is local, not a dollar spending limit. A local server may use cloud models depending on its configuration.")).font(.caption).foregroundStyle(.secondary)
            if let issue { Text(issue).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
           }
          }
            HStack {
                Button(text("إلغاء", "Cancel")) { operation?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                if hasSavedKey || (try? APIAssistantStore(root: root).load(agent)) != nil {
                    Button(text("إزالة الربط والمفتاح", "Remove connection & key"), role: .destructive) { remove() }.disabled(working)
                }
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button(text("حفظ واختبار", "Save & test")) { saveAndTest() }.disabled(working || model.isEmpty)
                if authorizedKey { Button(text("احفظ الربط", "Save connection")) { saveAuthorizedConnection() }.buttonStyle(WorkshopPrimaryButtonStyle()).disabled(working || model.isEmpty) }
                if localSettingsOnly { Button(text("احفظ الإعدادات", "Save settings")) { saveLocalSettings() }.buttonStyle(WorkshopPrimaryButtonStyle()).disabled(working) }
            }
        }.padding(24).frame(width: 650, height: min(720, max(400, (NSScreen.main?.visibleFrame.height ?? 820) - 100))).disabled(working)
        .overlay(alignment: .bottomLeading) {
            if working { Button(text("إلغاء العملية", "Cancel operation")) { operation?.cancel() }.padding(24) }
        }
        .onAppear {
            do {
                saved = try APIAssistantStore(root: root).load(agent)
                let profile = saved ?? .preset(agent)
                endpoint = profile.endpoint.absoluteString; model = profile.model; format = profile.format
                limitText = String(profile.dailyRequestLimit); roundsText = String(profile.maxRounds); enabled = profile.enabled
                hasSavedKey = APIAssistantKeychain.contains(profile)
                if agent == .openrouter { loadModels() }
            } catch { issue = error.localizedDescription }
        }
        .onDisappear { operation?.cancel() }
        .onChange(of: endpoint) { _, _ in availableModels = [] }
        .environment(\.layoutDirection, arabic ? .rightToLeft : .leftToRight)
    }
    private func profile(modelOverride: String? = nil) throws -> APIAssistant {
        guard let limit = integer(limitText), (1...10000).contains(limit), let rounds = integer(roundsText), (1...32).contains(rounds) else {
            throw FawalyError.invalid(text("حد الطلبات اليومي من ١ إلى ١٠٠٠٠، والجولات من ١ إلى ٣٢.", "Choose a daily cap from 1 to 10000 and a round limit from 1 to 32."))
        }
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw FawalyError.invalid("Enter a service URL.") }
        let profile = APIAssistant(agent: agent, endpoint: url, model: modelOverride ?? model.trimmingCharacters(in: .whitespacesAndNewlines), format: format, enabled: enabled, dailyRequestLimit: limit, maxRounds: rounds)
        try profile.validate(); return profile
    }
    private func integer(_ input: String) -> Int? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 5 else { return nil }
        var digits = ""
        for character in trimmed {
            guard let value = character.wholeNumberValue, (0...9).contains(value) else { return nil }
            digits += String(value)
        }
        return Int(digits)
    }
    private func signInToOpenRouter() {
        working = true; issue = nil; signInFeedback = nil
        operation = Task {
            defer { working = false; operation = nil }
            do {
                key = try await OpenRouterSignIn().signIn()
                authorizedKey = true
                signInFeedback = text("تم التفويض. اختار الموديل واضغط احفظ الربط؛ الحفظ وحده لا يرسل مهمة مدفوعة. تقدر تدير المفتاح من رابط حساب OpenRouter.", "Authorized. Choose a model and Save connection; saving alone sends no paid model task. Manage the key using the OpenRouter account link.")
                NSApp.activate(ignoringOtherApps: true)
            } catch is CancellationError { issue = text("اتلغى تسجيل الدخول. الربط المحفوظ ما اتغيّرش.", "Sign-in cancelled. Saved connections were not changed.") }
            catch { issue = error.localizedDescription }
        }
    }
    private func saveAuthorizedConnection() {
        guard authorizedKey, agent == .openrouter else { return }
        do {
            let value = try profile()
            let lease = try WorkActivityLease(root: root)
            defer { withExtendedLifetime(lease) {} }
            try APIAssistantKeychain.save(key, for: value)
            try APIAssistantStore(root: root).save(value)
            key = ""; changed(true); dismiss()
        } catch { issue = error.localizedDescription }
    }
    private func saveAndTest() {
        working = true; issue = nil
        operation = Task {
            defer { working = false; operation = nil }
            do {
                let profile = try profile()
                let lease = try WorkActivityLease(root: root)
                defer { withExtendedLifetime(lease) {} }
                let supplied = key
                let credential = supplied.isEmpty ? try APIAssistantKeychain.read(profile, allowInteraction: true) : supplied
                guard !credential.contains(where: \.isNewline), credential.utf8.count <= 16384 else { throw FawalyError.invalid("Enter a valid service key.") }
                var worker = APIWorker(root: root)
                worker.credential = { _ in credential }
                _ = try await worker.run(profile, prompt: "Reply briefly: Fawaly connection ready.", workspace: nil, timeout: 45)
                try Task.checkCancellation()
                if !supplied.isEmpty { try APIAssistantKeychain.save(supplied, for: profile) }
                let old = try APIAssistantStore(root: root).load(agent)
                try APIAssistantStore(root: root).save(profile)
                if let old, old.keyAccount != profile.keyAccount { try APIAssistantKeychain.remove(old) }
                key = ""; changed(true); dismiss()
            } catch is CancellationError { issue = text("اتوقف الاختبار. الإعدادات الجديدة ما اتحفظتش.", "Test stopped. New settings were not saved.") }
            catch { issue = error.localizedDescription }
        }
    }
    private func remove() {
        do {
            let lease = try WorkActivityLease(root: root)
            defer { withExtendedLifetime(lease) {} }
            if let old = try APIAssistantStore(root: root).load(agent) { try APIAssistantKeychain.remove(old) }
            try APIAssistantStore(root: root).remove(agent)
            key = ""; changed(false); dismiss()
        } catch { issue = error.localizedDescription }
    }
    private func saveLocalSettings() {
        guard localSettingsOnly else { return }
        do {
            let lease = try WorkActivityLease(root: root)
            defer { withExtendedLifetime(lease) {} }
            try APIAssistantStore(root: root).save(profile())
            changed(true); dismiss()
        } catch { issue = error.localizedDescription }
    }
    private func loadModels() {
        working = true; issue = nil
        operation = Task {
            defer { working = false; operation = nil }
            do {
                let assistant = try profile(modelOverride: "model-list")
                let supplied = key
                var worker = APIWorker(root: root)
                worker.credential = { value in supplied.isEmpty ? try APIAssistantKeychain.read(value, allowInteraction: true) : supplied }
                availableModels = try await worker.models(assistant)
                if availableModels.isEmpty { issue = text("الخدمة لم تعرض موديلات. تقدر تكتب معرّف الموديل يدويًا.", "No models were listed. You can enter a model ID manually.") }
            } catch is CancellationError { issue = text("اتوقف الطلب.", "Request stopped.") }
            catch { issue = error.localizedDescription }
        }
    }
}
