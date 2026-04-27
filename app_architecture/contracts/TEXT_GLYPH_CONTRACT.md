# Text Glyph Contract

## Summary

This contract closes the first real text-path API for `howl-render-core`.
It defines what the planner emits, what the backend must execute, and which responsibilities
stay on each side of the boundary.

The split is strict:

- `howl-render-core` owns glyph selection, glyph batching, atlas slot assignment, and upload
  scheduling.
- The backend owns texture allocation, atlas upload execution, and glyph quad submission.

## Glyph Plan Semantics

`RenderPlan.glyphs` is an ordered list of real glyph draw commands.

Each glyph quad represents one visible glyph at one terminal-cell origin. The quad is not a
color block and it is not a generic rectangle. Backends must interpret it as a glyph draw
instruction that samples an atlas entry and applies the quad tinting/color information.

The planner is responsible for:

- choosing which visible cells become glyph quads
- assigning the atlas slot for each glyph raster
- preserving command order
- omitting glyph quads for non-drawable cells such as spaces and continuations

The backend is responsible for:

- honoring the planned destination geometry
- binding the atlas slot referenced by the quad
- drawing the glyph as glyph content, not as a full-cell fill

## Atlas Upload Semantics

`RenderPlan.atlas_uploads` is the ordered list of glyph raster uploads required to execute the
glyph quads in the same plan.

Each upload entry is a backend upload directive, not a backend policy decision.

Render-core decides:

- which glyph raster needs an upload
- which slot that raster occupies
- when a slot must be refreshed

The backend decides:

- how atlas storage is allocated
- how the upload is marshalled into GPU or CPU memory
- how the slot is made visible to later glyph draws

An upload entry must describe real glyph content. It must identify the glyph raster that will
occupy the slot and the slot itself. Empty or placeholder upload records are not acceptable as
the contract for real glyph execution.

## Capacity Gate

Render-core receives backend capability as an explicit planning input. The planner must never
emit glyph quads or atlas uploads that exceed `max_atlas_slots`.

The overflow rule is deterministic:

- unique glyph rasters are assigned slots in first-seen row-major order starting at slot `0`
- repeated codepoints reuse the slot already assigned to that codepoint
- once slot budget is exhausted, any new codepoint is dropped for the rest of the frame

This means a frame can still contain glyph quads after capacity is reached if those quads reuse
already assigned slots. What it cannot do is introduce a new slot beyond the backend limit.

## Placeholder vs Real Execution

Placeholder glyph execution is a transitional implementation detail, not a supported contract
state.

- If a backend cannot execute glyph quads as glyphs, it must declare
  `supports_glyph_quads: false`.
- If a backend declares `supports_glyph_quads: true`, it must execute glyph quads using glyph
  sampling from atlas content.
- A backend may not claim glyph support while rendering glyph quads as filled cell rectangles,
  color blocks, or other alternate interpretations.

Render-core may still produce plans that contain no glyph quads for textless frames. That is
normal. What is not allowed is a backend treating a glyph quad as something other than a glyph
quad.

## Backend Data Requirements

To draw glyphs truthfully, a backend needs the following data from the plan:

- destination geometry for each glyph quad
- the atlas slot identifier for the glyph raster
- the glyph tint color
- atlas upload entries that name the real glyph raster behind the slot

The backend also needs its own texture state and upload execution machinery. That machinery is
backend-owned and stays out of render-core.

## Ownership Boundary

| Concern | Owner |
| --- | --- |
| glyph selection | `howl-render-core` |
| glyph batching and ordering | `howl-render-core` |
| atlas slot assignment | `howl-render-core` |
| atlas upload scheduling | `howl-render-core` |
| texture allocation | backend |
| atlas upload execution | backend |
| glyph quad submission | backend |
| alternate execution interpretations | neither |
