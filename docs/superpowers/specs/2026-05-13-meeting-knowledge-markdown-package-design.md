# Minimal Markdown Meeting Knowledge Package Design

Date: 2026-05-13
Status: Proposed
Owner: MeetingAgent

## Summary

MeetingAgent should turn each completed meeting into a minimal Markdown knowledge package that can be read by humans, opened in Obsidian, and ingested by LLM-driven systems such as Karpathy-style wikis or GBrain-like agent memory.

The package intentionally avoids a parallel JSON knowledge-delta file. Markdown is the product API. The Markdown must therefore be regular enough for AI agents to parse, diff, cite, and merge, while still being pleasant for a manager to review.

The first version exports three files per meeting:

```text
meetings/<meeting-slug>/
  meeting.md
  transcript.md
  knowledge.md
```

The package answers three different questions:

- `meeting.md`: What happened in this meeting?
- `transcript.md`: What is the source evidence?
- `knowledge.md`: What should this meeting update in the long-term knowledge base?

## Product Principle

The core product idea is not "generate a better meeting summary." It is:

> Turn every meeting into reviewed, cited, structured knowledge updates for a personal AI brain.

This design treats a meeting as a source event that may change the user's long-term understanding of projects, people, customers, topics, risks, decisions, commitments, and open questions.

The output must preserve four properties:

- Human-readable: A manager can quickly review the files.
- AI-readable: LLM agents can parse stable headings and fields without a custom SDK.
- Obsidian-friendly: The files use Markdown, YAML frontmatter, and wiki links.
- Evidence-backed: Every durable knowledge item links back to transcript evidence.

## Non-Goals

- Do not build a full personal knowledge base inside MeetingAgent in this milestone.
- Do not force a proprietary database or JSON API as the primary exchange format.
- Do not auto-merge every extracted item into a user's long-term wiki without review.
- Do not make final claims about culture, intent, or relationship dynamics without marking them as inference.
- Do not remove existing summary, transcript, subtitle, or readiness exports.

## Package Layout

The export directory is named from the meeting date and title:

```text
YYYY-MM-DD-<slugified-title>/
```

If the title is missing or generic, the slug falls back to the meeting UUID:

```text
2026-05-13-5F4C0F32/
```

The three files are:

```text
meeting.md
transcript.md
knowledge.md
```

Optional future files, such as audio references or exported subtitles, can be linked from `meeting.md`, but they are not required for the first implementation.

## File 1: meeting.md

`meeting.md` is the package entry point. It combines the old idea of a manifest and a brief into one file.

### Purpose

- Give a fast human-readable overview.
- Provide package metadata through YAML frontmatter.
- Link to the transcript and knowledge update files.
- Make the package navigable in Obsidian.

### Frontmatter

```markdown
---
type: meeting
meeting_id: 5F4C0F32-0D2F-42F9-AF4B-9D4E8DFBF9F2
title: Japan GTM Sync
date: 2026-05-13
started_at: 2026-05-13T10:00:00+08:00
ended_at: 2026-05-13T10:45:00+08:00
language: en-US
transcription_provider: whisper
participants:
  - Alice
  - Ken Tanaka
related:
  - "[[Japan GTM]]"
  - "[[Acme Japan]]"
---
```

Rules:

- `type` is always `meeting`.
- `meeting_id` is the existing `MeetingRecord.id`.
- `title` is the best available meeting name, using the generated title when available.
- `date`, `started_at`, and `ended_at` use ISO-style dates.
- `participants` comes from configured attendees plus detected speaker labels when available.
- `related` is optional and can be inferred from key topics, goals, or generated knowledge items.

### Body Template

```markdown
# Japan GTM Sync

## One-Line Summary
The team agreed to scope Q3 Japan launch to a Tokyo-only pilot.

## Key Outcomes
- Q3 Japan launch will start with a Tokyo-only pilot.
- Ken will confirm the local legal review timeline by Friday.
- Enterprise pricing for Japan remains unresolved.

## Meeting Context
- Goal: Align on Japan launch scope and local readiness.
- Started: 2026-05-13 10:00
- Ended: 2026-05-13 10:45
- Language: en-US
- Transcription provider: whisper

## Files
- [[transcript]]
- [[knowledge]]
```

Generation rules:

