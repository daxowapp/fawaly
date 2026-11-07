import SwiftUI

struct EngineServicesCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        EngineConnections(setup: model.setup)
    }
}

private struct EngineConnections: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var setup: SetupCoordinator

    var body: some View {
        WorkshopCard {
            VStack(alignment: .leading, spacing: 15) {
                Text(model.text("حساباتك", "Your accounts")).font(.headline)
                ConnectionList(setup: setup, agents: EngineAgent.allCases)
                HStack {
                    Button(model.text("افتح الإعداد", "Open setup")) { model.restartOnboarding() }.disabled(setup.busy)
                    Button(model.text("تحقق من الربط", "Check connections")) { setup.verifyConnections() }.disabled(setup.busy)
                    if setup.busy {
                        Button(model.text("إلغاء", "Cancel")) { setup.cancel() }
                    }
                }.disabled(model.busy)
                Text(model.text("تسجيل الدخول بيتم في صفحة الخدمة الرسمية، وبعدها الفواعلي بيتحقق من الربط.", "Sign-in uses the service’s official page. Fawaly then checks the connection."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .task { setup.scan(); setup.verifyConnections() }
    }
}
