//! Responsibility: own font-group/session vocabulary.
//! Ownership: render-core text engine.
//! Reason: model primary, style, symbol, and fallback faces separately from backends.

const std = @import("std");
const contract = @import("../text_contract.zig");

pub const FontFaceId = contract.FontFaceId;

pub const FontFaceRole = enum(u3) {
    primary,
    style,
    symbol,
    fallback,
    emoji,
    missing,
};

pub const FontFaceRecord = struct {
    id: FontFaceId,
    role: FontFaceRole,
    style: contract.FontStyle = .regular,
    presentation: contract.TextPresentation = .any,
    coverage: Coverage = .all,

    pub fn hasCellText(self: FontFaceRecord, text: contract.CellText) bool {
        for (text.codepoints) |cp| {
            if (isNonRenderingCodepoint(cp)) continue;
            if (!covers(self.coverage, cp)) return false;
        }
        return true;
    }
};

pub const HasCellTextFn = *const fn (ctx: *anyopaque, face_id: FontFaceId, text: contract.CellText) bool;

pub const FaceProvider = struct {
    ctx: *anyopaque,
    has_cell_text: HasCellTextFn,

    pub fn hasCellText(self: FaceProvider, face_id: FontFaceId, text: contract.CellText) bool {
        return self.has_cell_text(self.ctx, face_id, text);
    }
};

pub const Coverage = union(enum) {
    all,
    range: CodepointRange,
};

pub const CodepointRange = struct {
    first: u32,
    last: u32,

    pub fn contains(self: CodepointRange, cp: u32) bool {
        return self.first <= cp and cp <= self.last;
    }
};

pub const FontSession = struct {
    primary_face: FontFaceId = .{ .value = 1 },
    faces: []const FontFaceRecord = &.{},
    provider: ?FaceProvider = null,
    metrics: contract.CellMetrics = .{ .cell_w_px = 1, .cell_h_px = 1, .baseline_px = 1 },

    pub fn primary(self: FontSession) FontFaceRecord {
        return self.find(.primary, .regular, .any, 0) orelse .{ .id = self.primary_face, .role = .primary };
    }

    pub fn findStyle(self: FontSession, style: contract.FontStyle, presentation: contract.TextPresentation, text: contract.CellText) ?FontFaceRecord {
        if (self.findText(.style, style, presentation, text)) |face| return face;
        if (style == .regular) return self.findText(.primary, .regular, presentation, text) orelse validPrimary(self, self.primary(), text);
        return self.findText(.primary, .regular, presentation, text) orelse validPrimary(self, self.primary(), text);
    }

    pub fn findSymbol(self: FontSession, cp: u32) ?FontFaceRecord {
        return self.find(.symbol, .regular, .any, cp);
    }

    pub fn findFallback(self: FontSession, style: contract.FontStyle, presentation: contract.TextPresentation, text: contract.CellText) ?FontFaceRecord {
        return self.findText(.fallback, style, presentation, text) orelse self.findText(.fallback, .regular, .any, text);
    }

    fn find(self: FontSession, role: FontFaceRole, style: contract.FontStyle, presentation: contract.TextPresentation, cp: u32) ?FontFaceRecord {
        for (self.faces) |face| {
            if (face.role != role) continue;
            if (face.style != style and face.style != .regular) continue;
            if (face.presentation != presentation and face.presentation != .any) continue;
            if (!covers(face.coverage, cp)) continue;
            return face;
        }
        return null;
    }

    fn findText(self: FontSession, role: FontFaceRole, style: contract.FontStyle, presentation: contract.TextPresentation, text: contract.CellText) ?FontFaceRecord {
        for (self.faces) |face| {
            if (face.role != role) continue;
            if (face.style != style and face.style != .regular) continue;
            if (face.presentation != presentation and face.presentation != .any) continue;
            if (!self.hasCellText(face, text)) continue;
            return face;
        }
        return null;
    }

    pub fn hasCellText(self: FontSession, face: FontFaceRecord, text: contract.CellText) bool {
        if (self.provider) |provider| return provider.hasCellText(face.id, text);
        return face.hasCellText(text);
    }
};

