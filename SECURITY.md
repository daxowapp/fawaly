# Security

Fawaly runs AI coding tools locally and can authorize edits to a project selected by the user. Treat account setup, worker execution, downloaded runtimes, MCP configuration, and project boundaries as security-sensitive code.

## Reporting

Use GitHub’s **Security → Report a vulnerability** if private reporting is available for this repository. Otherwise, open an issue asking for a private contact channel without publishing exploit details, tokens, private files, or account identifiers. Please do not test against someone else’s accounts or projects.

Include the affected version, a minimal reproduction using disposable files, expected/actual boundaries, and impact. There is no response-time guarantee or paid bounty program.

## Current boundaries

- This is preview software; no independent security audit or production notarization is claimed.
- Native provider runtimes are downloaded separately and run with the user’s own consent and accounts.
- Credentials and runtime homes are local. Claude’s native flow may use macOS Keychain.
- Workers use macOS sandbox profiles and exact approved project paths. They may edit or partially change files inside that project. Keep version-control backups and independently review changes.
- The primary agent’s normal client permissions still apply. A saved review is the primary’s recorded claim, not a security attestation.
- No guarantee is made about malicious content inside model responses or project instructions. See source and tests before widening access.

Do not upload your Application Support folder, native CLI configuration, Keychain files, worker assignment directories, or real account logs to an issue.
