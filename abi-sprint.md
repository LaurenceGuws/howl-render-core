# Howl Render ABI Sprint

Shared rules: [`../AGENTS.md`](../AGENTS.md), [`../WORKFLOW.md`](../WORKFLOW.md),
[`../design/style-law.md`](../design/style-law.md),
[`../design/tigerbeetle-style-sprint.md`](../design/tigerbeetle-style-sprint.md)

## Purpose

This sprint applies the PTY and VT boundary reset standard to `howl-render`.

Target outcome:

- TigerBeetle-style discipline
- C ABI embeddability as the real product boundary
- no Zig-shaped host facades
- no wrapper namespace roots
- no integer-handle ABI posture where opaque handles should be explicit
- no runtime getter-heavy convenience posture where explicit state-machine steps should own the seam

`howl-pty` and `howl-vt` are the reference results.

## Current Smells

- `src/howl_render.zig` mixes ABI export duty and repo-local/public Zig root posture
- `src/render_namespace.zig` is wrapper namespace theater
- `build.zig` preserves fake dual-surface posture with self-import wiring around the same root
- `include/howl_render.h` still uses integer handle posture:
  - `HowlRenderSnapshotHandle`
  - `HowlRenderRuntimeHandle`
  - `HowlRenderRendererHandle`
- `src/ffi.zig` still mirrors that integer handle posture with `usize` handles and pointer casts
- `include/howl_render.h` still exports runtime convenience helpers that may be deletion targets:
  - `howl_render_runtime_has_pending_publication`
  - `howl_render_runtime_action`
- Linux host already consumes the render ABI, but current seam shape may still preserve convenience
  posture that should read as explicit runtime transitions instead
- `design.md` still presents Zig owner surfaces as the public render surface instead of naming the C ABI
  as the real embedding boundary

## Baseline

Current known measured totals from the shared sprint doc:

- `prod=12304`
- `usizes=770`
- `long_funcs=14`
- `asserts=72`

Current boundary facts observed before sprint start:

- shipped header exists: `include/howl_render.h`
- ABI exports currently come from `src/howl_render.zig`
- wrapper root exists: `src/render_namespace.zig`
- repo-local test root and ABI export root are not split yet
- Linux host consumes `howl_render_*` only, through C ABI

## Required End State

- one explicit shipped contract: `include/howl_render.h`
- one explicit ABI export root: `src/libhowl_render.zig`
- no wrapper namespace root
- no host-facing Zig root story in docs, roots, or build wiring
- no stale exported symbols remain
- render handles are opaque-pointer-shaped where ownership requires it
- Linux host consumes the cleaned render ABI only

## Checkpoints

### Checkpoint 1

Theme: contract lock.

Assigned files:

- `design.md`

Must do:

- rewrite `design.md` facts to describe C ABI as the only real embedding boundary
- name every Zig-shaped facade or root scheduled for deletion
- remove wording that preserves Zig-root consumption as an acceptable integration path

### Checkpoint 2

Theme: root and facade deletion.

Assigned files:

- `src/render_namespace.zig`
- `src/howl_render.zig`
- `src/libhowl_render.zig`
- `build.zig`

Must do:

- delete `src/render_namespace.zig`
- stop `src/howl_render.zig` from acting as host-facing convenience aggregation
- add `src/libhowl_render.zig` as the explicit ABI export root
- remove build wiring that preserves fake dual-surface posture

### Checkpoint 3

Theme: ABI sharpening.

Must do:

- inventory and delete getter-heavy runtime convenience symbols that should be read through explicit
  runtime transitions instead
- replace integer-handle posture with stricter opaque-handle contracts where the host can consume them
- remove stale validators or convenience helpers that do not belong in the shipped ABI

### Checkpoint 4

Theme: owner cleanup.

Must do:

- keep render contracts, runtime state, retained publication mutation, and backend submission owner-separated
- remove remaining repo-local public shape that suggests host-facing Zig owner access
- tighten docs so shipped ABI and repo-local owner APIs are not mixed

### Checkpoint 5

Theme: Linux host proof.

Must do:

- update `howl-linux-host` to the cleaned render ABI as needed
- remove stale host assumptions about deleted symbols
- prove the host still builds and runs on the owned path

## Proof Gates

Each checkpoint must close with all of the following:

- `zig build test` in `howl-render`
- `nu "./style.nu" --touched-files --json`
- `nu "./style.nu" --failures --json`
- `git diff --check`
- when ABI changes reach the host seam, `zig build` in `howl-linux-host`

## Review Gates

A checkpoint fails review if it does any of the following:

- preserves a Zig-shaped facade or root because it is convenient
- adds a compatibility wrapper
- keeps duplicate public stories alive in parallel
- exports a symbol that exists only to mirror Zig internals
- leaves ownership unclear between render contracts, runtime state, backend submission, and FFI
- keeps hidden policy in a root or wrapper
- claims C ABI first while preserving Zig integration as a practical bypass
- closes without exact proof on the changed path
