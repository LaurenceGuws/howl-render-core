#ifndef HOWL_RENDER_H
#define HOWL_RENDER_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct HowlRenderSurfaceText HowlRenderSurfaceText;
typedef struct HowlRenderPreparedSurfaceObject HowlRenderPreparedSurfaceObject;

typedef HowlRenderSurfaceText *HowlRenderSurfaceTextHandle;
typedef HowlRenderPreparedSurfaceObject *HowlRenderPreparedSurfaceHandle;

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

typedef enum {
  HOWL_RENDER_PIXEL_FORMAT_ALPHA8 = 0,
  HOWL_RENDER_PIXEL_FORMAT_RGBA8 = 1,
} HowlRenderPixelFormat;

typedef enum {
  HOWL_RENDER_SPRITE_PASS_ALPHA = 0,
  HOWL_RENDER_SPRITE_PASS_COLOR = 1,
} HowlRenderSpritePassKind;

typedef struct {
  uint16_t width;
  uint16_t height;
} HowlRenderPixelSize;

typedef struct {
  uint16_t width;
  uint16_t height;
} HowlRenderCellSize;

typedef struct {
  uint8_t r;
  uint8_t g;
  uint8_t b;
  uint8_t a;
} HowlRenderRgba8;

typedef struct {
  uint16_t cols;
  uint16_t rows;
} HowlRenderGridSize;

typedef struct {
  int32_t x_px;
  int32_t y_px;
  uint16_t width_px;
  uint16_t height_px;
  HowlRenderRgba8 color;
} HowlRenderColorDraw;

typedef struct {
  uint32_t slot;
  uint64_t key;
  int32_t x_px;
  int32_t y_px;
  uint16_t width_px;
  uint16_t height_px;
  HowlRenderRgba8 color;
} HowlRenderSpriteDraw;

typedef struct {
  uint8_t kind;
  uint8_t reserved0;
  uint16_t reserved1;
  int32_t x_px;
  int32_t y_px;
  uint16_t width_px;
  uint16_t height_px;
  HowlRenderRgba8 color;
} HowlRenderDecorationDraw;

typedef struct {
  uint16_t x_px;
  uint16_t y_px;
  uint16_t width_px;
  uint16_t height_px;
} HowlRenderRasterBounds;

typedef struct {
  uint32_t slot;
  uint64_t key;
  uint16_t width_px;
  uint16_t height_px;
  uint8_t color_mode;
  uint8_t reserved0;
  uint16_t reserved1;
  HowlRenderRasterBounds visual_bounds;
  const uint8_t *pixels_ptr;
  size_t pixels_len;
} HowlRenderRasterUpload;

typedef struct {
  const HowlRenderColorDraw *ptr;
  size_t len;
} HowlRenderColorDrawSpan;

typedef struct {
  const HowlRenderSpriteDraw *ptr;
  size_t len;
} HowlRenderSpriteDrawSpan;

typedef struct {
  const HowlRenderDecorationDraw *ptr;
  size_t len;
} HowlRenderDecorationDrawSpan;

typedef struct {
  const HowlRenderRasterUpload *ptr;
  size_t len;
} HowlRenderRasterUploadSpan;

typedef struct {
  int32_t x;
  int32_t y;
  int32_t width;
  int32_t height;
} HowlRenderRect;

typedef struct {
  const HowlRenderRect *ptr;
  size_t len;
} HowlRenderRectSpan;

typedef struct {
  const uint8_t *ptr;
  size_t len;
} HowlRenderByteSpan;

typedef struct {
  const uint16_t *ptr;
  size_t len;
} HowlRenderU16Span;

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
  const HowlRenderCell *ptr;
  size_t len;
} HowlRenderCellSpan;

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
} HowlRenderGeometryResponse;

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
  uint64_t snapshot_seq;
  uint64_t dirty_epoch;
  uint64_t geometry_epoch;
  uint64_t damage_base_seq;
  uint64_t known_target_epoch;
  uint8_t target_valid;
  uint8_t damage_kind;
  uint16_t reserved0;
} HowlRenderPrepareRequest;

