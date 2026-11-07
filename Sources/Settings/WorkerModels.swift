import Foundation
import SwiftUI

struct WorkerModelPreference: Sendable { let agent: EngineAgent; let model: String? }

enum NativeModelCatalog {
    static func models(_ agent: EngineAgent, root: URL) async throws -> [String] {
        switch agent {
        case .codex: return OfficialModels.codex(root: root)
        case .claude: return ["fable", "opus", "sonnet"] // Official aliases reported by the installed Claude CLI.
        case .kimi:
            let command = try NativeSignIn(configuration: .init(root: root)).command(.kimi, login: false)
            let result = try await LoginProcess.run(command, timeout: 20)
            guard result.exitCode == 0 else { throw FawalyError.invalid("Kimi’s saved model list could not be read.") }
            return kimiModels(Data(result.output.utf8))
        default:
            return try await APIWorker(root: root).models(agent)
        }
    }
    static func kimiModels(_ data: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let models = object["models"] as? [String: Any] else { return [] }
        return models.keys.filter(OfficialModels.valid).sorted()
    }
}

struct WorkerModelsPage: View {
    @EnvironmentObject private var model: AppModel
    @State private var available: [EngineAgent: [String]] = [:]
    @State private var reading = false
    @State private var notice: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.text("اختار موديل كل مساعد في شغل الفواعلي. موديل الأساسي بتختاره من برنامجه المعتاد.", "Choose each assistant’s model for Fawaly work. Choose your primary’s model in its usual app.")).font(.callout)
            HStack {
                Button(model.text("حدّث القوائم المحلية", "Refresh local model lists")) { Task { await refresh() } }.disabled(reading)
                if reading { ProgressView().controlSize(.small) }
            }
            if let notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
            ForEach(EngineAgent.allCases, id: \.self) { agent in
                WorkshopCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(agent.label).font(.headline)
                        let saved = model.state.workerModels?[agent.rawValue] ?? ""
                        let values = Array(Set((available[agent] ?? []) + (saved.isEmpty ? [] : [saved]))).sorted()
                        Picker(model.text("الموديل", "Model"), selection: Binding(get: { model.state.workerModels?[agent.rawValue] ?? "" }, set: { value in
                            do { try model.saveWorkerModel(agent, model: value.isEmpty ? nil : value) } catch { model.report(error) }
                        })) {
                            Text(model.text("اختيار الخدمة الافتراضي", "Provider default")).tag("")
                            ForEach(values, id: \.self) { Text($0).tag($0) }
                        }.disabled(!model.nativeAgents.contains(agent) || reading)
                        if !model.nativeAgents.contains(agent) {
                            Text(model.text("اربط الحساب من صفحة المساعدين.", "Connect this account from Assistants & plans.")).font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text(agent == .claude
                                 ? model.text("أسماء CLI المختصرة؛ الخدمة تختار نسختها الحالية. التغيير للطلبات الجديدة.", "CLI aliases resolve to the provider’s current version. Applies to new requests.")
                                 : model.text("قائمة محفوظة محليًا من أداة الخدمة، وقد تكون قديمة. الموديلات الجديدة لا تُختار تلقائيًا.", "A locally saved provider list, which may be stale. New models are never selected automatically.")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .task { await refresh() }
    }
    private func refresh() async {
        guard !reading else { return }
        reading = true
        defer { reading = false }
        model.refreshEngine()
        for agent in EngineAgent.allCases where model.nativeAgents.contains(agent) {
            do { available[agent] = try await NativeModelCatalog.models(agent, root: model.dataDirectory) }
            catch is CancellationError { return }
            catch { notice = model.text("تعذر قراءة بعض القوائم؛ تقدر تفضل على اختيار الخدمة الافتراضي.", "Some saved lists could not be read. Provider default remains available.") }
        }
    }
}
