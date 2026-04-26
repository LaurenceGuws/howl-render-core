# Render Plan Contract

## Summary

`RenderPlan` is the backend-neutral draw command set that `howl-render-core` produces and
render backends consume. It is the single hand-off artifact between the planning layer and
execution layer. Backends must not modify its semantics or produce alternate interpretations.

## Ownership

| Concern | Owner | Not owned by |
| --- | --- | --- |
| Plan shape and versioning | `howl-render-core` | backends, host, surface |
| Fill-rect policy (which cells, which colors) | `howl-render-core` | backends |
| Glyph placement policy (which atlas slot, which cell) | `howl-render-core` | backends |
| Atlas upload policy (which slots need upload, when) | `howl-render-core` | backends |
| Text batching policy (grouping, ordering) | `howl-render-core` | backends |
| Cursor draw policy (shape, position, color) | `howl-render-core` | backends |
| GPU/CPU resource binding (textures, buffers, shaders) | backend | `howl-render-core` |
| Draw call submission order within plan execution | backend | `howl-render-core` |
| Atlas texture storage and upload execution | backend | `howl-render-core` |

## Plan Input Source

`RenderPlan` inputs come from the surface frame model:
- `surface_px`: pixel dimensions of the drawable surface (from surface/host)
- `cell_px`: pixel dimensions of one terminal cell (from font/cell configuration)
- `grid`: terminal grid size in cell units (from session/surface state)
- `frame_theme`: render-core-owned color/default policy input chosen by the composition layer

Host and surface provide these inputs. They do not construct or interpret the plan's command
lists (`fills`, `glyphs`, `atlas_uploads`, `cursor`).

`frame_theme` is explicit planner input. Render-core owns how default colors, indexed colors,
RGB colors, and cursor colors are resolved into backend-neutral `Rgba8` values. The host may
select a named theme/profile, but it must not duplicate color resolution logic.

## Atlas Policy

Atlas policy is `howl-render-core`-owned. Render-core decides:
- which glyph raster is assigned which atlas slot
- which slots require upload on a given frame
- what slot identifier backends use when submitting draw commands

Backends allocate and manage the atlas texture resource, but slot assignment and upload
scheduling are exclusively core-owned.

The glyph-side contract is defined in `TEXT_GLYPH_CONTRACT.md`. That document captures the
real text-path handoff between glyph planning, atlas upload scheduling, and backend execution.

## Text Batching Policy

Text batching policy is `howl-render-core`-owned. Render-core decides:
- how glyph quads are grouped into the `glyphs` list
- the ordering of glyph draw commands relative to fill-rect commands
- which text runs share atlas slots

Backends execute the ordered `glyphs` list as-is. They must not reorder or re-batch glyph
commands.

## Host and Surface Visibility

| Permitted | Forbidden |
| --- | --- |
| Surface provides `surface_px`, `cell_px`, `grid` inputs to the planner | Surface inspects `fills`, `glyphs`, `atlas_uploads` lists |
| Host presents the frame after backend execution | Host inspects backend draw call internals |
| Host receives renderer failure signals | Host modifies plan before execution |

Host and surface are opaque to the contents of a `RenderPlan`. They hand off frame geometry
inputs and receive rendered output. The plan's command lists are exclusively a render-core
→ backend interface.

## Lifecycle Position

`RenderPlan` is produced per-frame. It is valid for exactly one backend execution call. Plans
are not cached, accumulated, or shared across frames by design. Incremental update and damage
tracking are core-owned policies expressed in the plan structure (not backend state).
