import SwiftUI

struct RunningWorkerControls: View {
    @EnvironmentObject private var model: AppModel
    let job: TeamJob
    @State private var requested = false

    var body: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text(job.started, style: .timer).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Spacer()
            Button(model.text(requested ? "جاري الإيقاف…" : "إيقاف العامل", requested ? "Stopping…" : "Stop worker")) {
                do { try model.stopJob(job.id); requested = true } catch { model.report(error) }
            }.disabled(requested)
        }
    }
}

struct RunningTeamPanel: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        let running = model.teamJobs.filter { $0.status == "running" }
        if !running.isEmpty {
            WorkshopCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text(model.text("شغالين دلوقتي", "Working now")).font(.headline)
                    ForEach(running) { job in
                        Text(job.worker.label + " · " + job.title).font(.callout).lineLimit(2)
                        RunningWorkerControls(job: job)
                    }
                }
            }
        }
    }
}
