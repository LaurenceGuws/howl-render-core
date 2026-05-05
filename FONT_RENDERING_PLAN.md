# Howl Text Rendering Maturity Plan

## Purpose
Push Howl's text stack from a basic monospace/codepoint renderer toward a kitty-class terminal text subsystem.

The immediate goal is pixel-faithful rendering of real glyphs from modern monospace and Nerd Font stacks, including edge-case characters. This is not primarily a UI/data-model exercise: it is about making the font engine choose the right face, shape the right glyphs, place them on the right baseline, rasterize them with the right FreeType/HarfBuzz settings, and cache/upload them without degrading quality.

This document is intentionally grounded in the current Howl implementation and in the local kitty reference under:
- `/home/home/personal/zide/dev_references/terminals/kitty/kitty/fonts.c`
- `/home/home/personal/zide/dev_references/terminals/kitty/kitty/fonts.h`
- `/home/home/personal/zide/dev_references/terminals/kitty/kitty/glyph-cache.c`
- `/home/home/personal/zide/dev_references/terminals/kitty/kitty/text-cache.c`
- `/home/home/personal/zide/dev_references/terminals/kitty/kitty_tests/fonts.py`

## Current Howl State
Howl currently has the beginning of a text contract, but the real implementation is still fundamentally cell/codepoint based.

Already present:
- `howl-render-core/src/text_contract.zig` defines placeholder contract types such as `TextCluster`, `ShapedRun`, `ShapedGlyph`, `FontMetrics`, and `CellMetrics`.
- `howl-render-core/src/text_pipeline.zig` defines resolver/shaper/raster operation shapes and counters.
- `RenderGl` and `RenderGles` link FreeType and HarfBuzz and rasterize glyph bitmaps into an atlas.
- Hosts can configure primary and fallback font paths.
- Render-core owns some shared special glyph classification and procedural box/block rendering.

Important gaps:
- HarfBuzz is currently used as a single-codepoint glyph-id helper, not as a run shaper.
- Render batches still carry one `codepoint` per glyph quad; atlas identity is codepoint + cell size, not face/glyph/features/scale/presentation.
- The VT-to-render snapshot emits cells, not kitty-like cell text clusters.
- Fallback is a linear configured-path retry, not a validated resolver keyed by text, style, and presentation.
- GL and GLES duplicate text placement/raster logic and diverge in baseline/origin behavior.
- There is no shaped-run cache, text cache, glyph property cache, or sprite-position cache.
- Combining marks, emoji presentation, ZWJ sequences, ligatures, PUA+space powerline behavior, and wide/multicell grouping are not first-class.
- Decorations are simple cell rectangles, not font-metric/sprite-integrated text decorations.

The architectural problem is not just that pieces are missing. The ownership is wrong.

Today the backend still owns too much of the text engine:
- font resolution
- fallback resolution
- glyph shaping decisions
- glyph rasterization policy
- atlas identity policy

That is fine for an intentionally immature bootstrap renderer, but it is not a viable mature architecture.

The renderer backend should not be the text engine.

## Kitty Ideology To Adopt
Kitty's text subsystem is not just "FT + HB". The important design is the ordering and ownership of decisions.

Kitty does effectively have a mature, mostly self-contained text/font engine, but it is not loosely coupled in the sense of being terminal-agnostic. It is tightly aware of terminal cells, multicell glyphs, ligatures, symbol routes, fallback validation, decoration geometry, and sprite atlas identity. The engine is isolated behind font/text APIs, while still modeling terminal-specific text realities explicitly.

Adopt these principles strictly:
- Text rendering is a line/run problem, not a per-codepoint problem.
- Cell text is a compact semantic payload that can contain multiple codepoints.
- Font selection happens per cell text, style, presentation, and symbol class before shaping runs.
- HarfBuzz shapes runs; cluster numbers are then reconciled back to terminal cells.
- Glyph groups are the unit of sprite caching, because ligatures and combining marks can span a different number of glyphs and cells.
- Box/block/braille/powerline/symbol drawing is a dedicated sprite route, not an accidental font fallback path.
- Cell metrics, baseline, underline position, and strikethrough position are central policy derived from the selected primary face.
- Fallback font choices are validated by glyph coverage for the whole cell text, not by trusting OS discovery blindly.
- Missing glyphs are explicit, countable, and testable.

