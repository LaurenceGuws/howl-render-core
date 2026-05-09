//! Responsibility: expose C types used by the OpenGL ES backend.
//! Ownership: OpenGL ES backend internals own native header selection.
//! Reason: keeps platform C imports out of render-core public contracts.

const builtin = @import("builtin");

pub const c = @cImport({
    if (builtin.target.abi == .android) {
        @cDefine("_Nonnull", "");
        @cDefine("_Nullable", "");
        @cDefine("_Null_unspecified", "");
    }
    @cInclude("GLES2/gl2.h");
    @cInclude("time.h");
    @cInclude("ft2build.h");
    @cInclude("freetype/freetype.h");
    @cInclude("hb.h");
    @cInclude("hb-ft.h");
});

pub const FtLibrary = c.FT_Library;
pub const FtFace = c.FT_Face;
pub const HbFont = *c.hb_font_t;