- `One-Line Summary` comes from the meeting summary overview, compressed to one sentence when possible.
- `Key Outcomes` combines the most important decisions, action items, and unresolved questions.
- `Meeting Context` comes from `MeetingRecord`, meeting goals, attendees, and transcription metadata.
- File links use Obsidian-style wiki links and assume all three files are in the same folder.

## File 2: transcript.md

`transcript.md` is the evidence layer. It should be faithful, stable, and minimally interpreted.

### Purpose

- Preserve the source transcript in a form humans and AI agents can inspect.
- Provide anchor targets for evidence citations in `knowledge.md`.
- Make every knowledge item traceable to source text.

### Frontmatter

```markdown
---
type: transcript
meeting_id: 5F4C0F32-0D2F-42F9-AF4B-9D4E8DFBF9F2
source: transcript.json
---
```

### Body Template

```markdown
# Transcript

<a id="t-00-00-12"></a>
## 00:00:12 Alice
Let's align on the Japan launch scope today.

<a id="t-00-00-18"></a>
## 00:00:18 Ken
I think Tokyo is safer for Q3 because the support workflow is not ready nationally.
```

Generation rules:

- Prefer structured transcript segments from `transcript.json`.
- Fall back to the rendered text transcript when structured segments are unavailable.
- Each structured segment gets a stable anchor.
- Anchor format is `t-HH-MM-SS`.
- If a segment has no timestamp, use `segment-<segment-id>` as the anchor.
- Speaker labels use `speakerLabel`, then `speakerID`, then `Unknown Speaker`.
- The transcript text should not be summarized or rewritten.

## File 3: knowledge.md

`knowledge.md` is the core product output. It contains candidate long-term knowledge updates extracted from the meeting.

### Purpose

- Give the user a reviewable knowledge inbox for one meeting.
- Provide AI-readable structured Markdown for downstream wiki or memory systems.
- Separate durable knowledge updates from a simple meeting recap.
- Preserve confidence, status, related entities, and evidence for every item.

### Frontmatter

```markdown
---
type: meeting_knowledge
meeting_id: 5F4C0F32-0D2F-42F9-AF4B-9D4E8DFBF9F2
status: proposed
generated_at: 2026-05-13T11:00:00+08:00
---
```

Rules:

- `status` is `proposed` until the user accepts or edits the item.
- The first implementation can export proposed knowledge only.
- A future review workflow can update item-level status to `accepted`, `edited`, or `rejected`.

### Body Template

```markdown
# Knowledge Deltas

## How To Use This File
Review each item before merging it into a long-term wiki or AI memory. Items marked as inference should not be treated as confirmed fact.

## Facts

### fact_001
**Statement:** The current support team has two Japanese-speaking members.  
**Related:** [[Japan GTM]], [[Support]], [[Japan]]  
**Confidence:** High  
**Status:** Proposed  
**Evidence:** [[transcript#t-00-12-08|Ken 00:12:08]]

## Judgments

### judgment_001
**Statement:** A nationwide Q3 Japan launch is likely to create support risk.  
**Related:** [[Japan GTM]], [[Support Risk]]  
**Confidence:** Medium  
**Status:** Proposed  
**Evidence:** [[transcript#t-00-20-31|Alice 00:20:31]], [[transcript#t-00-21-04|Ken 00:21:04]]  
**Note:** This is an inferred judgment, not a confirmed fact.

## Decisions

### decision_001
**Statement:** Q3 Japan launch will start with a Tokyo-only pilot.  
**Related:** [[Japan GTM]], [[Tokyo]]  
**Confidence:** High  
**Status:** Proposed  
**Evidence:** [[transcript#t-00-42-18|Alice 00:42:18]]

## Actions

### action_001
**Statement:** Ken will confirm the local legal review timeline by Friday.  
**Owner:** [[Ken Tanaka]]  
**Due:** 2026-05-15  
**Related:** [[Legal Review]], [[Japan GTM]]  
**Confidence:** High  
**Status:** Open  
**Evidence:** [[transcript#t-00-48-11|Ken 00:48:11]]

## Open Questions

### question_001
**Question:** Does enterprise pricing need local adjustment for Japan?  
**Related:** [[Pricing]], [[Japan GTM]]  
**Status:** Open  
**Evidence:** [[transcript#t-00-52-40|Alice 00:52:40]]

## Entity Updates

### entity_update_001
**Entity:** [[Ken Tanaka]]  
**Type:** people_insight  
**Statement:** Ken is the best current source for local legal and support constraints.  
**Confidence:** Medium  
**Status:** Proposed  
**Evidence:** [[transcript#t-00-12-08|Ken 00:12:08]], [[transcript#t-00-48-11|Ken 00:48:11]]  
**Note:** This is an inference from meeting behavior and should be reviewed before reuse.
```

