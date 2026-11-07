# Contributing to Fawaly

Welcome — أهلاً بيك. Help make the workshop easier for ordinary users.

## Good first contributions

- Reproduce an onboarding problem and describe the last successful step.
- Improve Arabic or English clarity, keyboard navigation, VoiceOver, and reduced-motion behavior.
- Add a focused regression for a real bug, or implement one documented missing capability.
- Review native integration boundaries without including credentials in issues or logs.

Search existing issues before opening a new one. For a large change, open an issue to agree on its scope. Small fixes can go directly to a pull request.

## Development

Use the build/test commands in README. Change only this repository; recovered reference copies are provenance material. Regenerate the project with `ruby Scripts/generate-project.rb "$PWD"` when adding Swift files or bundled resources. Keep the generated project in your PR.

Run the relevant tests and `git diff --check`. Changes to account setup, execution, cancellation, project access, or data formats need meaningful regression coverage. Live provider checks must be explicitly authorized by the account owner; do not rely on paid accounts in CI. State what you tested and what you could not test.

Keep user-facing setup inside the app. Do not require end users to paste secrets, type shell commands, or trust a model’s unverified report. Preserve existing client settings, isolate provider authentication, and never silently widen project grants or choose a paid fallback.

## Pull requests

Explain the user-visible problem, the resulting behavior, and verification. Keep changes focused. Include screenshots for visual changes in Arabic and English where applicable. Scrub private paths, account identifiers, prompts, and credentials from screenshots and logs.

Contributions are submitted under this repository’s AGPL-3.0-or-later license; separate third-party notices remain in effect. No CLA or transfer of copyright is required. Please send improvements upstream when you can — sharing is how the workshop gets better.
