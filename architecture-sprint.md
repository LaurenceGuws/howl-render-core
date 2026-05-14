# Howl Render Architecture Sprint

Shared rules: [`../AGENTS.md`](../AGENTS.md), [`../WORKFLOW.md`](../WORKFLOW.md),
[`../design/style-law.md`](../design/style-law.md),
[`../design/tigerbeetle-style-sprint.md`](../design/tigerbeetle-style-sprint.md)

## Purpose

This sprint corrects the render/backend ownership inversion that remained after the render ABI sprint.

This sprint also assumes a harder truth: most of the existing renderer/backends contract is not a
preservation target. If the current path is owner-wrong or performance-wrong, delete it or rewrite
it. Do not preserve a bad pipeline because it already exists.

Target outcome:

- GL and GLES are leaf wrappers over external C libraries and GPU objects only
- `Renderer` consumes a small backend contract instead of the backends consuming shared render policy
- `Render.Text` owns text analysis, scene assembly, raster planning, and render pipeline policy
- backend roots stop acting like partial renderers
- host proof still closes on the cleaned render ABI path

The render ABI sprint is already closed. This sprint is about architecture, not ABI shape.

## Operating Model

This document is the control plan for the render rewrite.

Roles are explicit:

- architect/reviewer/git gatekeeper:
  - defines milestone scope
  - defines checkpoint scope
  - locks owner truth before code moves
  - rejects guessing, wrapper theater, and fake progress
  - accepts or rejects checkpoint closure based on proof and touched-file review
  - decides when a checkpoint is ready to commit and push
- engineer:
  - executes one active checkpoint only
  - does not widen scope beyond the assigned files and closure bar
  - reports exact code changes, proof results, style results, and open edges
  - stops with `work-not-clear` instead of guessing

No checkpoint advances on intuition alone. The architect sets the contract first, then the engineer
proves the change against that contract.

## Why Now

The embedded renderer is the product edge. If it is owner-wrong, hidden-policy-heavy, or
performance-soft, it drags the whole terminal down. This sprint is the bandage rip:

- remove backend-owned render policy completely
- remove convenience surfaces that hide expensive work behind the wrong owner
- keep only the code that earns its place under a smaller, faster, owner-true renderer spine

The standard is not merely "clean enough". The standard is that the render architecture should make
future cleanup easier, performance work more mechanical, and review harder to fool.

## Non-Negotiable Rule

Backends do not own render policy.

Backends do not own text analysis.

Backends do not own retained-frame orchestration.

Backends wrap external C libraries and GPU state, then expose a small leaf contract upward.

If a proposed change preserves the current backwards contract shape for comfort, reject it.

If a proposed change keeps a slow or owner-wrong path alive "until later", reject it.

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
- Checkpoint 1 fixed the docs, but the code still carries this staged backend contract shape

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

## Architecture Principles

- one owner for branch policy
- one owner for retained-frame transitions
- one owner for text analysis and raster planning
- one owner for geometry derivation
- one owner for backend-local GPU mutation
- backends do bounded leaf work only; they do not decide the pipeline
- do not widen contracts to save a rewrite; shrink contracts until ownership is obvious

## Milestone Map

The sprint is split into milestones so planning, execution, and review stay local and exact.

### Milestone 1

Theme: contract lock and inventory truth.

Goal:

- make the final owner model explicit before code motion starts
- classify every backend-root public surface before any preservation decision is made

Checkpoints:

1. Checkpoint 1: contract lock
2. Checkpoint 2: backend contract inventory

Milestone closes when:

- docs define the final owner model without contradiction
- the inventory/disposition table is complete for GL and GLES backend roots
- every surviving backend-root public surface has an explicit owner-true reason

### Milestone 2

Theme: renderer control-spine reclaim.

Goal:

- move prepare/submit sequencing back into `Renderer`
- move renderer-visible observability into renderer-owned records
- stop backend roots from acting like frame-state owners

Checkpoints:

1. Checkpoint 3A: renderer sequencing design lock
2. Checkpoint 3B: renderer sequencing implementation
3. Checkpoint 3C: renderer observability reclaim

Milestone closes when:

- `Renderer` owns staged frame sequencing end to end
- runtime transitions are explicit in one owner path
- backend convenience getters are no longer required for renderer-owned observability

### Milestone 3

Theme: backend root collapse.

