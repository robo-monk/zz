const std = @import("std");

extern fn startTray() void;
pub fn main() !void {
    // Launch the macOS status bar (tray) app written in Swift.
    // This call blocks while the app run loop is active.
    startTray();
}
