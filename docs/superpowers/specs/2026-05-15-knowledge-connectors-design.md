# Knowledge Connectors Product Architecture Design

Date: 2026-05-15
Status: Proposed
Owner: MeetingAgent

## Summary

MeetingAgent should turn completed meetings into durable knowledge events that can feed both Karpathy-style Markdown wikis and GBrain-style agent memory systems.

The product architecture should keep MeetingAgent focused on producing trustworthy meeting outputs, then route those outputs through connector adapters. The first implementation path is Karpathy Wiki because it is a local Markdown folder protocol. GBrain support should be designed now but implemented later as a second connector that consumes the same meeting knowledge package.

The core flow is:

```text
MeetingSessionState
  -> MeetingKnowledgePackage
       meeting.md
       transcript.md
       knowledge.md
       ingest.md
  -> KnowledgeConnector
       KarpathyWikiConnector
       GBrainConnector
  -> KnowledgeSyncResult
```

## Product Principle

The product should not merely export notes. It should create a reviewable, evidence-backed knowledge inbox from each meeting.

Every destination should receive the same canonical meeting knowledge package. Destination-specific behavior belongs in connector adapters, not in realtime captioning, transcription, summary generation, or meeting persistence.

This preserves three important properties:

- The transcript remains the evidence source.
- Knowledge updates stay reviewable before they become long-term memory.
- New knowledge backends can be added without rewriting meeting output logic.

## Goals

- Support Karpathy Wiki as the first knowledge destination.
- Support GBrain later through the same connector boundary.
- Keep Markdown as the stable exchange format for meeting knowledge.
- Preserve evidence links from every durable knowledge item back to transcript anchors.
- Avoid coupling realtime recording, captioning, or transcription to knowledge sync.
- Make sync failure non-destructive: a failed wiki or GBrain export must not affect recording, transcription, summary, or local artifacts.

## Non-Goals

- Do not implement GBrain in the first milestone.
- Do not build a full knowledge base inside MeetingAgent.
- Do not auto-merge inferred meeting claims into long-term memory without review.
- Do not replace existing transcript, summary, subtitle, readiness report, or manual export workflows.
- Do not add realtime translation or active-recording knowledge publishing.

## Current Foundation

The repository already has the right first building blocks:

- `MeetingSessionState` is the in-memory source of truth for transcript and summary consumers.
- `MeetingExportService.exportKnowledgePackage` already exports a Markdown package from a meeting session.
- `MeetingKnowledgePackageMarkdownRenderer` already renders `meeting.md`, `transcript.md`, and `knowledge.md`.
- `transcript.json` remains the persisted `CaptionDocument`, but product consumers should read memory state whenever it exists.

This design should extend that existing shape rather than introduce a parallel file-backed transcript bridge or a destination-specific knowledge model.

## Canonical Knowledge Package

Each completed meeting can produce one package:

```text
YYYY-MM-DD-<meeting-slug>/
  meeting.md
  transcript.md
  knowledge.md
  ingest.md
```

The first three files are destination-neutral. `ingest.md` is a destination-neutral agent instruction file that tells a wiki or brain agent how to process the package.

### meeting.md

`meeting.md` is the package entry point.

It includes:

- YAML frontmatter with meeting ID, title, timestamps, language, provider, and participants.
- One-line summary.
- Key outcomes from decisions, actions, and unresolved questions.
- Meeting context.
- Links to `transcript.md`, `knowledge.md`, and `ingest.md`.

### transcript.md

`transcript.md` is the evidence layer.

It includes:

- One section per final transcript turn or segment.
- Stable anchors such as `t-00-12-31`.
- Speaker labels.
- Faithful transcript text.

The transcript must not be summarized, translated, or rewritten as part of knowledge export.

### knowledge.md

`knowledge.md` is the candidate long-term memory update file.

It includes these stable top-level sections:

1. Facts
2. Judgments
3. Decisions
4. Actions
5. Open Questions
6. Entity Updates

Each item includes:

```markdown
### decision_001
**Statement:** Q3 Japan launch will start with a Tokyo-only pilot.
**Related:** [[Japan GTM]], [[Tokyo]]
**Confidence:** High
**Status:** Proposed
**Evidence:** [[transcript#t-00-42-18|Alice 00:42:18]]
```

