import SwiftUI

struct ConsultationComposer: View {
    @EnvironmentObject private var model: AppModel
    @State private var question = ""
    @State private var context = ""
    @State private var provider = AppModel.preview
    @State private var caller = Rater.human
    @State private var reason = ConsultReason.userRequest
    @State private var confirm = false
    @State private var destination: URL?

    private var seats: [AdvisorSeat] {
        model.roster.advisors.seats.filter { $0.enabled && model.models($0.provider).contains($0.model) }
    }
    private var disabled: Bool {
        !model.loaded || model.busy || model.roster.advisors.mode == .off ||
        !seats.contains(where: { $0.provider == provider }) || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        WorkshopCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(model.text("استشارة جديدة", "New consultation")).font(.headline)
                TextField(model.text("سؤالك", "Your question"), text: $question, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(2...5)
                TextField(model.text("سياق اختياري", "Optional context"), text: $context, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(2...7)
                HStack {
                    Picker(model.text("المستشار", "Advisor"), selection: $provider) {
                        Text(model.text("اختار مستشار", "Choose an advisor")).tag("")
                        ForEach(seats, id: \.provider) { seat in
                            Text(model.name(seat.provider) + " · " + seat.model).tag(seat.provider)
                        }
                    }
                    Picker(model.text("صاحب السؤال", "Requested by"), selection: $caller) {
                        Text(model.text("أنا", "Me")).tag(Rater.human)
                        Text("Codex").tag(Rater.codex)
                        Text("Claude").tag(Rater.claude)
                    }
                    if model.roster.advisors.mode == .important {
                        Picker(model.text("السبب", "Reason"), selection: $reason) {
                            ForEach(ConsultReason.allCases, id: \.self) { value in
                                Text(AdvisorCopy.reason(value, arabic: model.arabic)).tag(value)
                            }
                        }
                    }
                }
                Button(provider == AppModel.preview ? model.text("جرّب محليًا", "Run local preview") : model.text("راجع الإرسال…", "Review and send…")) {
                    if provider == AppModel.preview { submit() } else { destination = model.state.provider?.url; confirm = true }
                }
                .buttonStyle(WorkshopPrimaryButtonStyle())
                .disabled(disabled)
            }
        }
        .onChange(of: seats.map(\.provider), initial: true) { _, available in
            if !available.contains(provider) { provider = available.first ?? "" }
        }
        .confirmationDialog(model.text("إرسال الاستشارة للخدمة؟", "Send this consultation?"), isPresented: $confirm, titleVisibility: .visible) {
            Button(model.text("إرسال", "Send")) { submit() }
        } message: {
            Text(model.text("السؤال والسياق اللي كتبته هيروحوا إلى", "Your question and context will be sent to") + " " +
                 model.providerDestination(provider, url: destination) + ".")
        }
    }

    private func submit() {
        Task {
            do {
                try await model.consult(provider: provider, by: caller,
                    reason: model.roster.advisors.mode == .important ? reason : .userRequest,
                    question: question, context: context, destination: destination)
                question = ""
                context = ""
            } catch { model.report(error) }
        }
    }
}

struct ConsultationActions: View {
    @EnvironmentObject private var model: AppModel
    let record: ConsultRecord
    @State private var followUp = ""
    @State private var summary = ""
    @State private var confirm = false
    @State private var destination: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if record.rounds.count < model.roster.advisors.maxRounds && model.roster.advisors.mode != .off {
                HStack {
                    TextField(model.text("متابعة", "Follow-up"), text: $followUp)
                    Button(model.text("جولة تانية", "Another round")) {
                        if record.provider == AppModel.preview { sendFollowUp() } else { destination = model.state.provider?.url; confirm = true }
                    }.disabled(model.busy || followUp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            TextField(model.text("ملخص القرار (اختياري)", "Decision summary (optional)"), text: $summary)
            HStack {
                ForEach(ConsultDecision.allCases, id: \.self) { decision in
                    Button(AdvisorCopy.decision(decision, arabic: model.arabic)) {
                        do { try model.decide(record.id, decision: decision, summary: summary) }
                        catch { model.report(error) }
                    }
                }
            }.disabled(model.busy)
        }
        .confirmationDialog(model.text("إرسال المتابعة؟", "Send follow-up?"), isPresented: $confirm, titleVisibility: .visible) {
            Button(model.text("إرسال", "Send")) { sendFollowUp() }
        } message: {
            Text(model.text("السؤال الجديد والجولات السابقة هيروحوا إلى", "The follow-up and prior rounds will be sent to") +
                " " + model.providerDestination(record.provider, url: destination) + ".")
        }
    }

    private func sendFollowUp() {
        Task {
            do {
                try await model.consult(provider: record.provider, by: record.caller, reason: record.reason,
                                        question: followUp, context: "", continuing: record.id, destination: destination)
                followUp = ""
            } catch { model.report(error) }
        }
    }
}
