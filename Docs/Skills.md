# Skills and project instructions

Fawaly asks for an installation scope each time: **all projects automatically on this Mac**, or **a specific project folder**. Scope selection happens before downloading or writing files. The specific-project option includes a native folder chooser; the review screen repeats the selected scope and destination. Existing skills, personal instructions, MCP settings and hook settings are preserved.

Project installs use `.agents/skills` and `.claude/skills`, append separate sections to project `CLAUDE.md` and `AGENTS.md`, and retain backups/receipts under `.fawaly/skills`. Global installs use the current account's `~/.agents/skills` and `~/.claude/skills`, append to `~/.codex/AGENTS.md` and `~/.claude/CLAUDE.md`, and keep backups/receipts under `~/Library/Application Support/Fawaly Rebuilt/skills-global`. They do not add `~/AGENTS.md` or `~/CLAUDE.md`, copy files into every project, or change a project's own instructions. Existing content remains byte-identical before appended sections. A global Codex `AGENTS.override.md` is preserved and its possible precedence is reported. Custom/managed host settings can limit how local skills load; global availability means the current Mac account's local clients, not remote/cloud sessions or other Macs.

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

Select Review & install, choose all projects or a specific project folder, then inspect the original instructions, source, requirements and file list. A warning acknowledgement is required for global installation, known overlaps, existing instructions when adding a template, scripts/hooks, and detected global precedence. The installer fetches only HTTPS files from the pinned GitHub revision, with bounded size and exact checksum validation. It does not run downloaded scripts. Executable helper permissions are restored only after verifying the expected file contents. Skills with hooks can execute those hooks later in an agent that supports them; the review sheet makes that distinction explicit.

Skills use the documented [Codex project/user skill locations](https://learn.chatgpt.com/docs/build-skills#where-codex-loads-local-skills) and [Claude Code project/personal skill locations](https://code.claude.com/docs/en/skills#choose-where-skills-load). Global instruction locations follow [Codex's global AGENTS.md guidance](https://learn.chatgpt.com/docs/agent-configuration/agents-md) and [Claude's user instructions](https://code.claude.com/docs/en/memory). Start a new agent chat after installing. Fawaly's restricted delegated workers receive project skill references or bounded excerpts of globally installed guidance; existing tool and sandbox restrictions stay in effect. Installing a skill grants no extra worker tools or nested delegation.

## Installed state and conflicts

- Installed means the receipt is complete, package file hashes match, and the attributed instruction sections are still present.
- User changes produce a preserved/modified state; Fawaly does not overwrite the edited files.
- Standard project and personal skill directories are inspected by skill name, including frontmatter names in renamed folders. An unmanaged project installation blocks replacement. A global match is reported and may have precedence in the host agent. Marketplace/plugin-managed skills outside these directories are not exhaustively detected.
- Existing destinations, links, hardlinks, path traversal and concurrent file edits stop writes. Prepared writes use expected content hashes rather than silently rebasing over a changed file.
- Incomplete receipts remain visible after cancellation or a write failure. Resuming accepts only byte-identical files belonging to the same pinned package. Newly changed files are preserved for review. There is no automatic removal or forced update of existing installations.
- Catalog tags identify potential overlap in planning, testing and design rules. This is a review aid, not a complete semantic conflict detector. Templates are optional guidance; existing user decisions, Fawaly routing/review rules and other installed instructions are explicitly preserved.

## Shared project memory

Planning with Files keeps plans, findings and progress on disk so supported agents can resume work. Its upstream package includes scripts and Claude-specific lifecycle hooks; other agents do not automatically gain identical hook behavior. Fawaly adds a bounded handoff: when a memory-tagged package has a complete project or global receipt, delegated work with an explicitly approved project receives relevant guidance and small root `task_plan.md`, `findings.md` and `progress.md` notes from that project only. A global skill makes the workflow available across projects; it does not merge their memories or read notes from the user's home directory. It does not read CLI conversation stores or another project's files. Named plans under `.planning/` should be identified in the primary's brief; this version does not guess an active plan among multiple task folders.

This is shared file context, not automatic recording of every chat, vector memory, or a guarantee that a model will follow all guidance. [Claude-Mem](https://github.com/thedotmack/claude-mem) and [Basic Memory](https://github.com/basicmachines-co/basic-memory) are researched runtime alternatives linked in the page; they are not falsely represented as one-click installed skills. They need their own runtime/provider/permission setup. Fawaly does not silently install them, enable analytics, select a paid memory provider, or disable a host agent's existing memory.
