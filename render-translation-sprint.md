# Render Translation Sprint

Owner: `howl-render`.

Purpose: lock the render backend cleanup order before more code motion.

## Goal

Treat render as a deterministic translation pipeline, not a bag of graphics logic.

Input:
- VT surface truth
- damage truth
- frame layout truth
- text/font configuration

Output:
- draw plans
- raster upload plans
- surface damage plans
- submit feedback requirements

## Proven Paths

Freeze these unless proof forces a move:
- shaping path that already behaves correctly
- plain ASCII path that already behaves correctly
- current frame-layout derivation contract

Do not reopen these for cleanup theater.

## Owner Rules

- `ffi.zig` translates contracts only.
- `frame/*` owns frame-level geometry, input shaping into render input, surface execution, and submit-facing contracts.
- `text/*` owns text translation from render input to scene, raster requests, and atlas consequences.
- Generated special glyph raster logic stays owned by `text/special_raster.zig` unless a smaller true owner appears.
- Public roots curate exports only.

## Translation Stages

Stage 1: frame input normalization.
- Owner: `frame/input.zig`
- Job: convert VT surface/config/damage into render input slices and metrics.

Stage 2: cell classification.
- Owner target: `text/*`
- Job: classify each cell into fast ASCII, direct normal glyph, complex shaping, generated special sprite, decoration-only, or empty.
- This is the render equivalent of parser state classification.

Stage 3: cluster and run extraction.
- Owner: `text/cluster.zig`, `text/grouping.zig`, `text/shape_run.zig`
- Job: turn classified cells into text runs, complex groups, fallback requests, and missing glyph consequences.

Stage 4: scene assembly.
- Owner: `text/scene.zig`
- Job: convert classified cells and grouped glyph output into draw lists and raster requests.

Stage 5: raster production.
- Owner: `text/rasterizer.zig`, `text/special_raster.zig`
- Job: produce sprite pixel data and raster metadata.

Stage 6: atlas and prepared surface assembly.
- Owner: `text/frame_preparer.zig`, `frame/surface.zig`
- Job: combine scene, raster uploads, and damage policy into prepared surface state.

Stage 7: FFI export and submit.
- Owner: `ffi.zig`, `frame/surface.zig`
- Job: translate prepared state to C ABI and accept submit feedback.

## First Checkpoint

First checkpoint is not all of render.

First checkpoint:
- make `ffi.zig` translation-only
- move owner state and mutation out of `ffi.zig`
- keep public C ABI shape unchanged unless proof forces a change

Why this checkpoint first:
- it is the clearest style violation
- it does not require reopening proven shaping or ASCII behavior
- it sharpens the owner map before any table-driven translation rewrite

## First Table-Driven Checkpoint

After `ffi.zig` is translation-only, start table-driven cleanup at cell classification.

Target:
- replace branch mazes that decide between ASCII, normal glyph, complex shaping, generated special, and decoration behavior
- do this with explicit classification enums and small direct dispatch tables

Do not start with:
- giant generic metadata tables
- callback-heavy frameworks
- a fake parser engine

## Stop Rules

Stop and mark `work-not-clear` if:
- a proposed split would create a new umbrella layer
- an FFI convenience type starts owning render state again
- shaping or ASCII proof is no longer isolated from cleanup work
- a table proposal hides owner truth instead of clarifying it

## Proof Gates

- `zig build` in `howl-render`
- `zig build test` in `howl-render`
- touched-file review against `design/style-law.md`
- preserve current host proof in `howl-linux-host` when ABI-affecting seams move