`Status: Proposed` is the default. Later review workflows can change item state to `Accepted`, `Edited`, or `Rejected`.

### ingest.md

`ingest.md` is a task file for a downstream agent.

It should say:

- Treat this directory as one meeting source package.
- Treat `transcript.md` as evidence.
- Treat `knowledge.md` as proposed deltas, not automatic truth.
- Update the long-term wiki or brain according to local schema.
- Preserve evidence links or convert them into the destination's citation format.
- Append timeline entries for accepted decisions, actions, and important entity updates.
- Mark inferred judgments, cultural interpretation, or relationship insight as inference.

This makes the Karpathy Wiki first path usable without requiring MeetingAgent to run an agent itself.

## Connector Layer

MeetingAgent should introduce a connector abstraction that consumes canonical packages.

```swift
public protocol KnowledgeConnector {
    var id: String { get }
    var displayName: String { get }

    func validate(configuration: KnowledgeConnectorConfiguration) async -> KnowledgeConnectorValidation
    func sync(package: MeetingKnowledgePackage, configuration: KnowledgeConnectorConfiguration) async throws -> KnowledgeSyncResult
}
```

Configuration:

```swift
public enum KnowledgeConnectorKind: String, Codable, Equatable {
    case karpathyWiki
    case gbrain
}

public struct KnowledgeConnectorConfiguration: Codable, Equatable {
    public let kind: KnowledgeConnectorKind
    public let isEnabled: Bool
    public let rootURL: URL?
    public let commandPath: String?
    public let autoSyncEnabled: Bool
    public let requireReviewBeforeSync: Bool
}
```

Result:

```swift
public struct KnowledgeSyncResult: Codable, Equatable {
    public let connectorID: String
    public let status: KnowledgeSyncStatus
    public let destinationDescription: String
    public let filesWritten: [URL]
    public let commandOutput: String?
    public let syncedAt: Date
}
```

The connector layer should live after package generation. It should not own transcript formatting, summary generation, or knowledge extraction.

## Karpathy Wiki Connector

Karpathy Wiki is a folder protocol, not a remote API.

The connector writes the canonical package into:

```text
<WikiRoot>/
  raw/
    meetings/
      YYYY-MM-DD-<meeting-slug>/
        meeting.md
        transcript.md
        knowledge.md
        ingest.md
```

Validation checks:

- `rootURL` is configured.
- The root exists or can be created if the user opted into creation.
- `raw/meetings` exists or can be created.
- The destination package directory does not accidentally overwrite unrelated files.
- The app can write to the destination.

Sync behavior:

- Render the canonical package from the current meeting session.
- Write all files atomically where possible.
- Return a success result with the destination path.
- On failure, return or throw a connector-specific error that the UI can present clearly.

The first implementation should not run an external agent automatically. It should create `ingest.md` so the user can ask Codex, Claude, or another wiki agent to process it.

Later Karpathy Wiki enhancements can add:

- Copy ingest prompt to clipboard.
- Open destination folder.
- Optional local command hook to run a user-provided agent command.
- A sync status marker after the user confirms the wiki has ingested the package.

## GBrain Connector

GBrain is a later connector that should consume the same package.

The initial design should support three modes but implement none in the Karpathy-first milestone:

1. CLI mode:

```text
gbrain ingest <package-dir> --type meeting
```

2. MCP stdio mode:

```text
gbrain serve
```

3. Remote MCP/HTTP mode:

```text
gbrain serve --http
```

Validation checks for the future GBrain connector:

- Detect `gbrain` command path.
- Verify installed GBrain is the intended package, not an unrelated binary.
- Run a lightweight health or version command.
- Confirm the configured brain can accept writes.
- Surface whether GBrain is using local PGLite or remote Postgres/Supabase if discoverable.

GBrain sync should start with coarse ingestion of the package directory. Fine-grained page, timeline, tag, and typed-link writes can come later.

The connector should preserve the same safety rule as Karpathy Wiki: proposed knowledge should not silently become accepted long-term truth unless the user explicitly enables that behavior.