### Required Sections

The file always uses these top-level sections in this order:

1. `Facts`
2. `Judgments`
3. `Decisions`
4. `Actions`
5. `Open Questions`
6. `Entity Updates`

If a section has no items, render:

```markdown
No proposed items.
```

Stable sections matter because Markdown is the API. Downstream agents should be able to parse by headings without guessing.

### Item Field Rules

Every item has:

- A stable heading ID, such as `fact_001`, `decision_001`, or `entity_update_001`.
- `Statement` or `Question`.
- `Related`, when entities or topics are known.
- `Confidence`, using `High`, `Medium`, or `Low`.
- `Status`.
- `Evidence`.

Additional fields are type-specific:

- Actions include `Owner` and `Due` when known.
- Entity updates include `Entity` and `Type`.
- Inferred items include a `Note` that clearly marks inference.

## Knowledge Types

### Facts

Facts are claims that the meeting appears to establish as true or externally verifiable.

Examples:

- A team has a specific resource constraint.
- A customer requires a specific contract process.
- A launch date or project state was stated as current.

Facts should not include opinions, guesses, or recommendations.

### Judgments

Judgments are assessments, concerns, beliefs, tradeoffs, or interpretations.

Examples:

- A launch is risky.
- A customer is unlikely to accept a workflow.
- A proposal is better because it reduces support load.

Judgments must not be written as facts. If the model infers the judgment from tone or discussion, it must include an inference note.

### Decisions

Decisions are commitments or choices that the meeting appears to settle.

Examples:

- The team will choose option B.
- The launch scope is limited to Tokyo.
- A follow-up meeting will happen before pricing is sent.

Decisions should be extracted only when the transcript shows clear agreement or explicit closure.

### Actions

Actions are commitments to do work after the meeting.

Examples:

- A named owner will send a document.
- A team will confirm a timeline.
- A participant will schedule a follow-up.

Actions should preserve owner and due date when present. Missing owner or due date is allowed but should remain blank rather than invented.

### Open Questions

Open questions are unresolved questions that matter after the meeting.

Examples:

- Whether local pricing needs adjustment.
- Whether legal can approve before a target date.
- Which team owns support escalation.

They are useful for future agendas and should not be collapsed into risks or follow-ups.

### Entity Updates

Entity updates are proposed changes to long-term pages about people, projects, customers, teams, markets, products, or topics.

Examples:

- A project state changed.
- A customer preference became clearer.
- A person appears to be the best source for a specific domain.
- A market has a local communication or support constraint.

Entity updates are where the globalized meeting-agent product can differentiate. Cultural or relationship insights must be marked as inference unless explicitly stated.

## Extraction Source Strategy

The first implementation should reuse existing summary infrastructure where possible, but it should not be limited to the old meeting summary schema.

Current available fields:

- `MeetingSummary.overview`
- `MeetingSummary.keyTopics`
- `MeetingSummary.decisions`
- `MeetingSummary.actionItems`
- `MeetingSummary.openQuestions`
- `MeetingSummary.risks`
- `MeetingSummary.followUps`
- `MeetingSummary.sourceSegmentIDs`
- structured transcript segments

Recommended extraction path:

1. Generate or load a `MeetingSummary`.
2. Render `meeting.md` from `MeetingRecord` plus `MeetingSummary`.
3. Render `transcript.md` from structured transcript segments.
4. Generate `knowledge.md` from a new knowledge extraction prompt that has access to:
   - meeting metadata,
   - meeting goal,
   - attendees,
   - summary,
   - structured transcript segments with IDs, speaker labels, timestamps, and text.

The new knowledge extraction prompt should return structured content internally so the app can render stable Markdown. The external artifact remains Markdown-only.

## LLM Prompt Contract

The knowledge extraction provider should instruct the model to:

- Extract only durable knowledge updates, not every discussion detail.
- Preserve the distinction between fact, judgment, decision, action, open question, and entity update.
- Include evidence segment IDs for every item.
- Never invent owners, due dates, participants, or source evidence.
- Mark inferred judgments, relationship insights, and cultural notes as inference.
- Prefer fewer high-quality items over exhaustive noisy extraction.
- Write output in the configured summary target language.

