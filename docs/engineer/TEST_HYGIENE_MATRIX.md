# Test Hygiene Baseline - Render Core

## Overview

Backend-neutral render-plan scaffold with package-context tests.

## Test Entrypoints

| Entrypoint | Status | Count | Classification |
| --- | --- | --- | --- |
| `zig build test` | ✓ passing | 2 | Package-aware scaffold validation |

## Coverage Notes

- render-plan stats summarize backend-neutral command sets
- empty-plan behavior is deterministic

## Known Intentional Limits

- no frame-to-plan builder behavior yet
- no backend conformance fixtures yet
