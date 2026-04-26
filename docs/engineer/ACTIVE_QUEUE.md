# Howl Render Core Active Queue

## Current State

M0 scaffold reset closed. Active authority target is `M5` backend capability
negotiation. M1 through M4 execution queues will be published in Sprint 2
(MVP-S2) as the architect confirms the progression path toward M5.

## Read Before Execution

- `app_architecture/authorities/SCOPE.md`
- `app_architecture/authorities/BOUNDARIES.md`
- `app_architecture/authorities/MILESTONE.md`
- `docs/architect/MILESTONE_PROGRESS.md`

## Guardrail

No engineer execution queue is published for M1-M5 yet. Do not begin
implementation work until the architect publishes a bounded queue entry.
The blocking reset notice has been removed; the blocking is now the absence
of a published queue, not an incomplete reset.