Goal:

- reduce GL/GLES roots to leaf wrappers over GPU objects and provider wiring
- delete one-shot pipeline surfaces and geometry passthroughs from backend roots

Checkpoints:

1. Checkpoint 4A: backend public-surface reduction
2. Checkpoint 4B: backend internal collapse
3. Checkpoint 4C: backend test relocation and truth cleanup

Milestone closes when:

- backend roots fit the target backend contract only
- no backend root exports text analysis or whole-pipeline render policy
- backend tests prove only the surviving backend contract

### Milestone 4

Theme: proof, parity, and closure.

Goal:

- prove the rewrite on the owned repo and host path
- record the final architecture result and surviving contract exactly

Checkpoints:

1. Checkpoint 5A: repo proof and parity proof
2. Checkpoint 5B: host proof and doc closure

Milestone closes when:

- GL and GLES close on equivalent renderer-owned sequencing
- host proof closes on the owned ABI path
- final docs describe the surviving contract and deleted surfaces without ambiguity

## Checkpoint Packet

Every checkpoint handoff to the engineer must include all of the following:

- checkpoint tag
- milestone tag
- owner view
- assigned files
- surfaces in scope
- surfaces explicitly out of scope
- exact smell being corrected
- exact closure conditions
- exact proof commands
- exact review-fail conditions

If any field is missing, the checkpoint is not ready for engineering.

## Engineer Report Format

Every completed checkpoint report must include all of the following:

- checkpoint tag
- owner view
- exact files read
- exact files changed
- exact APIs or surfaces removed, moved, replaced, or preserved
- why each surviving surface remains owner-true
- exact proof commands run
- exact result of each proof command
- style gate output
- open edges or `none`
- commit recommendation: `ready` or `not ready`

If the report relies on implication instead of exact output, reject it.

## Review Sequence

The architect reviews every checkpoint in the same order:

1. contract truth
2. owner truth
3. control-spine truth
4. proof truth
5. style truth
6. commit truth

If any step fails, the checkpoint does not pass.

## Target Backend Contract

The post-inversion backend root should be small and boring. The contract categories are exact:

- lifecycle:
  - `init(...)`
  - `deinit(...)`
- host-owned target binding:
  - `bindTargetTexture(...)`
  - `targetTexture(...)`
- font configuration needed by the backend's provider wiring:
  - `setFontPath(...)`
  - `setFallbackFontPaths(...)`
  - `setFontSizePx(...)`
- backend-local layout facts:
  - `deriveFrameLayout(...)`
- provider/session access used by renderer-owned text planning:
  - `textProvider(...)`
  - `fontSession(...)`
- backend capability facts:
  - `capabilities(...)`
- leaf upload and draw entrypoints after the rewrite:
  - one upload primitive for committed raster outputs
  - one draw primitive for prepared frame draws
  - one present/submit primitive if the backend truly needs a distinct step

The sprint may rename these leaf upload/draw entrypoints. It must not keep higher-level policy on
them.

## Disposition Table

Every backend-root surface named here must end in one of four states: keep, move, delete, or
replace.

| Current surface | Current owner | Classification | Destination owner | Final status |
| --- | --- | --- | --- | --- |
| `analyzeTextCellsOptions(...)` | backend root | text analysis policy | `Render.Text.Engine` | move then delete from backend root |
| `prepareFrame(...)` | backend root | staged renderer orchestration | `Renderer` with `RenderRuntime` and `Render.Text` support | move then delete from backend root |
| `submitFrame(...)` | backend root | staged renderer orchestration | `Renderer` with backend leaf submit primitive only | move then replace |
| `uploadTextSceneRaster(...)` | backend root | upload convenience surface that currently bundles renderer policy timing | backend leaf upload primitive consumed by `Renderer` | replace |
| `renderTextScene(...)` | backend root | one-shot render-policy surface | backend leaf draw primitive consumed by `Renderer` | replace |
| `renderFrameState(...)` | backend root | convenience whole-pipeline owner violation | no surviving owner | delete |
| backend-root `deriveGridSize(...)` | backend root | geometry convenience passthrough | `Render` | delete |
| backend-root `deriveGridForFrame(...)` | backend root | geometry convenience passthrough | `Render` | delete |
| `resolveCounters()` | backend root | observability ownership leak | `Renderer` or `RenderRuntime` metric record | move then delete from backend root |
| `surfaceHandle()` | backend root | observability ownership leak | `Renderer` submitted/prepared frame record | move then delete from backend root |
| `lastResolveStage()` | backend root | observability ownership leak | `Renderer` or `RenderRuntime` state transition record | move then delete from backend root |
| `init(...)` | backend root | true leaf contract | backend root | keep |
| `deinit(...)` | backend root | true leaf contract | backend root | keep |
| `bindTargetTexture(...)` | backend root | true leaf contract | backend root | keep |
| `setFontPath(...)` | backend root | true leaf contract | backend root | keep |
| `setFallbackFontPaths(...)` | backend root | true leaf contract | backend root | keep |
| `setFontSizePx(...)` | backend root | true leaf contract | backend root | keep |
| `deriveFrameLayout(...)` | backend root | backend-local layout fact | backend root | keep |
| `targetTexture(...)` | backend root | true leaf contract | backend root | keep |
| `textProvider(...)` | backend root | provider access contract | backend root | keep |
| `fontSession(...)` | backend root | provider access contract | backend root | keep |
| `capabilities(...)` | backend root | true backend capability fact | backend root | keep |

