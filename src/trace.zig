//! Temporary structured runtime trace sink for stress investigations.
//! Enable with HOWL_TRACE_PATH=/path/to/trace.ndjson.

const std = @import("std");

const trace_path_var = "HOWL_TRACE_PATH";

fn pathFromEnv() ?[]const u8 {
    const ptr = std.c.getenv(trace_path_var) orelse return null;
    const path = std.mem.span(ptr);
    return if (path.len == 0) null else path;
}

fn monotonicNs() u64 {
    var io_ctx = std.Io.Threaded.init_single_threaded;
    return @intCast(std.Io.Clock.awake.now(io_ctx.io()).nanoseconds);
}

fn writeLine(comptime fmt: []const u8, args: anytype) void {
    const path = pathFromEnv() orelse return;

    var io_ctx = std.Io.Threaded.init_single_threaded;
    const io = io_ctx.io();
    const file = if (std.fs.path.isAbsolute(path))
        std.Io.Dir.createFileAbsolute(io, path, .{ .truncate = false, .lock = .exclusive })
    else
        std.Io.Dir.cwd().createFile(io, path, .{ .truncate = false, .lock = .exclusive });
    var opened = file catch return;
    defer opened.close(io);

    const stat = opened.stat(io) catch return;
    var buf: [1024]u8 = undefined;
    var writer = opened.writer(io, &buf);
    writer.pos = stat.size;
    writer.interface.print(fmt ++ "\n", args) catch return;
    writer.interface.flush() catch return;
}

pub fn termIo(reads: usize, bytes: usize, ingest_apply_us: u64, history_delta: usize) void {
    writeLine(
        "{{\"ts_ns\":{d},\"event\":\"term_io\",\"reads\":{d},\"bytes\":{d},\"ingest_apply_us\":{d},\"history_delta\":{d}}}",
        .{ monotonicNs(), reads, bytes, ingest_apply_us, history_delta },
    );
}

pub fn termFrame(cols: u16, rows: u16, sync_us: u64, batch_us: u64, locked_us: u64, render_us: u64, glyphs: usize, fills: usize, uploads: usize) void {
    writeLine(
        "{{\"ts_ns\":{d},\"event\":\"term_frame\",\"cols\":{d},\"rows\":{d},\"sync_us\":{d},\"batch_us\":{d},\"locked_us\":{d},\"render_us\":{d},\"glyphs\":{d},\"fills\":{d},\"uploads\":{d}}}",
        .{ monotonicNs(), cols, rows, sync_us, batch_us, locked_us, render_us, glyphs, fills, uploads },
    );
}

pub fn renderAtlas(comptime backend: []const u8, uploads: usize, fast_hits: usize, resolved_hits: usize, committed: usize, elapsed_us: u64) void {
    writeLine(
        "{{\"ts_ns\":{d},\"event\":\"render_atlas\",\"backend\":\"" ++ backend ++ "\",\"uploads\":{d},\"fast_hits\":{d},\"resolved_hits\":{d},\"committed\":{d},\"elapsed_us\":{d}}}",
        .{ monotonicNs(), uploads, fast_hits, resolved_hits, committed, elapsed_us },
    );
}

pub fn hostRender(wake_to_render_us: u64, render_us: u64, render_px_w: u16, render_px_h: u16, grid_px_w: u16, grid_px_h: u16) void {
    writeLine(
        "{{\"ts_ns\":{d},\"event\":\"host_render\",\"wake_to_render_us\":{d},\"render_us\":{d},\"render_px_w\":{d},\"render_px_h\":{d},\"grid_px_w\":{d},\"grid_px_h\":{d}}}",
        .{ monotonicNs(), wake_to_render_us, render_us, render_px_w, render_px_h, grid_px_w, grid_px_h },
    );
}

pub fn hostFrame(terminal_dirty: bool, terminal_us: u64, present_us: u64, total_us: u64, texture_id: u32) void {
    writeLine(
        "{{\"ts_ns\":{d},\"event\":\"host_frame\",\"terminal_dirty\":{},\"terminal_us\":{d},\"present_us\":{d},\"total_us\":{d},\"texture\":{d}}}",
        .{ monotonicNs(), terminal_dirty, terminal_us, present_us, total_us, texture_id },
    );
}
