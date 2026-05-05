//! Responsibility: define the unified text-engine provider boundary.
//! Ownership: render-core text engine.
//! Reason: backends should implement one coherent FT/HB provider surface.

const contract = @import("../text_contract.zig");
const font_session = @import("font_session.zig");
const rasterizer = @import("rasterizer.zig");
const shape_run = @import("shape_run.zig");

pub const TextProvider = struct {
    face_provider: ?font_session.FaceProvider = null,
    shaper: shape_run.Shaper = shape_run.defaultShaper(),
    rasterizer: rasterizer.Rasterizer = rasterizer.defaultRasterizer(),

    pub fn applyToSession(self: TextProvider, session: font_session.FontSession) font_session.FontSession {
        var next = session;
        next.provider = self.face_provider;
        return next;
    }
};

pub fn defaultProvider() TextProvider {
    return .{};
}

test "text provider applies face provider to session" {
    const Provider = struct {
        fn has(ctx: *anyopaque, face_id: contract.FontFaceId, text: contract.CellText) bool {
            _ = ctx;
            _ = face_id;
            return text.codepoints.len == 1;
        }
    };
    var dummy: u8 = 0;
    const provider = TextProvider{ .face_provider = .{ .ctx = &dummy, .has_cell_text = Provider.has } };
    const session = provider.applyToSession(.{});
    const face = font_session.FontFaceRecord{ .id = .{ .value = 1 }, .role = .primary };
    try @import("std").testing.expect(!session.hasCellText(face, .{ .id = .{ .value = 0 }, .first_cp = 'i', .codepoints = &.{ 'i', 0x0332 } }));
}
