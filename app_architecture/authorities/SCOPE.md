# Scope Authority

Purpose: define what this module owns and what it does not own.

## In Scope

- Backend-agnostic renderer core logic
- Stable local API and deterministic behavior for this module
- Module-level tests and validation evidence

## Out of Scope

- Cross-module ownership policy (documented in parent architecture docs)
- Platform app lifecycle ownership unless this module is a host app
- Compatibility/fallback/workaround shim paths
