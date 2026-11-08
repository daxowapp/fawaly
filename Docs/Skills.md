# Skills and project instructions

Fawaly's Skills page installs selected, pinned upstream skill packages into the chosen project. It does not replace personal skills, MCP settings, hook settings or an existing skill folder. Existing `CLAUDE.md` and `AGENTS.md` content is preserved byte-for-byte before a separate, attributed section is appended; the original content is also backed up locally under `.fawaly/skills/backups`.

## Curated sources

The bundled catalog records the source commit, per-file SHA-256, declared license, author and GitHub star snapshot dated 2026-11-08. Stars indicate repository popularity, not a security certification or a guarantee that a skill suits a project.

| Package | Credit | Declared license |
| --- | --- | --- |
| Planning with Files | [OthmanAdi/planning-with-files](https://github.com/OthmanAdi/planning-with-files) | MIT |
| Systematic Debugging, Test-driven Development, Verification before Completion | [obra/superpowers](https://github.com/obra/superpowers) | MIT |
| React Best Practices, Web Design Guidelines | [vercel-labs/agent-skills](https://github.com/vercel-labs/agent-skills) | MIT in skill metadata |
| Frontend Design | [anthropics/skills](https://github.com/anthropics/skills/tree/main/skills/frontend-design) | Apache-2.0 |
| Example project CLAUDE.md | [affaan-m/everything-claude-code](https://github.com/affaan-m/everything-claude-code/blob/main/examples/CLAUDE.md) | MIT |
| Minimal project CLAUDE.md | Daxow / Fawaly contributors | AGPL-3.0-or-later |

The selected Anthropic skill has its own Apache license; source-available document skills from that repository are not included. Upstream license files are retained when supplied, and every installed package gets `Fawaly-CREDITS.md` plus a local receipt containing author, source, revision and license. The installer does not change the project's own license file.

## Review and installation

Choose a project, select Review & install, then inspect the original instructions, source, requirements and file list. A warning acknowledgement is required for known overlaps, existing instructions when adding a template, scripts/hooks, and detected global precedence. The installer fetches only HTTPS files from the pinned GitHub revision, with bounded size and exact checksum validation. It does not run downloaded scripts. Executable helper permissions are restored only after verifying the expected file contents. Skills with hooks can execute those hooks later in an agent that supports them; the review sheet makes that distinction explicit.

Skills go into both `.agents/skills/<name>` and `.claude/skills/<name>`. These are the documented [Codex project skill location](https://learn.chatgpt.com/docs/build-skills#where-codex-loads-local-skills) and [Claude Code project skill location](https://code.claude.com/docs/en/skills#choose-where-skills-load). The main agent should start a new chat after installing. Fawaly's restricted delegated workers receive relevant skill references, while their existing tool and sandbox restrictions stay in effect; installing a skill does not grant a worker extra tools or enable nested delegation.

## Installed state and conflicts

- Installed means the receipt is complete, package file hashes match, and the attributed instruction sections are still present.
- User changes produce a preserved/modified state; Fawaly does not overwrite the edited files.
- Standard project and personal skill directories are inspected by skill name, including frontmatter names in renamed folders. An unmanaged project installation blocks replacement. A global match is reported and may have precedence in the host agent. Marketplace/plugin-managed skills outside these directories are not exhaustively detected.
- Existing destinations, links, hardlinks, path traversal and concurrent file edits stop writes. Prepared writes use expected content hashes rather than silently rebasing over a changed file.
- Incomplete receipts remain visible after cancellation or a write failure. Resuming accepts only byte-identical files belonging to the same pinned package. Newly changed files are preserved for review. There is no automatic removal or forced update of existing installations.
- Catalog tags identify potential overlap in planning, testing and design rules. This is a review aid, not a complete semantic conflict detector. Templates are optional guidance; existing user decisions, Fawaly routing/review rules and other installed instructions are explicitly preserved.

## Shared project memory

Planning with Files keeps plans, findings and progress on disk so supported agents can resume work. Its upstream package includes scripts and Claude-specific lifecycle hooks; other agents do not automatically gain identical hook behavior. Fawaly adds a bounded handoff: when an installed memory-tagged package has a complete project receipt, delegated work with an explicitly approved project receives relevant installed-skill paths and small root `task_plan.md`, `findings.md` and `progress.md` notes. It does not read CLI conversation stores, global memory or another project's files. Named plans under `.planning/` should be identified in the primary's brief; this version does not guess an active plan among multiple task folders.

This is shared file context, not automatic recording of every chat, vector memory, or a guarantee that a model will follow all guidance. [Claude-Mem](https://github.com/thedotmack/claude-mem) and [Basic Memory](https://github.com/basicmachines-co/basic-memory) are researched runtime alternatives linked in the page; they are not falsely represented as one-click installed skills. They need their own runtime/provider/permission setup. Fawaly does not silently install them, enable analytics, select a paid memory provider, or disable a host agent's existing memory.