typedef struct {
  uint64_t snapshot_seq;
  uint64_t dirty_epoch;
  uint64_t geometry_epoch;
  uint64_t damage_base_seq;
  uint64_t required_base_seq;
  uint64_t required_target_epoch;
  uint8_t damage_kind;
  uint8_t reserved0;
  uint16_t reserved1;
} HowlRenderPreparedFrame;

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
} HowlRenderSurfaceMetrics;

typedef struct {
  uint32_t texture_id;
  uint16_t width;
  uint16_t height;
  uint64_t epoch;
} HowlRenderSurfaceHandle;

typedef struct {
  int32_t status;
  uint64_t snapshot_seq;
  uint64_t dirty_epoch;
  uint64_t geometry_epoch;
  uint64_t required_base_seq;
  uint64_t required_surface_epoch;
  HowlRenderPixelSize render_px;
  HowlRenderCellSize cell_px;
  HowlRenderGridSize grid;
  HowlRenderSurfaceMetrics prepare_metrics;
  uint8_t damage_kind;
  uint8_t reserved0;
  uint16_t reserved1;
} HowlRenderPreparedSurfaceInfo;

typedef struct {
  int32_t status;
  uint8_t full_redraw;
  uint8_t reserved0;
  uint16_t scroll_up_px;
  HowlRenderRectSpan surface_damage_rects;
  HowlRenderRectSpan buffer_damage_rects;
} HowlRenderPreparedSurfaceDamagePlan;

typedef struct {
  uint64_t sprite_key;
  uint32_t slot;
  uint16_t atlas_page;
  uint8_t pixel_format;
  uint8_t color_mode;
  uint16_t width_px;
  uint16_t height_px;
  uint16_t stride;
  uint32_t reserved0;
  uint64_t blob_offset;
  uint64_t blob_len;
  HowlRenderRasterBounds visual_bounds;
} HowlRenderUploadOp;

typedef struct {
  const HowlRenderUploadOp *ptr;
  size_t len;
} HowlRenderUploadOpSpan;

typedef struct {
  int32_t status;
  HowlRenderUploadOpSpan uploads;
  HowlRenderByteSpan pixel_blob;
} HowlRenderPreparedSurfaceUploadPlan;

typedef struct {
  uint16_t atlas_page;
  uint8_t pass_kind;
  uint8_t reserved0;
  uint32_t first_instance;
  uint32_t instance_count;
} HowlRenderSpriteBatch;

typedef struct {
  const HowlRenderSpriteBatch *ptr;
  size_t len;
} HowlRenderSpriteBatchSpan;

typedef struct {
  uint32_t slot;
  uint64_t sprite_key;
  int32_t dst_x_px;
  int32_t dst_y_px;
  uint16_t dst_width_px;
  uint16_t dst_height_px;
  uint16_t src_x_px;
  uint16_t src_y_px;
  uint16_t src_width_px;
  uint16_t src_height_px;
  HowlRenderRgba8 color;
} HowlRenderSpriteInstance;

typedef struct {
  const HowlRenderSpriteInstance *ptr;
  size_t len;
} HowlRenderSpriteInstanceSpan;

typedef struct {
  int32_t status;
  HowlRenderColorDrawSpan clear_draws;
  HowlRenderColorDrawSpan background_draws;
  HowlRenderSpriteBatchSpan sprite_batches;
  HowlRenderSpriteInstanceSpan sprite_instances;
  HowlRenderDecorationDrawSpan decoration_draws;
  HowlRenderColorDrawSpan cursor_draws;
} HowlRenderPreparedSurfaceDrawPlan;

typedef struct {
  int32_t status;
  uint64_t missing_glyphs;
  HowlRenderSurfaceMetrics resolve_metrics;
} HowlRenderPreparedSurfaceDiagnostics;

typedef struct {
  HowlRenderSurfaceHandle surface;
  uint64_t uploads_committed;
  uint64_t render_us;
  uint8_t scroll_reuse_applied;
  uint8_t content_valid;
  uint16_t reserved0;
} HowlRenderSurfaceExecutionInput;

