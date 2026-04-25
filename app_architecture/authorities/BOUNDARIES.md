# Boundary Authority

## Hard Boundaries

- Expose host-neutral/public module APIs only.
- Keep implementation details internal.
- No cross-repo internal imports.

## Forbidden Coupling

- No hidden coupling to sibling module internals.
- No platform/framework leakage across module boundary unless module is platform-owned.