For Howl, copy that shape: keep font quality inside render backends/render-core contracts, but let that engine understand terminal cells deeply enough to render actual glyphs correctly.

## Kitty Behaviors That Matter
From the local kitty reference:
- `FontGroup` owns faces, fallback fonts, fallback maps, scaled font metrics, sprite positions, and decorations.
- `TextCache` interns multi-codepoint cell text and maps compact cell ids back to codepoint lists.
- `font_for_cell()` chooses among blank, box/sprite, exact style face, symbol-map face, emoji-presentation fallback, discovery fallback, or missing glyph.
- `has_cell_text()` validates that the chosen face can render the whole cell text, accounting for non-rendered codepoints and composed combining characters.
- `shape_run()` shapes contiguous compatible cells with HarfBuzz, then groups glyphs back into terminal cell spans.
- `group_normal()` handles combining marks, wide glyphs, finite ligatures, empty spacer glyphs, and variable-length ligatures.
- `render_groups()` and `render_group()` rasterize shaped groups into per-cell sprites.
- `glyph-cache.c` keys sprite positions by glyph sequence, ligature index, cell count, scale, subscale, multicell row, and alignment.
- `fonts.py` tests sprite map allocation, box drawing sprites, scaled multicells, combining marks, wide CJK, emoji presentation, ligature grouping, fallback behavior, and symbol-map coalescing.

## Architecture Cut
The redesign boundary is simple:

- current Howl model: `cell -> codepoint -> atlas slot -> draw`
- target mature model: `cells -> cell text -> resolved font runs -> shaped glyph runs -> glyph groups -> sprite cache -> atlas -> draw`

The new text stack must be a first-class engine layer, not a thin helper around backend code.

### Target Pipeline
1. VT/frame cells enter render-core as terminal-aware cell payloads.
2. A text engine extracts `CellText` and grapheme clusters from cells.
3. A font resolver selects primary/style/symbol/fallback faces for compatible runs.
4. HarfBuzz shapes full runs, not individual codepoints.
5. A grouping stage maps shaped glyphs back to terminal cell spans.
6. A sprite-key stage identifies reusable rendered glyph groups.
7. A raster service produces sprite bitmaps and metrics.
8. Atlas/cache services ensure residency.
9. Backend uploads sprites and draws quads only.

This is the essential maturity move.

## Target Ownership
Keep Howl boundaries, but move text semantics into a real text engine layer inside render-core.

`howl-vt-core` owns:
- cell text semantics: codepoints, width/continuation, grapheme/multicodepoint cell content where terminal semantics require it
- Unicode width/presentation behavior that affects cursor movement and wrapping

`howl-term` owns:
- converting VT snapshots into render surface cells
- no FreeType/HarfBuzz/font discovery logic

`howl-render-core` owns:
- stable text contract types
- shared resolver order
- shared line/run/group/sprite data vocabulary
- shared special glyph classification and procedural sprite contracts
- shared metrics contract and test fixtures
- text engine orchestration
- cell text extraction and line/run construction
- font/session vocabulary
- sprite key vocabulary
- grouping semantics that map shaped glyphs back to terminal cells

`RenderGl` / `RenderGles` own:
- FreeType/HarfBuzz/font discovery integration hooks for the render-core text engine
- concrete face lifetime wiring where platform/backend specific
- concrete glyph rasterization backend hooks
- atlas texture storage, eviction, and upload
- final draw submission

Linux-host owns:
- user config input only: font family/path lists, size, features, fallback policy knobs
- no shaping, no fallback decisions, no Unicode text policy

## Required Data Model Upgrade
Current `SurfaceCell.codepoint` is not enough. Move toward a kitty-like cell text model.

