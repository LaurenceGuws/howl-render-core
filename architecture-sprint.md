# Howl Render Architecture Sprint

Shared rules: [`../AGENTS.md`](../AGENTS.md), [`../WORKFLOW.md`](../WORKFLOW.md),
[`../design/style-law.md`](../design/style-law.md),
[`../design/tigerbeetle-style-sprint.md`](../design/tigerbeetle-style-sprint.md)

## Purpose

This sprint corrects the render/backend ownership inversion that remained after the render ABI sprint.

Target outcome:

- GL and GLES are leaf wrappers over external C libraries and GPU objects only
- `Renderer` consumes a small backend contract instead of the backends consuming shared render policy
- `Render.Text` owns text analysis, scene assembly, raster planning, and render pipeline policy
- backend roots stop acting like partial renderers
- host proof still closes on the cleaned render ABI path

The render ABI sprint is already closed. This sprint is about architecture, not ABI shape.

## Non-Negotiable Rule

Backends do not own render policy.

Backends do not own text analysis.

Backends do not own retained-frame orchestration.

Backends wrap external C libraries and GPU state, then expose a small leaf contract upward.

If a proposed change preserves the current backwards contract shape for comfort, reject it.

## Current Inversion

Today the render stack still works backwards in these ways:

- `src/renderer.zig` delegates top-level staged work into backend roots through:
  - `prepareFrame(...)`
  - `submitFrame(...)`
- backend roots still expose render-policy-shaped surfaces such as:
  - `analyzeTextCellsOptions(...)`
  - `prepareFrame(...)`
  - `uploadTextSceneRaster(...)`
  - `renderTextScene(...)`
  - `renderFrameState(...)`
- renderer still reads backend-owned observability like:
  - `resolveCounters()`
  - `surfaceHandle()`
- `design.md` still documents this staged backend contract as acceptable owner shape

## Correct Owner Model

- `Render` owns render contracts, retained-publication policy, geometry policy, and frame-state transitions
- `Render.Text` owns text analysis, cluster selection, resolve, shape, grouping, scene assembly, and raster planning
- `Renderer` owns orchestration across render policy and one selected backend
- GL and GLES own only:
  - external C library binding and callback glue
  - backend-local atlas storage
  - texture/FBO/shader/program state
  - upload primitives
  - draw submission primitives
  - backend capability facts that truly depend on the backend

## Required End State

- backend roots expose only leaf GPU/storage operations and true backend capabilities
- renderer consumes prepared scene and raster outputs through a smaller backend contract
- no backend root owns text analysis entrypoints or one-shot render-policy surfaces
- render policy reads from `Render` and `Render.Text`, not from backend convenience APIs
- GL and GLES still close on parity and host proof after the inversion

## Checkpoints

### Checkpoint 1

Theme: contract lock.

Assigned files:

- `design.md`
- `architecture-sprint.md`

Must do:

- rewrite render design facts so backend layers are explicitly leaf wrappers only
- name every current backend-root surface that is a deletion or move target
- lock the review rule that preserving the backwards contract shape fails review

### Checkpoint 2

Theme: backend contract inventory.

Assigned files:

- `src/renderer.zig`
- `src/backend/gl/backend.zig`
- `src/backend/gles/backend.zig`

Must do:

- inventory every backend-root function and classify it as:
  - true backend leaf contract
  - renderer-owned orchestration that must move up
  - text/render policy that must move out
- do not move code yet unless required to make the inventory truthful

### Checkpoint 3

Theme: renderer orchestration reclaim.

Assigned files:

- `src/renderer.zig`
- `src/render.zig`
- `src/text/engine.zig`

Must do:

- move staged render orchestration out of backend roots into renderer/render owners
- make renderer consume a smaller backend contract
- keep runtime and prepared-frame ownership explicit and singular

### Checkpoint 4

Theme: backend root collapse.

Assigned files:

- `src/backend/gl/backend.zig`
- `src/backend/gles/backend.zig`
- `src/backend/gl/internal/provider.zig`
- `src/backend/gles/internal/provider.zig`

Must do:

- remove backend-owned text analysis and one-shot render-policy surfaces
- leave backend roots as C-lib/GPU wrappers plus true backend-local mutation only
- keep GL/GLES parity on the reduced contract

### Checkpoint 5

Theme: proof and parity.

Assigned files:

- `src/test/runtime_proof.zig`
- `src/test/render_benchmark.zig`
- `howl-linux-host/src/terminal/api.zig` if host seam needs adjustment

Must do:

- prove renderer/backends still close on the owned host path
- prove GL/GLES parity on the reduced contract
- update docs to state the closed architecture result

## Proof Gates

Each checkpoint must close with all of the following:

- `zig build test` in `howl-render`
- `zig build test:render` in `howl-render`
- `nu "./style.nu" --touched-files --json`
- `nu "./style.nu" --failures --json`
- `git diff --check`
- when host seam changes, `zig build` in `howl-linux-host`
- when host behavior changes, `zig build run` in `howl-linux-host` if feasible

## Review Gates

A checkpoint fails review if it does any of the following:

- preserves backend-owned render policy because it is convenient
- keeps text analysis entrypoints on backend roots
- keeps one-shot render-policy surfaces on backend roots
- adds another wrapper layer between renderer and backend
- leaves ownership unclear between render contracts, text policy, backend leaf operations, and FFI
- closes without proof on GL/GLES parity or the owned host path when those seams changed
