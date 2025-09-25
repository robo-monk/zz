const std = @import("std");
const core = @import("core.zig");

extern fn startTray() void;

pub fn main() !void {
    core.zig_init();
    startTray();
}
