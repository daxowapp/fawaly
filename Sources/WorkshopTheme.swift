import AppKit
import SwiftUI

enum AppPage: String, CaseIterable, Identifiable {
    case home, shift, advisor, contractors, worklog, usage, settings, hires, contest, connection, rules, skills, daily

    var id: Self { self }
    static let navigation: [Self] = [.home, .connection, .rules, .advisor, .contractors, .skills, .daily, .worklog, .usage, .hires, .contest, .settings]

    func title(_ arabic: Bool) -> String {
        switch self {
        case .home: arabic ? "الرئيسية" : "Home"
        case .connection: arabic ? "ربط الوكيل الرئيسي" : "Primary connection"
        case .rules: arabic ? "قواعد التفويض" : "Delegation rules"
        case .shift: arabic ? "المهام" : "Tasks"
        case .advisor: arabic ? "المستشار" : "Advisor"
        case .contractors: arabic ? "المساعدون والاشتراكات" : "Assistants & plans"
        case .worklog: arabic ? "المهام والمراجعات" : "Tasks & reviews"
        case .usage: arabic ? "الاستخدام والحدود" : "Usage & limits"
        case .settings: arabic ? "الإعدادات" : "Settings"
        case .hires: arabic ? "موديلات المساعدين" : "Assistant models"
        case .skills: "Skills"
        case .daily: arabic ? "أخبار المبرمجين اليومية" : "Developer Daily"
        case .contest: arabic ? "مقارنة المساعدين" : "Compare assistants"
        }
    }
}

enum AppResources {
    static let bundle = Bundle.main
}

enum Workshop {
    static let yellow = Color(red: 0.96, green: 0.71, blue: 0.19)
    static let card = Color(nsColor: .controlBackgroundColor)
    // Yellow remains the brand accent; interactive text needs readable ink on light cards.
    static let actionInk = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 1, green: 0.76, blue: 0.36, alpha: 1)
            : NSColor(red: 0.48, green: 0.26, blue: 0.02, alpha: 1)
    })
    // Semantic warning ink remains readable on both light and dark cards.
    static let warning = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 1, green: 0.76, blue: 0.36, alpha: 1)
            : NSColor(red: 0.48, green: 0.26, blue: 0.02, alpha: 1)
    })
    static func heading(_ size: CGFloat, ar: Bool) -> Font {
        ar ? .custom("Lalezar-Regular", size: size, relativeTo: .title) : .system(size: size, weight: .semibold, design: .rounded)
    }
}

@MainActor
enum WorkshopAccessibility {
    static func announce(_ text: String?) {
        guard let text, !text.isEmpty else { return }
        AccessibilityNotification.Announcement(text).post()
    }
}

struct SectionHeader: View {
    let title: String
    let subtitle: String
    let ar: Bool
    let page: AppPage

    var body: some View {
        HStack(spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(Workshop.heading(34, ar: ar)).accessibilityAddTraits(.isHeader)
                Text(subtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            WorkshopIllustration(page: page, compact: page == .daily).id(page)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct WorkshopCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content.padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Workshop.card, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.09)))
    }
}

struct WorkshopPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.callout.weight(.semibold))
            .padding(.horizontal, 13).padding(.vertical, 8)
            .background(Workshop.yellow.opacity(configuration.isPressed ? 0.72 : 1), in: RoundedRectangle(cornerRadius: 8))
            .foregroundStyle(.black.opacity(0.86))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(focused ? Color.primary : .clear, lineWidth: 2).padding(-3))
            .opacity(enabled ? 1 : 0.5)
    }
}

struct WorkerAvatar: View {
    let id: String
    let size: CGFloat
    var body: some View {
        Image(systemName: id == AppModel.preview ? "hammer.fill" : "sparkle.magnifyingglass")
            .font(.system(size: size * 0.43, weight: .semibold))
            .frame(width: size, height: size)
            .background(Workshop.yellow.opacity(0.20), in: Circle())
            .accessibilityHidden(true)
    }
}

struct HazardStripe: View {
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.primary.opacity(0.8)))
            for x in stride(from: -12.0, through: size.width + 24, by: 30) {
                var stripe = Path()
                stripe.move(to: CGPoint(x: x, y: 0)); stripe.addLine(to: CGPoint(x: x + 18, y: 0))
                stripe.addLine(to: CGPoint(x: x + 6, y: size.height)); stripe.addLine(to: CGPoint(x: x - 12, y: size.height))
                stripe.closeSubpath(); context.fill(stripe, with: .color(Workshop.yellow))
            }
        }.frame(height: 6).accessibilityHidden(true)
    }
}