Add render-core vocabulary:
- `CellTextId`: compact reference to one cell's codepoint sequence.
- `CellText`: one or more Unicode scalar values plus cached first codepoint.
- `LineTextCache`: per-frame or retained interner for repeated cell text.
- `RenderableCell`: cell text id, style, colors, width/span/continuation flags, link metadata.
- `RunFont`: resolved face id plus scale/subscale/alignment/multicell row.
- `TextRun`: contiguous cells with identical `RunFont` and compatible styling/features.
- `GlyphGroup`: shaped glyph slice mapped to one or more terminal cells.
- `SpriteKey`: face id, glyph sequence, ligature index, cell count, scale/subscale/alignment, presentation, feature set.
- `SpritePosition`: atlas slot plus colored/alpha metadata.

Also add explicit engine output vocabulary:
- `TextScene`: renderer-neutral text output for one frame or dirty line set.
- `TextSpriteDraw`: final positioned sprite draw with atlas residency info.
- `ResolvedRun`: a run with fully chosen face/style/presentation/features.
- `GlyphInstance`: one shaped glyph with cluster and placement data.

Do not try to solve this by adding more fields to `GlyphQuad`. `GlyphQuad` should become the final GPU submission result, not the text decision input.

## Proposed Module Layout
Build the mature stack in `howl-render-core/src/text_stack/`.

New modules:
- `engine.zig`: orchestrates the full text pipeline.
- `font_session.zig`: Howl equivalent of kitty's `FontGroup`; owns primary/style/fallback/symbol faces and metrics caches.
- `font_resolver.zig`: resolves exact style faces, symbol-map routes, fallback faces, and presentation-specific faces.
- `cluster.zig`: extracts grapheme/cell text payloads from terminal cells.
- `shape_run.zig`: shapes full runs with HarfBuzz and emits glyph instances.
- `grouping.zig`: maps shaped glyphs back to terminal cell groups, handling ligatures, combining marks, wide glyphs, and special empty followers.
- `sprite_key.zig`: defines stable cache identity for rendered glyph groups.
- `rasterizer.zig`: rasterizes glyph groups into alpha/color sprites with full metrics.
- `scene.zig`: renderer-neutral text scene output for the backend.
- `atlas_cache.zig`: backend-neutral atlas residency bookkeeping and lookup vocabulary.
- `symbol_map.zig`: explicit symbol/icon/nerd-font routing.
- `metrics.zig`: shared baseline, overhang, underline, and line metric policy.

Existing placeholder modules should either be expanded into these real responsibilities or replaced by them.

## Backend Boundary Rules
After the redesign, backends must not own text semantics.

Backends may own:
- concrete FT/HB object wiring
- platform/library specific font discovery hooks
- bitmap upload to GPU textures
- atlas texture allocation and eviction policy
- final draw submission

Backends must not own:
- resolver order semantics
- ligature grouping semantics
- cluster-to-cell reconciliation
- sprite cache identity policy
- primary text engine orchestration
- shared metrics policy

If a text behavior matters for correctness, it belongs in render-core text-stack policy, not duplicated in GL and GLES.

## Quality Targets
This sprint is not just for cold-path performance. It is for raising the architecture and quality floor.

Non-negotiable target:
- If a configured primary or fallback font contains the glyph, Howl should render that actual glyph, not a placeholder or procedural approximation unless the codepoint is deliberately routed to a procedural sprite.

Architectural non-negotiables:
- Text shaping happens on runs, not single codepoints.
- Cache identity is based on rendered glyph groups, not codepoints.
- Ligatures, combining marks, wide glyphs, and symbol routes are first-class model concepts.
- Mono and non-monospace fonts must go through the same engine.
- Nerd Font and icon rendering must be explicit and testable, not accidental fallback luck.