typedef struct {
  HowlRenderCellSpan cells;
  uint16_t cols;
  uint16_t rows;
  uint64_t scroll_row;
  uint8_t is_alternate_screen;
  uint8_t full_damage;
  uint16_t scroll_up_rows;
  HowlRenderByteSpan dirty_rows;
  HowlRenderU16Span dirty_cols_start;
  HowlRenderU16Span dirty_cols_end;
  HowlRenderCursor cursor;
} HowlRenderSurfaceSource;

typedef struct {
  int32_t status;
  uint8_t damage_kind;
  uint8_t reserved0;
  uint16_t reserved1;
  HowlRenderSurfaceHandle surface;
  HowlRenderSurfaceMetrics metrics;
} HowlRenderSurfaceFeedback;

typedef struct {
  HowlRenderPixelSize surface_px;
  uint16_t font_size_px;
  uint16_t reserved0;
} HowlRenderSurfaceTextConfig;

HowlRenderGridSize howl_render_derive_grid_size(HowlRenderPixelSize grid_px, HowlRenderCellSize cell_px);
HowlRenderFrameGridResult howl_render_derive_frame_grid_size(HowlRenderPixelSize render_px, HowlRenderPixelSize grid_px, HowlRenderCellSize cell_px);
HowlRenderFrameLayoutResult howl_render_surface_text_derive_frame_layout(HowlRenderSurfaceTextHandle handle, HowlRenderPixelSize render_px, HowlRenderPixelSize grid_px);

HowlRenderSurfaceTextHandle howl_render_surface_text_init(HowlRenderSurfaceTextConfig config);
void howl_render_surface_text_deinit(HowlRenderSurfaceTextHandle handle);
int howl_render_surface_text_set_font_size_px(HowlRenderSurfaceTextHandle handle, uint16_t font_size_px);
int howl_render_surface_text_set_font_path(HowlRenderSurfaceTextHandle handle, const uint8_t *ptr, size_t len);
int howl_render_surface_text_set_fallback_font_paths(HowlRenderSurfaceTextHandle handle, const uint8_t *const *ptrs, size_t count);

/* Owned prepared-surface ABI target. */
HowlRenderPrepareStatus howl_render_surface_text_prepare_handle(HowlRenderSurfaceTextHandle surface_text_handle, const HowlRenderSurfaceSource *surface_source, HowlRenderPrepareRequest prepare_request, HowlRenderSurfaceQuery query, HowlRenderPreparedSurfaceHandle *prepared_handle_out);
void howl_render_prepared_surface_release(HowlRenderPreparedSurfaceHandle prepared_surface_handle);
int howl_render_prepared_surface_describe(HowlRenderPreparedSurfaceHandle prepared_surface_handle, HowlRenderPreparedSurfaceInfo *info_out);
int howl_render_prepared_surface_damage_plan(HowlRenderPreparedSurfaceHandle prepared_surface_handle, HowlRenderPreparedSurfaceDamagePlan *plan_out);
int howl_render_prepared_surface_upload_plan(HowlRenderPreparedSurfaceHandle prepared_surface_handle, HowlRenderPreparedSurfaceUploadPlan *plan_out);
int howl_render_prepared_surface_draw_plan(HowlRenderPreparedSurfaceHandle prepared_surface_handle, HowlRenderPreparedSurfaceDrawPlan *plan_out);
int howl_render_prepared_surface_diagnostics(HowlRenderPreparedSurfaceHandle prepared_surface_handle, HowlRenderPreparedSurfaceDiagnostics *diagnostics_out);
HowlRenderSubmitStatus howl_render_surface_text_submit(HowlRenderSurfaceTextHandle surface_text_handle, HowlRenderPreparedSurfaceHandle prepared_surface_handle, HowlRenderPreparedFrame prepared_frame, const HowlRenderSurfaceExecutionInput *execution_in, HowlRenderSurfaceFeedback *feedback_out);

#ifdef __cplusplus
}
#endif

#endif
