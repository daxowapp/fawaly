# Developer Daily

One useful idea before the coffee gets cold.

Developer Daily is a public developer-news page inside Sudo Interns / الفواعلي. It takes the useful format of a daily briefing—dated sources followed by practical next steps—and applies it to a general programming audience. It does not publish private chats or company-specific reports.

## What it does

- Reads [OpenAI News](https://openai.com/news/rss.xml), [GitHub Changelog](https://github.blog/changelog/feed/) and [Hugging Face Blog](https://huggingface.co/blog/feed.xml) directly from their official feeds.
- Checks once every 24 hours when the page opens. Manual refresh is limited to once per minute while the page remains open.
- Separates the past 24 hours from earlier items, up to 14 days old. A quiet news day remains a quiet news day.
- Filters by source, topic or title search. Topics are simple title/source classifications, not an AI assessment.
- Keeps read marks and up to 200 saved articles locally. Saved articles remain available after leaving the 14-day feed window, until unsaved.
- Copies a source-review and small-trial request through **Brief the crew**. The user pastes it into their usual primary-agent chat. Copying does not start a job or charge a provider account.

Publisher headlines stay in their original language. Publication times are displayed in the Mac’s local timezone; the news windows use elapsed time. Titles and links belong to the credited publishers. Full articles, images and publisher scripts are not republished or loaded.

## Provenance and failure states

Each card identifies its original source and publication date and links to the original article. Practical suggestions are labelled as app suggestions; they are general checklists, not independently verified claims about that article’s tool.

Each source has a separate last-success timestamp. Failed sources retain their previously cached items with their original dates. The page names failed sources and distinguishes an empty result from a refresh failure. A successful response with no recent stories is allowed. No fabricated stories fill the gap.

During the 2026-11-08 check, the production feed/parser code returned 46 recent OpenAI items and 10 GitHub items. Hugging Face rate-limited the request; its visible failure state was checked. Availability and counts can change.

## Data and safety

No AI account, API key or project context is used to fetch news. Requests contact the publishers directly, so those publishers receive normal connection metadata. The app sends no project files, saved chats, bookmarks or account credentials to them. News and reading choices live in the app’s local application-support folder.

Network sessions use no stored cookies or credentials, follow only HTTPS redirects to the same host, have bounded timeouts and cap each feed at 2 MB. The parser rejects XML document types/entities outside inert CDATA and never resolves external entities. Article links are restricted to approved publisher hosts with no user information or unusual port. Headlines are bounded plain text with control/bidi overrides removed.

Copied task briefs quote publisher metadata as untrusted JSON, include the original link/date, and instruct the primary to verify availability, present a small trial and obtain approval before installing tools, transmitting project files or changing a project. News is data; it never becomes an automatically executed instruction.

## Brand voice

The English name is **Sudo Interns**, with **Overprompted. Underpaid.** The Arabic name remains **الفواعلي**. Both languages use workshop humor written for that language. Permissions, billing, cancellations and failure facts remain explicit. There is no connection between the name and granting `sudo` privileges.
