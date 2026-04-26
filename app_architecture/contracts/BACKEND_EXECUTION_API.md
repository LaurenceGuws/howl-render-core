# Backend Execution API Contract

## Summary

Every render backend must implement a bounded execution API surface. Backends are thin
executors: they accept backend-neutral plans from `howl-render-core` and submit GPU or CPU
draw work. They do not plan, reinterpret, or augment plan contents.

## Required API Surface

Every backend implementation must expose the following operations:

### `init(config: BackendConfig) !Backend`

Initialize the backend from a declared surface and cell geometry.
- Transitions state from cold to ready.
- `config.surface_px` is the current drawable pixel dimensions.
- `config.cell_px` is the terminal cell pixel dimensions.
- `config.font_path` is an optional host-provided font path used by text-capable backends.
- Initialization may fail if required backend resources cannot be loaded.

### `deinit(*Backend) void`

Release all backend-local resources. Transitions state to cold. Must be safe to call from
any state.

### `resize(*Backend, surface_px: PixelSize) void`

Update the backend's declared surface pixel dimensions. Does not trigger a re-render.
Backends that hold viewport or projection state derived from surface size should update
that state here.

### `execute(*Backend, plan: RenderPlan) ExecuteError!void`

Submit a backend-neutral render plan for execution.
- Backend must be in ready state. Returns `error.NotReady` if not.
- Backend must not modify plan contents or plan semantics.
- Backend must not implement planning policy (batching, atlas assignment, cursor policy).
- Backend submits draw work derived from the plan's command lists.

### `capabilities(*const Backend) BackendCapability`

Return the backend's declared execution limits. Used by `howl-render-core` for capability
negotiation (milestone M5). Must be callable in any state (including cold).

## State Model

```
cold ──init──▶ ready ──execute──▶ ready
  ▲                                  │
  └────────────deinit────────────────┘
```

`execute` is only valid in `ready` state. `deinit` is valid from any state.

## Ownership Boundary

Backends own:
- GPU/CPU resource handles (textures, buffers, shaders, framebuffers)
- Device context and presentation surface references
- Resource lifecycle within a session (init → deinit)

Backends do not own:
- Plan structure or command ordering
- Atlas slot assignment
- Glyph placement or text batching decisions
- Damage tracking or incremental update policy

## Error Surface

`ExecuteError` is the only declared error set backends may return from `execute`. Backends
must not surface backend-specific error variants through the core execution API. Backend
diagnostic state is backend-local.

## BackendConfig

`BackendConfig` is defined in `howl-render-core`. Backends accept it as an opaque
initialization input. Backends must not extend or redefine this type.

```
BackendConfig {
    surface_px: PixelSize   // drawable pixel dimensions
    cell_px:    CellSize    // cell pixel dimensions
    font_path:  ?[:0]const u8 // optional host-provided font resource path
}
```