Immediate requirements:
- Resolve the correct face for regular/bold/italic/bold-italic instead of treating one face as the whole family.
- Validate glyph availability in the selected face before claiming a hit.
- Use HarfBuzz output glyph ids, not only `FT_Get_Char_Index`, for shaped text.
- Derive cell width, height, baseline, underline, and strikethrough positions from the primary face once, then use that policy in both GL and GLES.
- Use identical glyph bitmap placement in GL and GLES.
- Preserve glyph bitmap bearings and advances instead of forcing every bitmap into a naive cell rectangle.
- Distinguish alpha glyphs from colored glyphs and plan for COLR/CPAL/CBDT/SBIX emoji support.
- Key atlas entries by face id + glyph id + load/render target + size + presentation/style, not just codepoint + cell size.
- Keep procedural box/block routes intentional; do not use them to hide normal font-rendering failures.

Broader maturity targets:
- mono and non-monospace font correctness
- pixel-faithful nerd font icon rendering
- high-quality ligature support
- backend-light architecture
- kitty-level quality floor, but not kitty as the end goal

Modern Nerd Font cases to validate early:
- Powerline separators and branch symbols.
- Patched private-use glyphs followed by spaces.
- Symbols wider than one nominal cell.
- Fonts with ligature programming glyphs.
- Fallback from primary mono to symbol/emoji fallback without placeholder boxes.

## Resolver Order
Model kitty's resolver order, adapted to Howl names:
1. Blank cell route for empty, tab, and simple spaces with no required decoration.
2. Procedural sprite route for box drawing, block elements, braille, powerline, legacy computing, and configured symbol ranges.
3. Exact configured style face: regular/bold/italic/bold-italic.
4. Symbol-map override face for explicitly mapped ranges.
5. Validated primary-style retry when requested style is unavailable.
6. Configured fallback path list, validated against whole cell text.
7. System discovery fallback when enabled, validated against whole cell text.
8. Emoji-presentation fallback when VS16/default emoji presentation requires it.
9. Explicit missing glyph sprite and counter.

Validation rule:
- A resolver hit must prove the face can render the cell text, not just the first codepoint.

## Shaping Rules
Shape contiguous runs, not individual cells.

Required rules:
- Build runs from adjacent cells with identical resolved `RunFont`, compatible style/features, and compatible scale/alignment.
- Feed full run text to HarfBuzz.
- Preserve HarfBuzz cluster data.
- Reconcile glyph clusters back to terminal cells.
- Group combining marks into the base cell.
- Allow a wide glyph or emoji to consume multiple cells.
- Detect ligatures where glyph count differs from cell count.
- Keep cursor ligature suppression as a policy hook, even if disabled initially.
- Treat PUA+space powerline cases as a multicell glyph group where the following spaces inherit the PUA foreground.

First-class hard cases:
- `He\u0347\u0305llo\u0337,`
- `i\u0332\u0308`
- `你好,世界`
- `|\U0001F601|\U0001F64f|\U0001F63a|`
- `\u2716\u2716\ufe0f`
- `A===B!=C`, `----`, `==!=<>==<><><>` with FiraCode/Cascadia/Iosevka-like ligatures

## Metrics Rules
Centralize font metrics and use them everywhere.

Metrics contract:
- `FontMetrics`: ascender, descender, line gap, max advance, underline position/thickness, strikethrough position/thickness.
- `CellMetrics`: width, height, baseline, decoration regions.
- `ScaledCellMetrics`: derived for scaled/multicell rendering.

Rules:
- Derive cell metrics from the selected primary face.
- Apply user metric adjustments only through one render-core/renderer policy path.
- GL and GLES must use the same baseline/origin math.
- Cursor geometry must be derived from the same `CellMetrics` as glyph placement.
- Atlas slot dimensions must include any decoration/underline-exclusion row policy explicitly, if adopted.

## Atlas And Sprite Cache Rules
Current atlas slots are codepoint-sized; kitty-class rendering needs sprite keys.

Required changes:
- Atlas key is not codepoint. It is a `SpriteKey` derived from face, glyph ids, group/cell span, scale, presentation, features, and decoration state.
- Cache shaped glyph groups, not only rasterized codepoints.
- Support alpha sprites and colored sprites distinctly.
- Track fallback hits/misses, missing glyphs, shaped runs, shaped groups, raster uploads, cache hits, and cache evictions.
- Make eviction explicit. Ring overwrite is acceptable only as an initial policy if stale references cannot survive into a frame.

