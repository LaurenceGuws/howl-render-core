
const builtin = @import("builtin");

pub const c = @cImport({
    if (builtin.target.abi == .android) {
        @cDefine("_Nonnull", "");
        @cDefine("_Nullable", "");
        @cDefine("_Null_unspecified", "");
    }
    @cDefine("GL_GLEXT_PROTOTYPES", "1");
    @cInclude("GL/gl.h");
    @cInclude("GL/glext.h");
    @cInclude("ft2build.h");
    @cInclude("freetype/freetype.h");
    @cInclude("harfbuzz/hb.h");
    @cInclude("harfbuzz/hb-ft.h");
});

pub const FtLibrary = c.FT_Library;
pub const FtFace = c.FT_Face;
pub const HbFont = *c.hb_font_t;
pub const supports_complex_shaping = builtin.target.abi != .android;

pub fn createHbFont(face: FtFace) ?HbFont {
    if (!supports_complex_shaping) return null;
    return @ptrCast(c.hb_ft_font_create_referenced(face));
}

pub fn destroyHbFont(hb_font: ?HbFont) void {
    if (!supports_complex_shaping) return;
    if (hb_font) |font| c.hb_font_destroy(font);
}

pub fn shapeGlyphId(hb_font: ?HbFont, face: FtFace, codepoint: u21) c_uint {
    if (!supports_complex_shaping) return c.FT_Get_Char_Index(face, codepoint);
    if (hb_font) |font| {
        const buffer = c.hb_buffer_create() orelse return c.FT_Get_Char_Index(face, codepoint);
        defer c.hb_buffer_destroy(buffer);
        var cp: u32 = codepoint;
        c.hb_buffer_add_utf32(buffer, &cp, 1, 0, 1);
        c.hb_buffer_guess_segment_properties(buffer);
        c.hb_shape(font, buffer, null, 0);
        var count: c_uint = 0;
        const infos = c.hb_buffer_get_glyph_infos(buffer, &count);
        if (infos != null and count > 0) {
            const gid = infos[0].codepoint;
            if (gid != 0) return gid;
        }
    }
    return c.FT_Get_Char_Index(face, codepoint);
}