## Review Model

The architecture should support two product modes:

### Proposed Sync

The connector writes the package with all items marked `Proposed`.

This is the correct default for Karpathy Wiki because the downstream agent can read `knowledge.md` and decide how to merge it according to the wiki schema.

### Reviewed Sync

A later UI lets the user accept, edit, or reject items before syncing.

Reviewed sync can write only accepted and edited items, or include rejected items in an audit section depending on the destination's needs.

The first milestone should use proposed sync only.

## Settings UX

Add a Knowledge Destinations section in settings.

Karpathy Wiki:

```text
[ ] Export to Karpathy Wiki
Wiki root: /Users/allan/wiki
Destination: raw/meetings/
[Test Connection]
```

GBrain:

```text
[ ] Sync to GBrain
Status: Planned
gbrain path: Auto-detect later
```

The GBrain controls can be disabled or hidden behind a "Planned" state until implementation begins.

## Meeting UX

The existing export actions should remain.

Add a knowledge destination action:

```text
Export to Wiki
```

After success:

```text
Knowledge package exported to Karpathy Wiki:
raw/meetings/2026-05-15-japan-gtm-sync/
```

After failure:

```text
Wiki export failed: raw/meetings is not writable.
```

The failure must not change meeting status, transcript status, summary status, or local artifact state.

## Error Handling

Missing transcript:

- Package generation fails with `MeetingExportError.missingArtifact("transcript")`.

Missing summary:

- `meeting.md` can still render from metadata.
- `knowledge.md` should render a clear extraction status instead of pretending there are no updates.

Invalid wiki root:

- Connector validation fails before sync.
- UI shows the path and the reason.

Destination collision:

- If the exact package directory exists, either use a deterministic suffix or fail with a clear "already exists" error.
- Do not merge into an existing package directory unless the user explicitly chooses overwrite.

External command failure for future GBrain:

- Capture command output.
- Mark sync failed.
- Leave the local knowledge package available for retry.

## Testing Strategy

Unit tests should cover:

- Karpathy destination path generation.
- Slug generation from meeting date and title.
- `raw/meetings` directory creation.
- Atomic package writing behavior where practical.
- `ingest.md` content includes source, evidence, proposed-delta, and schema-following instructions.
- Connector validation success and failure cases.
- Missing transcript failure.
- Missing summary fallback.
- Destination collision behavior.
- No connector code reads legacy transcript files directly.
- GBrain connector types compile or remain documented without active UI wiring in phase 1.

Integration-style tests can use temporary directories and a fake connector.

The required verification command remains:

```sh
make test
```

## Implementation Path

### Phase 1: Karpathy Wiki File Connector

- Add connector models and protocol.
- Add `KarpathyWikiConnector`.
- Add `ingest.md` renderer to the existing knowledge package renderer.
- Add settings for wiki root and enabled state.
- Add manual "Export to Wiki" action.
- Test package structure, validation, evidence links, and failures.

### Phase 2: Review Workflow

- Display knowledge deltas in the app.
- Let users accept, edit, or reject items.
- Persist review state.
- Let sync use reviewed items.

### Phase 3: GBrain CLI Connector

- Detect and validate `gbrain`.
- Export a temporary package or reuse the canonical package.
- Run `gbrain ingest`.
- Capture sync result and command output.
- Add tests with a fake command runner.

### Phase 4: GBrain MCP / Remote

- Add MCP or HTTP sync mode.
- Support scoped writes where available.
- Add optional page, timeline, tag, and typed-link writes.
- Add richer sync diagnostics.

## Open Decisions

- Whether `Export to Wiki` should create `raw/meetings` automatically or require it to already exist.
- Whether package directory collisions should fail or create `-2`, `-3` suffixes.
- Whether `ingest.md` should be global and reusable or generated per meeting.
- Whether the first Karpathy Wiki milestone should include a clipboard prompt action.

Recommended defaults:

- Create `raw/meetings` if the configured wiki root is writable.
- Fail on exact package directory collision in phase 1.
- Generate `ingest.md` per meeting.
- Include clipboard prompt as a small follow-up, not in the first connector cut.
