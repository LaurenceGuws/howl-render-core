# Active Queue

## Current State

M0 scaffold queue open.

## Tickets

| Ticket | Status | Intent |
| --- | --- | --- |
| `M0-A1` | pending | Define contract baseline for module API. |
| `M0-A2` | pending | Implement minimal compile-safe scaffold. |
| `M0-A3` | pending | Add baseline tests and close queue. |

## Guardrail

- One ticket per commit.
- Mandatory validation per ticket:
  - zig build
  - zig build test

## TH2 (Test Hygiene Phase 2)

| Ticket | Status | Intent |
| --- | --- | --- |
| `TH2-1` | done | Baseline test inventory (TEST_HYGIENE_MATRIX.md) |
| `TH2-2` | done | VS Code workflow normalization (.vscode/ config) |
| `TH2-3` | done | Platform target verification (standard config) |

### Known Intentional Limits

- Minimal test coverage (API surface checks only)
- GPU rendering tests deferred to integration phase
- Platform-specific integration testing deferred
- Direct-file testing not applicable (cross-module dependencies)