Notes:

- `submitFrame(...)`, `uploadTextSceneRaster(...)`, and `renderTextScene(...)` are not sacred names.
  They are deletion/replacement targets.
- if the reduced backend contract needs different names, choose names that describe leaf work, not
  pipeline ownership
- any backend-root function not listed here must be classified during Checkpoint 2 before it can be
  preserved

## Explicit Landing Owners

When a surface moves, the landing owner is not negotiable:

- text cell analysis, clustering, resolve, shape, grouping, scene assembly, and raster planning land
  in `Render.Text`
- staged prepare/submit orchestration lands in `Renderer`
- retained publication transitions and queue consequences stay in `RenderRuntime`
- geometry derivation lives in `Render`
- backend capability facts stay in the backend root
- GPU uploads, atlas mutation tied to the backend's actual texture objects, and draw submission stay
  in the backend root or its backend-local internal files
- renderer-visible metrics and surface/result observability land in renderer-owned frame records or
  runtime metric records, not in backend convenience getters

## Parity Definition

"GL/GLES parity" is explicit for this sprint. It does not mean matching internals. It means:

- the same renderer-owned step order: analyze -> prepare runtime -> upload leaf work -> submit leaf
  work -> accept submitted -> present
- the same host-visible retained runtime consequences for the same input frame sequence
- the same public ABI behavior through `howl_render_*`
- the same renderer-visible metrics shape for equivalent outcomes
- the same benchmark surface names and proof surfaces
- no backend-specific policy fork that changes damage semantics, retained-publication semantics, or
  text correctness without an explicitly documented backend capability reason

## Exit Artifacts

Every checkpoint must leave a durable artifact, not only code motion:

- Checkpoint 1: architecture contract lock in docs
- Checkpoint 2: committed backend inventory table with every root surface classified and assigned a
  final status
- Checkpoint 3: committed renderer-owned sequencing with backend contract reduced in actual code
- Checkpoint 4: committed backend-root collapse with deleted/replaced policy surfaces and tests moved
  to the right owner seams
- Checkpoint 5: committed proof result in docs stating the closed architecture and parity outcome

## Milestone-to-Checkpoint Decomposition

Each checkpoint exists so code review can stay narrow and exact.

## Checkpoints

### Checkpoint 1

Milestone: 1

Theme: contract lock.

Intent:

- make the architecture statement impossible to misread
- lock the anti-preservation rule before code moves

Engineer may change:

- `design.md`
- `architecture-sprint.md`

Engineer may not change:

- runtime code
- backend code
- tests

Closure artifact:

- docs state the owner model, move targets, and review-fail rule exactly

Assigned files:

- `design.md`
- `architecture-sprint.md`

Must do:

- rewrite render design facts so backend layers are explicitly leaf wrappers only
- name every current backend-root surface that is a deletion or move target
- lock the review rule that preserving the backwards contract shape fails review
- remove wording that treats the current staged backend contract as acceptable architecture

Contract lock for this checkpoint:

- the authoritative architecture statement lives in `design.md`
- backend roots are not partial renderers
- backend roots are not acceptable owners for text analysis, raster planning, retained-frame sequencing, or one-shot render policy
- preserving the current backwards contract shape for convenience or compatibility fails review
- this checkpoint does not change the shipped ABI surface