fn validPrimary(self: FontSession, face: FontFaceRecord, text: contract.CellText) ?FontFaceRecord {
    return if (self.hasCellText(face, text)) face else null;
}

fn covers(coverage: Coverage, cp: u32) bool {
    return switch (coverage) {
        .all => true,
        .range => |range| range.contains(cp),
    };
}

fn isNonRenderingCodepoint(cp: u32) bool {
    return cp == 0xfe0e or cp == 0xfe0f;
}

test "font session has deterministic defaults" {
    const session = FontSession{};
    try std.testing.expectEqual(@as(u32, 1), session.primary_face.value);
    try std.testing.expectEqual(@as(u32, 1), session.primary().id.value);
}

test "font session resolves symbol and fallback records by coverage" {
    const faces = [_]FontFaceRecord{
        .{ .id = .{ .value = 2 }, .role = .symbol, .coverage = .{ .range = .{ .first = 0xe000, .last = 0xf8ff } } },
        .{ .id = .{ .value = 3 }, .role = .fallback, .coverage = .{ .range = .{ .first = 0x2600, .last = 0x26ff } } },
    };
    const session = FontSession{ .faces = &faces };
    try std.testing.expectEqual(@as(u32, 2), session.findSymbol(0xe0b0).?.id.value);
    const snowman = contract.CellText{ .id = .{ .value = 1 }, .first_cp = 0x2603, .codepoints = &.{0x2603} };
    try std.testing.expectEqual(@as(u32, 3), session.findFallback(.regular, .any, snowman).?.id.value);
}

test "font session validates all rendering codepoints in cell text" {
    const faces = [_]FontFaceRecord{
        .{ .id = .{ .value = 2 }, .role = .primary, .coverage = .{ .range = .{ .first = 'a', .last = 'z' } } },
        .{ .id = .{ .value = 3 }, .role = .fallback, .coverage = .all },
    };
    const session = FontSession{ .faces = &faces };
    const combining = contract.CellText{ .id = .{ .value = 1 }, .first_cp = 'i', .codepoints = &.{ 'i', 0x0332 } };
    const emoji_presentation = contract.CellText{ .id = .{ .value = 2 }, .first_cp = 'x', .codepoints = &.{ 'x', 0xfe0f } };
    try std.testing.expect(session.findStyle(.regular, .any, combining) == null);
    try std.testing.expectEqual(@as(u32, 3), session.findFallback(.regular, .any, combining).?.id.value);
    try std.testing.expectEqual(@as(u32, 2), session.findStyle(.regular, .any, emoji_presentation).?.id.value);
}

test "font session provider can reject static coverage hits" {
    const Provider = struct {
        fn has(ctx: *anyopaque, face_id: FontFaceId, text: contract.CellText) bool {
            _ = ctx;
            if (face_id.value == 1 and text.codepoints.len > 1) return false;
            return true;
        }
    };
    const faces = [_]FontFaceRecord{
        .{ .id = .{ .value = 1 }, .role = .primary, .coverage = .all },
        .{ .id = .{ .value = 2 }, .role = .fallback, .coverage = .all },
    };
    var dummy: u8 = 0;
    const session = FontSession{ .faces = &faces, .provider = .{ .ctx = &dummy, .has_cell_text = Provider.has } };
    const sequence = contract.CellText{ .id = .{ .value = 1 }, .first_cp = 'i', .codepoints = &.{ 'i', 0x0332 } };
    try std.testing.expect(session.findStyle(.regular, .any, sequence) == null);
    try std.testing.expectEqual(@as(u32, 2), session.findFallback(.regular, .any, sequence).?.id.value);
}
