#ifndef HOWL_RENDER_H
#define HOWL_RENDER_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef uintptr_t HowlRenderSnapshotHandle;
typedef uintptr_t HowlRenderRuntimeHandle;
typedef uintptr_t HowlRenderRendererHandle;

typedef enum {
  HOWL_RENDER_CALL_OK = 0,
  HOWL_RENDER_CALL_MISSING_HANDLE = -1,
  HOWL_RENDER_CALL_INVALID_ARGUMENT = -2,
  HOWL_RENDER_CALL_FAILED = -3,
} HowlRenderCallStatus;

typedef enum {
  HOWL_RENDER_DAMAGE_NONE = 0,
  HOWL_RENDER_DAMAGE_PARTIAL = 1,
  HOWL_RENDER_DAMAGE_SCROLL = 2,
  HOWL_RENDER_DAMAGE_FULL = 3,
} HowlRenderDamageKind;

typedef enum {
  HOWL_RENDER_ACTION_IDLE = 0,
  HOWL_RENDER_ACTION_PREPARE = 1,
  HOWL_RENDER_ACTION_SUBMIT = 2,
  HOWL_RENDER_ACTION_PRESENT = 3,
} HowlRenderAction;

typedef enum {
  HOWL_RENDER_PREPARE_IDLE = 0,
  HOWL_RENDER_PREPARE_READY = 1,
  HOWL_RENDER_PREPARE_FAILED = -3,
} HowlRenderPrepareStatus;

typedef enum {
  HOWL_RENDER_SUBMIT_IDLE = 0,
  HOWL_RENDER_SUBMIT_RENDERED = 1,
  HOWL_RENDER_SUBMIT_STALE = 2,
  HOWL_RENDER_SUBMIT_NEEDS_PREPARE = 3,
  HOWL_RENDER_SUBMIT_FAILED = -3,
} HowlRenderSubmitStatus;

typedef struct {
  uint16_t width;
  uint16_t height;
} HowlRenderPixelSize;

typedef struct {
  uint16_t width;
  uint16_t height;
} HowlRenderCellSize;

typedef struct {
  uint16_t cols;
  uint16_t rows;
} HowlRenderGridSize;

typedef struct {
  int status;
  HowlRenderGridSize grid;
} HowlRenderFrameGridResult;

typedef struct {
  int status;
  HowlRenderCellSize cell_px;
  HowlRenderGridSize grid;
} HowlRenderFrameLayoutResult;

typedef struct {
  uint8_t continuation;
  uint8_t reserved0;
  uint8_t reserved1;
  uint8_t reserved2;
} HowlRenderCellFlags;

typedef struct {
  uint8_t kind;
  uint32_t value;
} HowlRenderColor;

typedef struct {
  uint8_t bold;
  uint8_t dim;
  uint8_t italic;
  uint8_t underline;
  uint8_t underline_color_set;
  uint8_t blink;
  uint8_t inverse;
  uint8_t invisible;
  uint8_t strikethrough;
} HowlRenderCellAttrs;

typedef struct {
  uint32_t codepoint;
  HowlRenderCellFlags flags;
  HowlRenderColor fg_color;
  HowlRenderColor bg_color;
  HowlRenderColor underline_color;
  uint8_t underline_style;
  uint8_t reserved0;
  uint8_t reserved1;
  uint8_t reserved2;
  HowlRenderCellAttrs attrs;
  uint32_t link_id;
} HowlRenderCell;

typedef struct {
  uint16_t row;
  uint16_t col;
  uint8_t visible;
  uint8_t shape;
} HowlRenderCursor;

typedef struct {
  HowlRenderPixelSize render_px;
  HowlRenderPixelSize grid_px;
  HowlRenderCellSize cell_px;
} HowlRenderGeometry;

typedef struct {
  int32_t status;
  uint8_t changed;
  uint8_t reserved0;
  uint8_t reserved1;
  uint8_t reserved2;
  uint32_t reserved3;
  HowlRenderPixelSize render_px;
  HowlRenderPixelSize grid_px;
  HowlRenderCellSize cell_px;
  uint64_t geometry_epoch;
} HowlRenderGeometryReceipt;

typedef struct {
  uintptr_t snapshot_handle;
  uint16_t cols;
  uint16_t rows;
  uint64_t scrollback_count;
  uint64_t scrollback_offset;
  uint8_t selection_anchor_valid;
  uint8_t selection_current_valid;
  uint8_t focused;
  uint8_t hover_underline_style;
  uint64_t selection_anchor_depth;
  uint16_t selection_anchor_col;
  uint16_t reserved0;
  uint64_t selection_current_depth;
  uint16_t selection_current_col;
  uint16_t reserved1;
  uint32_t hover_link_id;
  uint64_t snapshot_seq;
  uint64_t vt_epoch;
  uint8_t last_alt_screen;
  uint8_t reserved2;
  uint8_t reserved3;
  uint8_t reserved4;
} HowlRenderSourceView;

typedef struct {
  int32_t status;
  uint8_t published;
  uint8_t queued;
  uint8_t damage_kind;
  uint8_t reserved0;
  uint64_t source_seq;
  uint64_t geometry_epoch;
} HowlRenderSourceReceipt;

typedef struct {
  int32_t status;
  HowlRenderPixelSize render_px;
  HowlRenderPixelSize grid_px;
  HowlRenderCellSize cell_px;
  uint16_t font_size_px;
  uint16_t reserved0;
  uint64_t epoch;
} HowlRenderSurfaceQuery;

