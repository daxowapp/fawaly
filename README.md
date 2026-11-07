<div align="center">

# الفواعلي · Fawaly

**وكيلك يخطّط. الفواعلي تنفّذ.**<br>
**Your agent plans. Fawaly executes.**

A free, open-source macOS workshop for your AI coding team.

[العربية](#العربية) · [Get started](#get-started) · [Contribute](CONTRIBUTING.md) · [License](LICENSE)

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black)
![SwiftUI](https://img.shields.io/badge/SwiftUI-native-orange)
![AGPL v3 or later](https://img.shields.io/badge/license-AGPL--3.0--or--later-blue)

</div>

![Fawaly workshop](Docs/Screenshots/workshop-ar.png)

Keep working in your usual **Codex or Claude Code**. Fawaly connects an independent advisor and supporting workers through MCP. Your primary agent owns the plan, delegates bounded work, inspects the actual changes, runs checks, and records its decision.

**The official Fawaly app is free and will remain free.** No Fawaly subscription, paid unlocks, or artificial feature tiers. AI provider accounts, subscriptions, and usage are separate and subject to each provider’s terms. Fawaly does not make paid AI services free.

> **Preview:** this is a working reconstruction of Fawaly, not a claim of complete historical feature parity. The current source is buildable and tested locally. A production-signed, notarized public installer is not available yet. See [verification and limits](Docs/Verification.md).

## How the team works

```mermaid
flowchart LR
    You[You, in Codex or Claude Code] --> Primary[Primary agent: plan and verify]
    Primary <-->|Independent advice| Advisor[Advisor]
    Primary -->|Bounded assignment| Worker[Worker]
    Worker -->|Files and report| Primary
    Primary -->|Independent decision and evidence| Workshop[Fawaly workshop]
```

| Role | Supported native agents |
| --- | --- |
| Primary | Codex, Claude Code |
| Advisor | Codex, Claude Code, Kimi Code |
| Worker | Codex, Claude Code, Kimi Code |

An agent has one role in a saved team. A typical team is **Codex → Claude advisor + Kimi worker**. You can change roles in setup. Primary agents decide when to call tools; integrations cannot guarantee every model will always follow a policy.

## Get started

1. Build and open the app using the developer instructions below. A verified public installer will be documented here when available.
2. Follow the Arabic or English setup: choose your primary, advisor, and workers.
3. Let Fawaly prepare the official supporting tools. Sign in through each provider’s own browser flow. No Terminal commands or pasted setup tokens.
4. Connect the team. Fawaly registers MCP in your primary agent’s user settings. Reopen that client or start a new chat if it cached its tools.
5. Choose a project folder when you want workers to edit files. Continue your work in your usual primary client.

For substantial tasks, the team instructions ask the primary to consult according to your advisor policy, delegate suitable bounded work, inspect the result independently, and save a review. Native client tool approvals still apply.

## Inside the workshop

- Native SwiftUI interface, Arabic/English, mirrored layout, light/dark/system appearance, and the original illustrated workshop identity.
- Browser-based native account setup, connection checks, cancellation, sign-out, and saved team roles.
- Advisor policy, rounds and timeouts; ordered workers by task type; a 15-minute default worker timeout.
- Searchable tasks and reviews, live progress, stop controls, independent review evidence, and optional primary ratings.
- Isolated Git HEAD comparisons with two assistants. Your uncommitted files stay outside the snapshots. Selecting a winner never merges it automatically.
- Explicit supporting-agent model choices, a verified signed reference catalog, local activity counts, and settings export/import without credentials.
- Optional local notifications and morning account checks while the app is open. Settings files can be moved using iCloud Drive; this is not automatic cross-device sync.

Official subscription balances, spending caps, automatic metered fallback, additional historical provider adapters, automatic model discovery, and complete old app parity are **not implemented**. Account availability and local job counts are not quota measurements.

## Build and test

Requires macOS 14+, full Xcode, and acceptance of Xcode’s license. Tested locally with Xcode 27.2. No external Swift package dependencies.

```sh
git clone https://github.com/daxowapp/fawaly.git
cd fawaly
xcodebuild -project "Fawaly Rebuilt.xcodeproj" -scheme "Fawaly Rebuilt" \
  -destination 'platform=macOS' -derivedDataPath Build/DerivedData \
  -parallel-testing-enabled NO test
```

To run from Xcode, select **Fawaly Rebuilt → My Mac → Run**. Keep the app at a stable location before connecting MCP. To use the optional `Engine/fawaly` developer launcher, copy the built app to `Build/Fawaly Rebuilt.app`:

```sh
ditto "Build/DerivedData/Build/Products/Debug/Fawaly Rebuilt.app" "Build/Fawaly Rebuilt.app"
```

The checked-in Xcode project is ready to open. When adding source files, regenerate it with the dependency-free script:

```sh
ruby Scripts/generate-project.rb "$PWD"
```

Do not commit downloaded runtimes, local builds, account data, or your project files. Native providers are downloaded separately from their official sources and retain their own licenses. See [architecture and privacy](Docs/Architecture.md).

## Free forever, with shared improvements

Our maintainer commitment: **the official Fawaly app remains free**. The code is licensed **AGPL-3.0-or-later**. You may use, study, modify, and share it. When conveying covered modified software, provide corresponding source under the license; modified network-facing versions must offer corresponding source to their remote users as required by section 13.

Private modifications do not automatically require a public repository, and the license does not require an upstream pull request. We warmly encourage sharing improvements here for everyone. AGPL permits commercial use and charging for copies; our free-app pledge concerns the official project and does not restrict those freedoms. The full [license](LICENSE) controls.

## العربية

الفواعلي بيخلّيك تكمّل شغلك داخل Codex أو Claude Code المعتاد. الأجنت الأساسي يخطّط ويراجع، مستشار مستقل يدّي رأي تاني، والفواعلي ينفّذوا مهام محددة. مثال: Codex أساسي، Claude مستشار، وKimi عامل.

**نسخة الفواعلي الرسمية مجانية وهتفضل دائمًا مجانية**؛ من غير اشتراك للفواعلي أو قفل للمميزات خلف باقات. اشتراكات واستخدام خدمات الذكاء الاصطناعي مستقلة وبتخضع لشروط أصحابها.

التجهيز بيتم من واجهة التطبيق: اختيار الفريق، تجهيز الأدوات الرسمية، تسجيل دخول من متصفح الخدمة، وربط الفريق. المستخدم العادي مش محتاج يكتب أوامر Terminal. تختار فولدر المشروع عشان تسمح للعمال بتعديله، والأساسي لازم يراجع الشغل قبل اعتماده.

دي نسخة مستعادة ومطوّرة من التطبيق، وفيها أجزاء قديمة لسه محتاجة شغل. مفيش حاليًا مُثبّت عام موقّع وموثّق من Apple. المطور يقدر يبنيها من المصدر بالخطوات اللي فوق.

الرخصة AGPLv3 أو أحدث بتضمن حقوق الاستخدام والتعديل والمشاركة، وبترجع حق الوصول للمصدر لمستخدمي النسخ الموزعة والخدمات المعدّلة حسب شروطها. بنشجّع كل تحسين يرجع هنا للمجتمع؛ إرسال Pull Request مش شرط إجباري في الرخصة، والتعديلات الخاصة مش لازم تتحول تلقائيًا لمشروع عام.

## Help build it

Useful bug reports, accessible Arabic copy, onboarding feedback, security reviews, tests, and small focused fixes all help. Read [CONTRIBUTING.md](CONTRIBUTING.md), [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md), and [SECURITY.md](SECURITY.md). Please remove credentials and private project content from reports.

Original idea and name: **Ahmed Nagdy**. Development and reconstruction: **Daxow and contributors**. This is an independent project, not an official OpenAI, Anthropic, or Moonshot product. Provider names and trademarks belong to their owners. [Third-party notices](THIRD_PARTY_NOTICES.md).
