# Backend Capability Declaration Contract

## Summary

`BackendCapability` is the mechanism by which a backend declares its execution limits to
`howl-render-core`. Render-core uses declared capabilities to plan within backend bounds.
Capability negotiation is milestone M5; this document defines the contract that M5 will
implement against.

## Ownership

Capability declaration is `howl-render-core`-owned:
- `BackendCapability` type is defined in `howl-render-core`.
- Backends return a populated `BackendCapability` via `capabilities()`.
- Render-core interprets capability values when building plans.
- Backends must not use capabilities to skip execution of plan commands they declared support for.

## BackendCapability Fields

```
BackendCapability {
    max_atlas_slots:      u32   // maximum atlas slot count the backend can manage
    supports_fill_rect:   bool  // backend can execute FillRect commands
    supports_glyph_quads: bool  // backend can execute GlyphQuad commands
}
```

### `max_atlas_slots`

The maximum number of distinct atlas slots the backend can hold simultaneously.
- Render-core must not produce plans that reference slot indices ≥ `max_atlas_slots`.
- A value of 0 means the backend has not yet queried device limits (stub state).

### `supports_fill_rect`

Whether the backend can execute `FillRect` commands in a plan.
- A conforming backend that declares `true` must execute all `FillRect` commands in the plan.

### `supports_glyph_quads`

Whether the backend can execute `GlyphQuad` commands in a plan.
- A conforming backend that declares `true` must execute all `GlyphQuad` commands in the plan.

## Capability Stability

Capabilities are declared per-backend-instance and are considered stable for the lifetime
of that instance (init → deinit). Render-core may cache declared capabilities after the
first query. Backends must not return different values across calls within one session.

## Relationship to Conformance (M6)

Backend conformance fixtures (M6) verify that backends correctly execute plans within their
declared capability bounds. A backend that declares `supports_fill_rect: true` but fails to
execute fill-rect commands fails conformance. Capability declarations are binding.

## M1 Status

At M1, `BackendCapability` is a declared contract type. Render-core does not yet negotiate
against capabilities (that is M5). Backends should return accurate values for
`supports_fill_rect` and `supports_glyph_quads`. `max_atlas_slots` may be 0 until device
limit queries are implemented (M2+).