### Checkpoint 2

Milestone: 1

Theme: backend contract inventory.

Intent:

- remove guesswork about what survives the rewrite
- classify all backend-root public surfaces before implementation starts

Assigned files:

- `src/renderer.zig`
- `src/backend/gl/backend.zig`
- `src/backend/gles/backend.zig`

Must do:

- inventory every backend-root function and classify it as:
  - true backend leaf contract
  - renderer-owned orchestration that must move up
  - text/render policy that must move out
- classify every unlisted backend-root public function too; nothing survives by omission
- write the classification into this sprint doc as a committed inventory artifact
- name the destination owner and final status for every classified surface
- do not move code yet unless required to make the inventory truthful

Checkpoint 2 closes only when:

- the inventory table in this document is complete for GL and GLES backend roots
- every surviving backend-root public function has an owner-true reason to exist
- no reviewer needs to infer destination ownership from prose

### Checkpoint 3A

Milestone: 2

Theme: renderer sequencing design lock.

Intent:

- define the renderer-owned step order in code terms before broad rewrites start
- lock where prepared-frame state, submitted-frame state, and runtime transitions live

Assigned files:

- `src/renderer.zig`
- `src/render.zig`
- `design.md` if wording must sharpen to stay truthful

Must do:

- name the exact renderer-owned steps that replace backend `prepareFrame(...)` and `submitFrame(...)`
- name the frame records that will own observability after backend getters are removed
- define the reduced backend calls the renderer will make

Checkpoint 3A closes only when:

- the reduced sequencing is explicit enough that implementation can proceed without guessing
- the destination owner for each moved responsibility is named in code-facing terms

### Checkpoint 3B

Milestone: 2

Theme: renderer orchestration reclaim.

Assigned files:

- `src/renderer.zig`
- `src/render.zig`
- `src/text/engine.zig`

Must do:

- move staged render orchestration out of backend roots into renderer/render owners
- make renderer consume a smaller backend contract
- keep runtime and prepared-frame ownership explicit and singular
- move renderer-visible observability out of backend convenience getters
- do not preserve one-shot whole-pipeline entrypoints while staged sequencing is reclaimed

Checkpoint 3B closes only when:

- `Renderer.prepareFrame(...)` no longer delegates whole staged ownership into backend `prepareFrame(...)`
- `Renderer.submitFrame(...)` no longer depends on backend-owned frame record semantics
- renderer-owned records now hold the observability that used to leak through backend getters
- runtime transitions remain explicit and bounded in one owner path

### Checkpoint 3C

Milestone: 2

Theme: renderer observability reclaim.

Intent:

- remove backend-owned observability getters from the active renderer path
- prove metrics and frame-result reporting now live with the true owner

Assigned files:

- `src/renderer.zig`
- `src/render.zig`
- backend roots only if temporary reads must be deleted in the same checkpoint

Must do:

- move `resolveCounters()`, `surfaceHandle()`, and `lastResolveStage()` consequences into renderer-owned records or runtime records
- delete any renderer dependency that still requires backend convenience observability

Checkpoint 3C closes only when:

- renderer-visible observability no longer depends on backend convenience getters
- frame records and runtime records carry the surviving observability truth

### Checkpoint 4A

Milestone: 3

Theme: backend public-surface reduction.

Intent:

- delete or replace public backend surfaces that violate ownership
- leave a smaller public contract before deeper internal cleanup

Assigned files:

- `src/backend/gl/backend.zig`
- `src/backend/gles/backend.zig`
- backend tests that must move with the public-surface change

Must do:

- remove backend-owned text analysis entrypoints
- remove one-shot render-policy entrypoints
- remove backend-local `deriveGrid*` passthroughs
- rename surviving upload/draw calls if needed so names describe leaf work only

Checkpoint 4A closes only when:

- backend roots expose only surviving or replacement leaf primitives
- no backend public surface still implies pipeline ownership

### Checkpoint 4B

Milestone: 3

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
- move or rewrite backend-root tests that currently prove the wrong owner shape
- delete convenience passthrough geometry surfaces from backend roots

Checkpoint 4B closes only when:

