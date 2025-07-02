const std = @import("std");

extern fn hello() i32;

pub fn main() !void {
    const ret = hello();
    // Prints to stderr (it's a shortcut based on `std.io.getStdErr()`)
    std.debug.print("All your {s} are belong to us ({}).\n", .{ "codebase", ret });
}
