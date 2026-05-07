const builtin = @import("builtin");

pub const c = @cImport({
    @cDefine("GL_GLEXT_PROTOTYPES", "1");
    @cInclude("GL/gl.h");
    @cInclude("GL/glext.h");
    @cInclude("ft2build.h");
    @cInclude("freetype/freetype.h");
    if (builtin.target.abi != .android) {
        @cInclude("harfbuzz/hb.h");
        @cInclude("harfbuzz/hb-ft.h");
    }
});

pub const FtLibrary = c.FT_Library;
pub const FtFace = c.FT_Face;
pub const HbFont = if (builtin.target.abi == .android) usize else *c.hb_font_t;
