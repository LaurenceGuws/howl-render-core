# Howl Render Core Milestone Authority

This document defines the renderer-core development ladder.
`howl-render-core` owns backend-neutral render planning and backend-facing contracts.

## Milestone Ladder

| ID | Name | Outcome |
| --- | --- | --- |
| `M0` | Scaffold Reset | Repo, docs, and compile-safe stub reflect the renderer-lane architecture. |
| `M1` | Render Plan Contract | Backend-neutral plan types, ownership rules, and lifecycle contracts are explicit. |
| `M2` | Plan Builder Baseline | Core transforms frame-model input into deterministic backend-neutral plans. |
| `M3` | Text and Atlas Policy | Glyph placement, atlas update policy, and text batching rules are core-owned. |
| `M4` | Damage and Batch Policy | Incremental update, batching, and clip discipline are explicit and tested. |
| `M5` | Backend Capability Negotiation | Render-core plans against declared backend capabilities without backend-specific policy leaks. |
| `M6` | Backend Conformance Fixtures | Shared fixtures prove backends consume identical plans with identical semantic results. |
| `M7` | Performance and Memory Discipline | Plan generation, buffer growth, and allocation bounds are measured and enforced. |
| `M8` | Integration Readiness | Surface/host integration seams are stable and backend-agnostic. |
| `M9` | Visual Reliability | Edge cases, stress paths, and failure boundaries are explicit and reproducible. |
| `M10` | Production Render Core | Render-core is mature enough to anchor all backend implementations. |

## Current Target

Current target is `M5` backend capability negotiation.
