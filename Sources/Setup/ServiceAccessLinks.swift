import SwiftUI

struct ServiceAccessLinks: View {
    let agent: EngineAgent
    let arabic: Bool
    var region = KimiRegion.global
    var endpoint: URL? = nil
    private func text(_ ar: String, _ en: String) -> String { arabic ? ar : en }
    var body: some View {
        HStack {
            ForEach(links, id: \.url) { item in
                Link(item.label, destination: item.url)
            }
        }.font(.caption).tint(.blue)
    }
    private struct Item { let label: String; let url: URL }
    private func link(_ ar: String, _ en: String, _ url: String) -> Item { Item(label: text(ar, en), url: URL(string: url)!) }
    private var links: [Item] {
        switch agent {
        case .codex: return [link("حساب ChatGPT والاشتراك", "ChatGPT account & subscription", "https://chatgpt.com/")]
        case .claude: return [link("حساب Claude والاشتراك", "Claude account & subscription", "https://claude.ai/")]
        case .kimi: return [link("حساب Kimi والاشتراك", "Kimi account & subscription", region == .global ? "https://www.kimi.ai/" : "https://www.kimi.com/")]
        case .zai: return [link("المفاتيح وحساب GLM", "GLM account & keys", "https://z.ai/manage-apikey/apikey-list"), link("دليل الاشتراك", "Subscription guide", "https://docs.z.ai/devpack/tool/claude")]
        case .minimax: return [link("مفتاح اشتراك MiniMax", "MiniMax subscription key", "https://platform.minimax.io/console/plan"), link("دليل الربط", "Connection guide", "https://platform.minimax.io/docs/m-plan/quickstart")]
        case .deepseek: return [link("تسجيل الدخول ومفاتيح DeepSeek", "DeepSeek sign-in & keys", "https://platform.deepseek.com/api_keys")]
        case .openrouter: return [link("مفاتيح وحساب OpenRouter", "OpenRouter account & keys", "https://openrouter.ai/settings/keys"), link("الموديلات والأسعار", "Models & pricing", "https://openrouter.ai/models")]
        case .ollama: return [link("تنزيل وتجهيز Ollama", "Set up Ollama", "https://ollama.com/download")]
        case .lmstudio: return [link("تنزيل وتجهيز LM Studio", "Set up LM Studio", "https://lmstudio.ai/download")]
        case .openAIAPI, .anthropicAPI:
            if endpoint?.host == "api.openai.com" { return [link("حساب OpenAI ومفاتيح API", "OpenAI API account & keys", "https://platform.openai.com/api-keys")] }
            if endpoint?.host == "api.anthropic.com" { return [link("حساب Anthropic ومفاتيح API", "Anthropic API account & keys", "https://console.anthropic.com/settings/keys")] }
            guard let endpoint, var parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
                  parts.user == nil, parts.password == nil, ["https", "http"].contains(parts.scheme) else { return [] }
            parts.path = ""; parts.query = nil; parts.fragment = nil
            return parts.url.map { [Item(label: text("افتح موقع الخدمة المختارة", "Open the selected service website"), url: $0)] } ?? []
        }
    }
}
