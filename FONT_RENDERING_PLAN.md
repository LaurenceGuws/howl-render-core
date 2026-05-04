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
Howl currently has the beginning of a text contract, but the renderer is still fundamentally cell/codepoint based.

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

## Target Ownership
Keep Howl boundaries, but make the renderer own text quality.

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

`RenderGl` / `RenderGles` own:
- FreeType/HarfBuzz/font discovery wiring
- face lifetime and fallback loading
- shaped run execution
- glyph/sprite rasterization
- atlas storage, eviction, and upload

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

Do not try to solve this by adding more fields to `GlyphQuad`. `GlyphQuad` should become the final GPU submission result, not the text decision input.

## Pixel Fidelity Track
This is the first practical track. It can start before the full line/run/group model is complete.

Non-negotiable target:
- If a configured primary or fallback font contains the glyph, Howl should render that actual glyph, not a placeholder or procedural approximation unless the codepoint is deliberately routed to a procedural sprite.

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

### Slice 0: Pixel-Fidelity Baseline
Goal: make current code render actual glyphs from configured primary/fallback fonts consistently.

Tasks:
- Unify GL/GLES FreeType metrics, baseline, and bitmap placement.
- Introduce a real glyph atlas key: face id, glyph id, font size, style, presentation, and render flags.
- Stop treating codepoint + cell size as atlas identity.
- Validate glyph existence before fallback success.
- Track missing glyphs, fallback hits, fallback misses, and raster failures separately.
- Add a small Nerd Font and symbol corpus test where available.

Exit criteria:
- A glyph present in configured primary/fallback fonts renders as that glyph in both GL and GLES.
- GL/GLES produce matching placement decisions for the same glyph metrics.
- Missing glyphs are explicit and counted.

### Slice 1: Contract Reconciliation
Goal: make the existing placeholder text contract match the actual target.

Tasks:
- Replace `TextCluster.grapheme_utf8`-only thinking with `CellTextId` / `CellText` / `LineTextCache` vocabulary.
- Add `RunFont`, `TextRun`, `GlyphGroup`, `SpriteKey`, and `SpritePosition` types to render-core.
- Add tests for deterministic equality/hash fields where applicable.
- Document that `GlyphQuad` is final GPU output, not shaping input.

Exit criteria:
- `howl-render-core` tests define the line/run/group model without changing host behavior.

### Slice 2: Metrics And Decorations
Goal: one baseline/cell metric policy for GL and GLES.

Tasks:
- Factor FreeType metrics extraction into shared backend-local helper shape.
- Add `FontMetrics` fields needed by kitty-class decorations.
- Use identical baseline/origin placement in GL and GLES.
- Add tests for derived metrics from fake inputs where possible.

Exit criteria:
- GL/GLES no longer diverge in glyph vertical placement logic.

### Slice 3: Validated Fallback Resolver
Goal: stop treating fallback as blind path retry.

Tasks:
- Resolve against whole cell text.
- Cache fallback result by text/style/presentation.
- Count fallback hit/miss/missing glyph reasons.
- Keep configured fallback paths before system discovery.

Exit criteria:
- Known fallback glyphs do not render placeholder if present in configured fallback paths.

### Slice 4: Real HarfBuzz Runs
Goal: shape line runs, not codepoints.

Tasks:
- Build line runs from render cells.
- Feed UTF-32/UTF-8 run text to HarfBuzz.
- Convert HarfBuzz clusters into `GlyphGroup`s.
- Rasterize groups into sprite slots.
- Preserve current simple rendering path only as an implementation fallback during this slice, not as a public contract.

Exit criteria:
- Combining mark and CJK width tests pass.
- Simple ligature grouping tests pass for one configured font.

### Slice 5: Procedural Sprite Parity
Goal: make special glyph rendering a real kitty-like route.

Tasks:
- Expand procedural coverage beyond current subset.
- Add pixel-mask tests adapted from kitty's box/block testing style.
- Route procedural sprites through the same sprite/atlas cache shape as font glyph groups.

Exit criteria:
- Box/block/braille/powerline masks are deterministic across GL/GLES.

### Slice 6: Emoji And Presentation
Goal: make emoji/text presentation explicit.

Tasks:
- Interpret VS15/VS16 in cell text and resolver presentation.
- Add emoji fallback/presentation cache keys.
- Distinguish colored sprites from alpha sprites.

Exit criteria:
- `\u2716`, `\u2716\ufe0f`, and common emoji render with expected width and presentation.

### Slice 7: Performance And Diagnostics
Goal: make the mature path measurable.

Tasks:
- Add shaped-run cache.
- Add sprite-position cache.
- Add atlas upload batching and explicit eviction policy.
- Add debug counters accessible from render reports or test-only APIs.

Exit criteria:
- Heavy scrolling and prompt redraws do not reshape/rasterize unchanged text unnecessarily.

## First Recommended Work
Start with Slice 0.

Reason:
- The visible quality gap is glyph fidelity: modern Nerd Font symbols and edge-case glyphs must render as actual font glyphs.
- We can improve face/glyph resolution, atlas identity, metrics, and GL/GLES placement before a full shaping rewrite.
- This keeps the first implementation slice concrete and visually testable.

Do not start with broad system font discovery or full emoji. First make configured primary/fallback fonts render correctly and predictably.
