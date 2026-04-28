# Restart Meeting Listening Design

## Context

Issue #47 reports that after a meeting is stopped, the app no longer prompts to start listening when audio is detected again. The current monitor remembers every prompted process ID and suppresses repeated prompts until that process exits. Manual Stop clears the recording state but leaves the active process ID in that prompted set.

## Goal

After a user manually stops recording a meeting, the same still-running meeting process can trigger a fresh start prompt when audio is active again.

## Requirements

- Manual Stop releases only the stopped active process from the prompted-process suppression set.
- Ignored candidates remain ignored until their process exits.
- Recording still suppresses candidate prompts.
- Target-process-ended handling remains unchanged.
- Tests cover the monitor behavior and the view-model Stop flow.

## Non-Requirements

- Do not auto-restart recording.
- Do not change the candidate UI.
- Do not clear every prompted or ignored process after Stop.

## Selected Approach

Add a focused `allowReprompt(processID:)` method to `MeetingProcessMonitor` that removes one process ID from `promptedProcessIDs`. Call it from manual stop paths in `MeetingAgentViewModel` before clearing `activeTarget`.

This keeps the feature local to the existing detection boundary and avoids changing discovery, capture, or UI behavior.

## Alternatives Considered

- Clear all prompted processes on Stop. This is simple but can re-prompt unrelated active meeting apps.
- Ignore prompted-process suppression after any Stop. This is broader than needed and makes monitor state harder to reason about.

## Test Plan

- Add a `MeetingProcessMonitorTests` case proving `allowReprompt(processID:)` permits the same active preferred target to be detected again.
- Add a `MeetingProcessMonitorTests` case proving ignored processes stay ignored even after `allowReprompt(processID:)`.
- Add a `MeetingAgentViewModelTests` case proving manual Stop permits the same still-running target to become a pending candidate again.
- Run `make test`.