- backend roots no longer export text-analysis entrypoints
- backend roots no longer export one-shot render-policy surfaces
- backend roots no longer export backend-local `deriveGrid*` convenience surfaces
- remaining backend-root public functions all fit the target backend contract above
- GL and GLES still close on equivalent renderer-owned sequencing

### Checkpoint 4C

Milestone: 3

Theme: backend test relocation and truth cleanup.

Intent:

- stop tests from proving deleted architecture
- move proofs to the owner seams that now matter

Assigned files:

- `src/backend/gl/tests.zig`
- `src/backend/gles/tests.zig`
- renderer or render tests that absorb the moved proofs

Must do:

- delete tests that exist only for deleted backend-owned pipeline surfaces
- rewrite tests to prove surviving backend leaf work or renderer-owned sequencing

Checkpoint 4C closes only when:

- no backend test asserts the deleted owner model
- moved tests prove the new owner model at the correct seam

### Checkpoint 5A

Milestone: 4

Theme: repo proof and parity proof.

Intent:

- prove the render repo closes on the reduced architecture before host closure

Assigned files:

- `src/test/runtime_proof.zig`
- `src/test/render_benchmark.zig`
- any render-side proof files needed for parity closure

Must do:

- update runtime proof to the renderer-owned sequencing
- update benchmark/test names that still encode the deleted backend contract
- state parity outcomes against the explicit parity definition in this document

Checkpoint 5A closes only when:

- repo proof closes on the reduced architecture
- parity proof is explicit, not implied

### Checkpoint 5B

Milestone: 4

Theme: host proof and doc closure.

Assigned files:

- `src/test/runtime_proof.zig`
- `src/test/render_benchmark.zig`
- `howl-linux-host/src/terminal/api.zig` if host seam needs adjustment

Must do:

- prove renderer/backends still close on the owned host path
- prove GL/GLES parity on the reduced contract
- update docs to state the closed architecture result
- record what was deleted, what was replaced, and what survived because it was a true leaf contract

Checkpoint 5B closes only when:

- host proof closes on the owned ABI path
- parity proof is stated against the explicit parity definition above
- benchmark/test names no longer reflect the deleted staged backend contract
- docs make the final owner model impossible to misread

## Reachability Rules

Every checkpoint must be reachable in one engineering pass.

- assign only the files that must move together
- do not mix doc-only truth cleanup with broad code rewrites unless the code depends on it
- do not open the next checkpoint until the active one is accepted, committed, and pushed
- if a checkpoint grows beyond one clear reviewable theme, split it before engineering starts

## Handoff Questions

Before an engineer starts any checkpoint, they must be able to answer:

- Which file is the true owner of the control spine touched here?
- Which surfaces are being deleted, and which are true survivors?
- What behavior proof closes this checkpoint?
- What style gate closes this checkpoint?
- What exact diff shape would make this checkpoint fail review?

If any answer is unclear, stop with `work-not-clear`.

## Proof Gates

Each checkpoint must close with all of the following:

- `zig build test` in `howl-render`
- `zig build test:render` in `howl-render`
- `nu "./style.nu" --touched-files --json`
- `nu "./style.nu" --failures --json`
- `git diff --check`
- when host seam changes, `zig build` in `howl-linux-host`
- when host behavior changes, `zig build run` in `howl-linux-host` if feasible

Proof must be reported with exact pass/fail results, not implied.

## Review Gates

A checkpoint fails review if it does any of the following:

- preserves backend-owned render policy because it is convenient
- preserves slow or owner-wrong code because rewriting it feels risky
- keeps text analysis entrypoints on backend roots
- keeps one-shot render-policy surfaces on backend roots
- adds another wrapper layer between renderer and backend
- keeps backend convenience getters for renderer-owned observability
- leaves backend-root tests proving a contract that the sprint is deleting
- leaves ownership unclear between render contracts, text policy, backend leaf operations, and FFI
- closes without proof on GL/GLES parity or the owned host path when those seams changed

## Execution Bias

This sprint should prefer deletion over negotiation with bad structure.

- if a path is both slow and owner-wrong, delete or rewrite it in the owner that should have existed
  all along
- if a backend API exists only to make renderer sequencing easy to hide, delete it
- if a test proves the wrong architecture, move or rewrite the test instead of preserving the
  architecture
- if a helper name makes pipeline ownership ambiguous, rename it before the ambiguity spreads
