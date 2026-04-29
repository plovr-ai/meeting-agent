# Recommended Questions Design

## Context

Issue #76 asks for a recommended questions module based on the meeting topic and goal progress. The module should show at most two questions, and should not appear when the app cannot produce accurate recommendations.

The existing `MeetingGoal.requiredQuestions` field is not exposed in the agenda UI, so this feature must not depend on preconfigured required questions.

## Goals

- Generate recommended manager questions from the meeting goal, agenda topics, unresolved objective progress, and current transcript context.
- Show at most two recommended questions.
- Hide the module when there is not enough meeting context for accurate recommendations.
- Keep the implementation deterministic for this iteration; do not add an extra LLM call.

## Non-Goals

- Add UI for editing `requiredQuestions`.
- Add a new hosted recommendation provider.
- Persist a separate recommendation artifact beyond the existing meeting progress JSON.

## Approach

`DeterministicMeetingProgressAnalyzer` will continue writing `MeetingProgressState.suggestedQuestions`, but the source of those suggestions will change from `requiredQuestions` to context-driven recommendations.

The analyzer will:

- Prefer unresolved meeting objectives when objectives exist.
- Fall back to agenda topics when objectives are unavailable.
- Avoid recommending a question when the objective or topic already appears covered by the transcript text.
- Return at most two recommendations.
- Return no recommendations when there is no useful goal/objective/topic context.

`MeetingAgentViewModel` will expose a derived `recommendedQuestions` array from the current `meetingProgressState`.

`MainWindowView` will pass those questions into the right-side insights pane and render a `Recommended Questions` panel only when the array is non-empty.

## UI Behavior

The insights pane will show `Recommended Questions` above the summary/export controls. Each item shows the localized Chinese prompt when available and the English/source prompt as supporting text. If there are no suggested questions, the panel is not rendered.

## Data Flow

1. A meeting has a `MeetingGoal` and optional agenda topics.
2. Live captions are drained into the view model.
3. `refreshMeetingProgress()` runs the analyzer.
4. The analyzer writes up to two context-driven `FollowUpQuestionSuggestion` values into `MeetingProgressState`.
5. The view model publishes the current progress state.
6. The insights pane conditionally renders the recommended questions panel.

## Testing

- Unit-test the analyzer returns at most two context-driven suggestions.
- Unit-test suggestions do not require `requiredQuestions`.
- Unit-test suggestions are hidden when there is no reliable objective/topic context.
- Add a view-model test proving recommended questions publish from refreshed progress.
- Add a layout guard proving the insights pane contains the recommended questions panel and does not render placeholder empty-state text.