typedef struct {
  int32_t status;
  uint64_t snapshot_publishes;
  uint64_t snapshot_hidden_drops;
  uint64_t snapshot_clean_drops;
  uint64_t prepare_requests;
  uint64_t prepare_coalesces;
  uint64_t prepare_forced_full;
  uint64_t prepare_takes;
  uint64_t prepared_publishes;
  uint64_t prepared_coalesces;
  uint64_t submit_takes;
  uint64_t submit_valid;
  uint64_t submit_rejected;
  uint64_t full_prepare_requests;
  uint64_t submitted_accepts;
  uint64_t presents;
  uint64_t target_invalidations;
} HowlRenderRuntimeMetrics;

typedef struct {
  uint64_t sync_us;
  uint64_t copy_us;
  uint64_t render_us;
  uint64_t glyphs;
  uint64_t fills;
  uint64_t clear_fills;
  uint64_t background_fills;
  uint64_t decoration_fills;
  uint64_t cursor_fills;
  uint64_t uploads;
  uint64_t face_checks;
  uint64_t face_cache_hits;
  uint64_t shape_requests;
  uint64_t shape_cache_hits;
  uint64_t fallback_hits;
  uint64_t fallback_misses;
  uint64_t missing_glyphs;
} HowlRenderBackendMetrics;

typedef struct {
  uint32_t texture_id;
  uint16_t width;
  uint16_t height;
  uint64_t epoch;
} HowlRenderSurfaceHandle;

typedef struct {
  HowlRenderPixelSize surface_px;
  HowlRenderCellSize cell_px;
  uint16_t font_size_px;
  uint16_t reserved0;
  uint32_t target_texture;
} HowlRenderBackendConfig;

HowlRenderGridSize howl_render_derive_grid_size(HowlRenderPixelSize grid_px, HowlRenderCellSize cell_px);
HowlRenderFrameGridResult howl_render_derive_frame_grid_size(HowlRenderPixelSize render_px, HowlRenderPixelSize grid_px, HowlRenderCellSize cell_px);
HowlRenderFrameLayoutResult howl_render_renderer_derive_frame_layout(HowlRenderRendererHandle handle, HowlRenderPixelSize render_px, HowlRenderPixelSize grid_px);

HowlRenderSnapshotHandle howl_render_snapshot_init(uint16_t rows, uint16_t cols);
void howl_render_snapshot_deinit(HowlRenderSnapshotHandle handle);
int howl_render_snapshot_resize(HowlRenderSnapshotHandle handle, uint16_t rows, uint16_t cols);
int howl_render_snapshot_mark_full_dirty(HowlRenderSnapshotHandle handle);
int howl_render_snapshot_clear_dirty(HowlRenderSnapshotHandle handle);
int howl_render_snapshot_set_viewport(HowlRenderSnapshotHandle handle, uint64_t scroll_row, int is_alternate_screen);
int howl_render_snapshot_set_cursor(HowlRenderSnapshotHandle handle, HowlRenderCursor cursor);
int howl_render_snapshot_write_cell(HowlRenderSnapshotHandle handle, uint16_t row, uint16_t col, HowlRenderCell cell);

HowlRenderRuntimeHandle howl_render_runtime_init(void);
void howl_render_runtime_deinit(HowlRenderRuntimeHandle handle);
int howl_render_runtime_set_font_size_px(HowlRenderRuntimeHandle handle, uint16_t font_size_px);
HowlRenderGeometryReceipt howl_render_runtime_sync_geometry(HowlRenderRuntimeHandle handle, HowlRenderGeometry geometry);
HowlRenderSourceReceipt howl_render_runtime_publish_snapshot(HowlRenderRuntimeHandle handle, HowlRenderSourceView source);
uint8_t howl_render_runtime_has_pending_publication(HowlRenderRuntimeHandle handle);
uint8_t howl_render_runtime_action(HowlRenderRuntimeHandle handle);
void howl_render_runtime_mark_presented(HowlRenderRuntimeHandle handle);
HowlRenderSurfaceQuery howl_render_runtime_surface_query(HowlRenderRuntimeHandle handle);
HowlRenderRuntimeMetrics howl_render_runtime_take_metrics(HowlRenderRuntimeHandle handle);
int howl_render_runtime_reset_metrics(HowlRenderRuntimeHandle handle);

HowlRenderRendererHandle howl_render_renderer_init(HowlRenderBackendConfig config);
void howl_render_renderer_deinit(HowlRenderRendererHandle handle);
int howl_render_renderer_set_font_size_px(HowlRenderRendererHandle handle, uint16_t font_size_px);
int howl_render_renderer_set_font_path(HowlRenderRendererHandle handle, const uint8_t *ptr, size_t len);
int howl_render_renderer_set_fallback_font_paths(HowlRenderRendererHandle handle, const uint8_t *const *ptrs, size_t count);
int howl_render_renderer_prepare(HowlRenderRendererHandle renderer_handle, HowlRenderRuntimeHandle runtime_handle, HowlRenderSnapshotHandle snapshot_handle);
HowlRenderSubmitStatus howl_render_renderer_submit(HowlRenderRendererHandle renderer_handle, HowlRenderRuntimeHandle runtime_handle, HowlRenderSurfaceHandle *surface_out, HowlRenderBackendMetrics *metrics_out);

#ifdef __cplusplus
}
#endif

#endif