Preferred key philosophy:
- identity should describe the rendered result, not the source codepoint
- glyph sequence and cell grouping matter
- presentation/features/style matter
- proportional and multicell output must fit without inventing backend-local exceptions later

## Special Glyph Route
Do not regress the procedural path. Expand it deliberately.

Initial procedural coverage target:
- box drawing U+2500..U+257F
- block elements U+2580..U+259F
- braille U+2800..U+28FF
- powerline ranges U+E0A0..U+E0D7
- legacy computing symbols U+1FB00..U+1FBAE where practical

Rules:
- Procedural sprites must be tested as pixel masks, not only visually inspected.
- Procedural rendering remains optional per codepoint class only if font rendering is proven better.
- Box drawing should stay aligned to cell edges/centers and remain independent of font fallback quality.

## Configuration Model
Keep config product-shaped, not escape-sequence-shaped.

Future config should describe font policy:
- primary family/path
- regular/bold/italic/bold-italic faces or automatic style selection
- fallback families/paths
- symbol-map ranges
- font features
- hinting/load target/render target if exposed
- metric adjustments only if clearly needed

Avoid config for:
- per-codepoint hacks in host config
- persisted cell width/height as primary inputs
- host-owned fallback order

## Quality Gates
Add tests before large rewrites become hard to judge.

Unit/golden test groups:
- sprite atlas allocation and key stability
- cell metrics derivation and baseline invariants
- fallback resolver order and validation
- missing glyph accounting
- combining mark grouping
- wide CJK cell spans
- emoji presentation selectors VS15/VS16
- ZWJ emoji sequences
- ligature grouping for FiraCode/Cascadia/Iosevka-style behaviors
- PUA+space powerline multicell behavior
- procedural box/block/braille/powerline pixel masks
- GL/GLES contract parity tests using the same render-core fixtures

Manual validation corpus:
- shell prompt with Nerd Font/powerline symbols
- `btop`, `nvtop`, `nvim`
- Unicode stress line containing ASCII, combining marks, CJK, emoji, ZWJ, ligatures, braille, and box drawing

## Implementation Slices

### Progress Tracking

This section is the working checklist for the migration. Update it before moving between slices.