Although the public export is Markdown, using an internal structured response is acceptable. It keeps rendering deterministic and tests simple while preserving Markdown as the product boundary.

## Evidence Linking

`knowledge.md` evidence links point to anchors in `transcript.md`:

```markdown
[[transcript#t-00-42-18|Alice 00:42:18]]
```

Rules:

- If the source segment has a timestamp, use its timestamp anchor.
- If the source segment has no timestamp, use its segment ID anchor.
- If multiple segments support an item, list multiple evidence links.
- If no evidence is available, the item should not be emitted except in a failure note.

This keeps downstream wiki agents from treating unsupported model output as durable memory.

## User Review Model

The first development milestone can export all items as `Proposed`.

The intended review workflow is:

- User opens `knowledge.md`.
- User accepts, edits, or deletes proposed items.
- Downstream systems ingest the reviewed Markdown.

A later app UI can provide explicit controls:

- Accept item
- Edit item
- Reject item
- Mark as uncertain
- Link to existing page/entity

The Markdown format is already compatible with this future UI because each item has a stable ID and status field.

## App Integration

The implementation should add a new export path rather than replacing existing exports.

Suggested core components:

- `MeetingKnowledgePackageExporter`
  - Creates the package directory.
  - Writes `meeting.md`, `transcript.md`, and `knowledge.md`.
- `MeetingKnowledgeMarkdownRenderer`
  - Renders all three Markdown files from typed inputs.
- `MeetingKnowledgeProvider`
  - Generates typed knowledge items from meeting metadata, summary, and transcript.
- `OpenRouterMeetingKnowledgeProvider`
  - Uses the existing OpenRouter chat client for the first provider implementation.
- `MeetingKnowledge`
  - Internal Codable model for generated knowledge items. This is not exported as a required JSON artifact.

Existing `MeetingExportService` can expose:

```swift
public func exportKnowledgePackage(for record: MeetingRecord, to destinationURL: URL) async throws
```

The async boundary is needed when knowledge extraction must call a provider. If a previously generated knowledge artifact exists in a later version, the service can support a synchronous copy/export path.

## Failure Handling

If transcript is missing:

- Package export fails with `MeetingExportError.missingArtifact("transcript")`.

If summary is missing:

- `meeting.md` can still be generated from metadata and transcript excerpt.
- `knowledge.md` should either call the knowledge provider directly from transcript segments or render a failure note.

If provider is unavailable or fails:

- Still write `meeting.md` and `transcript.md`.
- Write `knowledge.md` with frontmatter and a clear failure section:

```markdown
# Knowledge Deltas

## Extraction Status
Knowledge extraction failed: <reason>
```

Do not silently produce empty knowledge as if the meeting had no durable updates.

## Tests

Unit tests should cover:

- Package directory contains exactly `meeting.md`, `transcript.md`, and `knowledge.md` for successful export.
- `meeting.md` frontmatter includes meeting ID, title, date, language, and participants.
- `transcript.md` renders stable timestamp anchors and speaker labels.
- `knowledge.md` renders required sections in stable order.
- Empty knowledge sections render `No proposed items.`
- Evidence links in `knowledge.md` point to anchors present in `transcript.md`.
- Provider failure still writes `meeting.md` and `transcript.md` and renders a knowledge failure note.
- Missing transcript fails export with a missing artifact error.

The required verification command remains:

```sh
make test
```

## Development Plan After Approval

After this design is approved, implementation should proceed in small steps:

1. Add internal meeting knowledge models and Markdown renderer tests.
2. Implement transcript Markdown rendering with stable anchors.
3. Implement `meeting.md` package entry rendering.
4. Implement `knowledge.md` rendering from typed knowledge items.
5. Add a stub or deterministic knowledge provider for tests.
6. Add OpenRouter-backed knowledge extraction.
7. Add `MeetingExportService.exportKnowledgePackage`.
8. Add UI command or export action for the package.
9. Run `make test`.

## Acceptance Criteria

The milestone is complete when:

- A user can export a completed meeting as a folder containing `meeting.md`, `transcript.md`, and `knowledge.md`.
- The three files are valid Markdown and useful without proprietary tooling.
- `knowledge.md` contains stable sections and item fields suitable for AI ingestion.
- Each emitted knowledge item includes evidence linking back to `transcript.md`.
- Existing transcript, summary, subtitle, and readiness exports continue to work.
- Unit tests cover rendering, package export, and failure paths.
