const std = @import("std");
const non_prod_options = @import("non_prod_options");

pub const main = @import("test/benchmark.zig").main;

test {
    switch (non_prod_options.entry) {
        .unit => {
            std.testing.refAllDecls(@import("howl_render.zig"));
            _ = @import("test/unit.zig");
        },
        .runtime_proof => {
            std.testing.refAllDecls(@import("howl_render.zig"));
            _ = @import("test/unit.zig");
        },
        .benchmark => {},
    }
}