- Slice 0: Architecture Skeleton — mostly complete. The target module layout exists under `src/text_stack/`, public contract/pipeline vocabulary is expanded, and the legacy path still coexists.
- Slice 1: Cell Text And Run Vocabulary — partially complete. Render-core can intern legacy and rich cell text inputs and produce clusters/runs, and continuation cells now expand base-cell spans for the new text pipeline. VT/render conversion still does not preserve full rich terminal cell text end-to-end.
- Slice 2: Font Session And Resolver — partially complete. Provider-backed sessions and whole-cell validation exist, but style-family faces, symbol-map override faces, discovery fallback, and full resolver order are incomplete.
- Slice 3: Metrics And Placement Policy — functionally complete for the current architecture slice. Shared 26.6 face-metric to `CellMetrics`/baseline policy exists in `TextStack.Metrics`, GL/GLES cell-size and glyph baseline helpers consume it, shared decoration/cursor geometry helpers exist, bitmap bearing/baseline placement is centralized for GL/GLES raster paths, shaping/grouping/scene contracts carry explicit placement data, the legacy frame-to-batch path preserves underline/strikethrough into shared-geometry decoration fills, and the mature text-scene path now emits explicit decoration draws. Remaining correctness work is now mainly replacing stub placement/shaping with real HarfBuzz outputs in Slice 4.
- Slice 4: Real HarfBuzz Shaping — in progress. The shaping boundary now carries full `LineTextCache` data, and `RenderGl` has started whole-run HarfBuzz shaping with preserved glyph clusters/offsets/advances. Remaining work is broadening that shaping path across more cases and making grouping consume real HarfBuzz cluster behavior for ligatures, combining marks, and multicell glyphs.
- Slice 5: Glyph Grouping Back To Cells — in progress. Grouping now consumes real shaped cluster output enough to merge multiple glyphs that map back to the same originating cluster into one terminal group, infer a wider terminal span when HarfBuzz collapses multiple source clusters into a first-cluster ligature glyph, preserve continuation-derived wide cell spans through cluster extraction and default shaping, drop follow-on groups whose first cell is already covered by an earlier multicell group, expand powerline sprite routes across immediately-adjacent spacer cells so PUA+space prompt segments become one sprite group, and expose a default-disabled cursor ligature-suppression policy hook. Broader spacer policies and production cursor wiring are still pending.
- Slice 6: Sprite Keys, Rasterization, And Atlas Residency — forced single-path migration in progress. GL terminal frame rendering now always routes through `TextScene` (`renderFrameState` -> `renderFrameStateTextScene` -> `renderTextScene`), and the host render loop no longer has a retained `RenderBatch` fallback or `HOWL_TEXT_SCENE_RENDERER` switch. GL `renderBatch`, `prepareFrameState`, and `prepareRetainedFrameState` now panic if called so legacy path usage is loud. Sprite keys/positions, raster requests, raster plans, GL atlas upload from renderer-neutral `TextScene` plus raster outputs, multicell-aware GL atlas slot sizing for scene raster outputs, renderer-neutral `TextScene.background_draws` and `cursor_draws`, scene-build and engine-analysis cursor options, and shared frame-to-text-scene input conversion exist. Font-size changes now mark the viewport dirty so raster/sprite data is regenerated like Kitty's dirty-sprite-position flow. HarfBuzz shaping now uses monotone character clusters like Kitty, bitmap placement honors the requested scene baseline, and GL group rasterization now composites every glyph in the shaped group instead of only glyph 0. Still missing: Kitty-style group splitting around special/empty ligature glyphs, cache-generation invalidation, complete fallback/icon/emoji correctness, GLES parity, and deletion of lower-level legacy `RenderBatch/GlyphQuad` utilities after replacement coverage exists.
- Slice 7: Procedural And Symbol Route Maturity — partial scaffold only. Some route classification exists; pixel-mask coverage and explicit symbol/icon tests are still pending.
- Slice 8: Presentation, Emoji, And Advanced Font Behavior — partial scaffold only. VS15/VS16 detection exists, but color glyph output, emoji fallback, icon alignment, and proportional placement are pending.
- Slice 9: Diagnostics And Performance — not started beyond basic counters. Do not optimize bootstrap paths before the mature architecture is active.

Next planned work: finish any remaining spacer policy hooks and production cursor wiring, then move into Slice 6 production migration toward a single text-scene renderer path.

### Slice 0: Architecture Skeleton
Goal: create the real text-engine module layout and contracts without yet deleting the legacy codepoint path.

Tasks:
- Add `engine.zig`, `font_session.zig`, `font_resolver.zig`, `cluster.zig`, `shape_run.zig`, `grouping.zig`, `sprite_key.zig`, `rasterizer.zig`, `scene.zig`, `atlas_cache.zig`, `symbol_map.zig`, and `metrics.zig` under `text_stack/`.
- Expand `text_contract.zig` and `text_pipeline.zig` so they describe the real target model.
- Wire a parallel engine entrypoint that can coexist with the old path during migration.
- Mark `GlyphQuad` as final draw output only.

Exit criteria:
- The mature architecture exists in code as real modules and types.
- The migration no longer depends on backend-local ad hoc evolution.

### Slice 1: Cell Text And Run Vocabulary
Goal: replace codepoint-per-cell thinking with cell text and run models.

Tasks:
- Add `CellTextId`, `CellText`, `LineTextCache`, `RenderableCell`, `ResolvedRun`, `GlyphInstance`, and `GlyphGroup` vocabulary.
- Teach VT/render conversion to preserve richer cell text information.
- Add deterministic tests for cell text interning and run construction.

