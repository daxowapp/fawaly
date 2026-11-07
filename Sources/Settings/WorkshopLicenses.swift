import SwiftUI

struct WorkshopLicenses: View {
    let arabic: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var selected = "AGPL-3.0"
    private let files = ["AGPL-3.0", "OFL", "Sparkle-LICENSE"]
    private var license: String {
        guard let url = Bundle.main.url(forResource: selected, withExtension: "txt"), let text = try? String(contentsOf: url, encoding: .utf8) else { return "License text unavailable." }
        return text
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(arabic ? "تراخيص البرامج" : "Software licenses").font(.headline)
                Spacer()
                Button(arabic ? "تم" : "Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Picker(arabic ? "المكوّن" : "Component", selection: $selected) {
                ForEach(files, id: \.self) { Text($0).tag($0) }
            }.pickerStyle(.segmented)
            ScrollView { Text(license).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .environment(\.layoutDirection, .leftToRight)
        }.padding(24).frame(width: 660, height: 500)
    }
}