Exit criteria:
- Render-core can express a line of terminal text without collapsing it to one codepoint per draw glyph.

### Slice 2: Font Session And Resolver
Goal: create a kitty-like font session owner and remove resolver semantics from backend draw code.

Tasks:
- Introduce primary regular/bold/italic/bold-italic faces.
- Add fallback face registry and cache.
- Add symbol-map and nerd-font/icon routing.
- Define validated resolver order over whole cell text.
- Keep configured fallback before discovery fallback.

Exit criteria:
- Font selection is a first-class subsystem, not a backend miss path.

### Slice 3: Metrics And Placement Policy
Goal: one shared baseline and placement policy for all backends.

Tasks:
- Centralize `FontMetrics`, `CellMetrics`, and decoration geometry policy.
- Explicitly model baseline, overhang, underline, and strikethrough placement.
- Make GL and GLES consume the same placement output.

Exit criteria:
- Text placement correctness no longer depends on backend-local math.

### Slice 4: Real HarfBuzz Shaping
Goal: shape runs, not codepoints.

Tasks:
- Build contiguous compatible runs.
- Shape full runs with HarfBuzz.
- Preserve cluster data and glyph positions.
- Emit `GlyphInstance` arrays from shaping.

Exit criteria:
- Combining mark, CJK width, and basic ligature test cases shape through the new engine.

### Slice 5: Glyph Grouping Back To Cells
Goal: implement the terminal-specific part that mature terminals actually need.

Tasks:
- Map shaped glyphs back to terminal cell spans.
- Handle combining marks, wide glyphs, finite ligatures, empty spacer glyphs, and PUA+space powerline behavior.
- Keep cursor ligature suppression as a hook even if initially disabled.

Exit criteria:
- The engine can explain how shaped glyph output occupies terminal cells.

### Slice 6: Sprite Keys, Rasterization, And Atlas Residency
Goal: replace codepoint atlas identity with rendered-sprite identity.

Tasks:
- Introduce `SpriteKey` and `SpritePosition`.
- Rasterize glyph groups into sprites.
- Cache shaped/rasterized groups by rendered identity.
- Separate alpha and colored sprite flows.
- Move backends to atlas upload and draw only.

Exit criteria:
- Cache identity is no longer codepoint-based.
- Backend text correctness no longer depends on backend-local fallback/shaping logic.

### Slice 7: Procedural And Symbol Route Maturity
Goal: make special glyph handling a deliberate peer path.

Tasks:
- Expand procedural box/block/braille/powerline coverage.
- Route procedural sprites through the same sprite cache and atlas shape.
- Add explicit symbol/icon routing tests.

Exit criteria:
- Special glyph handling is explicit, deterministic, and integrated.

### Slice 8: Presentation, Emoji, And Advanced Font Behavior
Goal: make presentation and richer font behavior first-class.

Tasks:
- Handle VS15/VS16, emoji/text presentation, and colored glyph output.
- Prepare for variable fonts and non-monospace faces through the same engine.
- Validate nerd fonts, icon alignment, and proportional placement.

Exit criteria:
- Text-vs-emoji presentation and icon rendering are explicit and correct.

### Slice 9: Diagnostics And Performance
Goal: optimize the mature architecture only after it exists.

Tasks:
- Add shaped-run cache.
- Add sprite-position cache.
- Add atlas batching/eviction policy improvements.
- Add counters and trace points for resolver, shaping, grouping, raster, upload, and cache behavior.

Exit criteria:
- Performance work is done on the mature engine, not on bootstrap architecture.

## First Recommended Work
Start with Slice 0.

Reason:
- The current problem is architectural immaturity, not isolated renderer inefficiency.
- We need the target engine shape present in the codebase before optimizing or migrating behavior.
- This creates a clean path to move correctness out of backend-local scaffolding and into a real text engine.

Do not start by tuning the current backend-owned path as if it were the final design. Build the mature engine boundary first, then migrate behavior into it slice by slice.
