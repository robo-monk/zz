const std = @import("std");
// const Ollama = @import("ollama");

// ---- Swift UI functions we call from Zig ----
extern fn ui_set_tray_title(title: [*]const u8) void;
extern fn ui_take_screenshot_at(path: [*]const u8) bool;

// ---- State ----
const State = struct {
    arena: std.heap.ArenaAllocator,

    is_running: bool = false,
    task_name: []u8 = &[_]u8{},

    base_elapsed_s: u64 = 0, // seconds accumulated while paused
    start_mono_ns: u64 = 0, // monotonic start when running

    session_start_s: u64 = 0, // epoch seconds of first start
    session_folder: []u8 = &[_]u8{},

    // Focus tracking
    last_focus_name: []u8 = &[_]u8{},
    last_focus_change_s: u64 = 0,
    app_times: std.StringHashMap(u64), // seconds per app name
};

var state_opt: ?*State = null;

fn nowEpochSeconds() u64 {
    return @as(u64, @intCast(std.time.timestamp()));
}

fn nowMonoNs() u64 {
    return @as(u64, @intCast(std.time.nanoTimestamp()));
}

fn dupZ(alloc: std.mem.Allocator, s: []const u8) ![*:0]u8 {
    var buf = try alloc.alloc(u8, s.len + 1);
    std.mem.copyForwards(u8, buf[0..s.len], s);
    buf[s.len] = 0;
    return @as([*:0]u8, @ptrCast(buf.ptr));
}

fn ensureState() *State {
    if (state_opt) |s| return s;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();
    const map = std.StringHashMap(u64).init(std.heap.page_allocator);
    const st = alloc.create(State) catch @panic("OOM");
    st.* = .{ .arena = arena, .app_times = map };
    state_opt = st;
    return st;
}

fn freeIfSet(alloc: std.mem.Allocator, s: []u8) void {
    if (s.len > 0) alloc.free(s);
}

fn tasksRoot(alloc: std.mem.Allocator) ![]u8 {
    const home = try std.process.getEnvVarOwned(alloc, "HOME");
    defer alloc.free(home);
    const path = try std.fs.path.join(alloc, &[_][]const u8{ home, ".zz", "tasks" });
    try std.fs.cwd().makePath(path);
    return path;
}

fn sanitized(alloc: std.mem.Allocator, name: []const u8) ![]u8 {
    var buf = try alloc.alloc(u8, name.len);
    var j: usize = 0;
    for (name) |c| {
        if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == ' ' or c == '-' or c == '_') {
            buf[j] = c;
            j += 1;
        } else {
            buf[j] = '_';
            j += 1;
        }
    }
    return buf[0..j];
}

fn ensureSessionFolder(st: *State) !void {
    const alloc = st.arena.allocator();
    if (st.session_folder.len != 0) return;
    const root = try tasksRoot(alloc);
    const base_name = if (st.task_name.len != 0) st.task_name else "task";
    const safe = try sanitized(alloc, base_name);
    var buf: [32]u8 = undefined;
    const t = nowEpochSeconds();
    const stamp = std.fmt.bufPrint(&buf, "{d:0>8}", .{t}) catch unreachable;
    const folder_name = try std.fmt.allocPrint(alloc, "{s}_{s}", .{ safe, stamp });
    const folder = try std.fs.path.join(alloc, &[_][]const u8{ root, folder_name });
    try std.fs.cwd().makePath(folder);
    st.session_folder = folder;
}

fn screenshotsFolder(st: *State) ![]u8 {
    const alloc = st.arena.allocator();
    try ensureSessionFolder(st);
    const shots = try std.fs.path.join(alloc, &[_][]const u8{ st.session_folder, "screenshots" });
    try std.fs.cwd().makePath(shots);
    return shots;
}

fn nextScreenshotPath(st: *State) ![]u8 {
    const alloc = st.arena.allocator();
    const shots = try screenshotsFolder(st);
    var buf: [32]u8 = undefined;
    const t = nowEpochSeconds();
    const ts = std.fmt.bufPrint(&buf, "{d:0>8}", .{t}) catch unreachable;
    const filename = try std.fmt.allocPrint(alloc, "screenshot_{s}.png", .{ts});
    return try std.fs.path.join(alloc, &[_][]const u8{ shots, filename });
}

fn formatElapsed(st: *State, out: []u8) usize {
    var total: u64 = st.base_elapsed_s;
    if (st.is_running) {
        const delta_ns = nowMonoNs() - st.start_mono_ns;
        total += @divTrunc(delta_ns, std.time.ns_per_s);
    }
    return formatSeconds(total, out);
}

fn formatSeconds(total: u64, out: []u8) usize {
    const h: u64 = total / 3600;
    const m: u64 = (total % 3600) / 60;
    const s: u64 = total % 60;
    if (h > 0) {
        const res = std.fmt.bufPrint(out, "{d}:{d:0>2}:{d:0>2}", .{ h, m, s }) catch return 0;
        return res.len;
    } else {
        const res = std.fmt.bufPrint(out, "{d:0>2}:{d:0>2}", .{ m, s }) catch return 0;
        return res.len;
    }
}

fn appTimeAccrue(st: *State, name: []const u8, delta_s: u64) !void {
    const gop = try st.app_times.getOrPut(name);
    if (!gop.found_existing) {
        gop.key_ptr.* = try std.heap.page_allocator.dupe(u8, name);
        gop.value_ptr.* = 0;
    }
    gop.value_ptr.* += delta_s;
}

fn writeTaskMd(st: *State) !void {
    const alloc = st.arena.allocator();
    try ensureSessionFolder(st);
    const path = try std.fs.path.join(alloc, &[_][]const u8{ st.session_folder, "TASK.md" });
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();

    // finalize last app segment
    if (st.last_focus_name.len != 0 and st.last_focus_change_s != 0) {
        const delta = nowEpochSeconds() - st.last_focus_change_s;
        try appTimeAccrue(st, st.last_focus_name, delta);
    }

    const title = if (st.task_name.len != 0) st.task_name else "task";
    try file.writer().print("# {s}\n\n", .{title});

    // Start/End and Duration
    const start_ts = if (st.session_start_s != 0) st.session_start_s else nowEpochSeconds();
    const end_ts = nowEpochSeconds();
    // Write as epoch seconds for portability; can be prettified later.
    var elapsed: u64 = st.base_elapsed_s;
    if (st.is_running) {
        elapsed += @divTrunc(nowMonoNs() - st.start_mono_ns, std.time.ns_per_s);
    }
    var tmp: [32]u8 = undefined;
    const title_len = formatElapsed(st, tmp[0..]);
    try file.writer().print("- Start: {d}\n- End: {d}\n- Duration: {s}\n- Screenshots: ./screenshots/\n\n", .{ start_ts, end_ts, tmp[0..title_len] });

    // App times (formatted as h:mm:ss)
    try file.writer().writeAll("## App Time\n");
    var it = st.app_times.iterator();
    var any = false;
    while (it.next()) |e| {
        any = true;
        const secs = e.value_ptr.*;
        var fbuf: [32]u8 = undefined;
        const flen = formatSeconds(secs, fbuf[0..]);
        try file.writer().print("  - {s}: {s}\n", .{ e.key_ptr.*, fbuf[0..flen] });
    }
    if (!any) {
        try file.writer().writeAll("  - (no focus changes recorded)\n");
    }
}

// no-op placeholder retained for potential future use

// ---- Exports for Swift to call ----
pub export fn zig_init() callconv(.C) void {
    _ = ensureState();
}

export fn zig_on_set_task_name(name: [*:0]const u8) callconv(.C) void {
    var st = ensureState();
    const alloc = st.arena.allocator();
    const n = std.mem.sliceTo(name, 0);
    if (st.task_name.len != 0) alloc.free(st.task_name);
    st.task_name = alloc.dupe(u8, n) catch return;
}

export fn zig_on_start_pause() callconv(.C) void {
    var st = ensureState();
    if (st.is_running) {
        // pause
        const delta_ns = nowMonoNs() - st.start_mono_ns;
        st.base_elapsed_s += @divTrunc(delta_ns, std.time.ns_per_s);
        st.is_running = false;
    } else {
        // start
        if (st.session_start_s == 0) st.session_start_s = nowEpochSeconds();
        st.start_mono_ns = nowMonoNs();
        st.is_running = true;
    }
}

export fn zig_on_end_task() callconv(.C) void {
    var st = ensureState();
    if (st.is_running) {
        const delta_ns = nowMonoNs() - st.start_mono_ns;
        st.base_elapsed_s += @divTrunc(delta_ns, std.time.ns_per_s);
        st.is_running = false;
    }
    // Persist
    writeTaskMd(st) catch {};
    // reset
    const alloc = st.arena.allocator();
    st.base_elapsed_s = 0;
    st.start_mono_ns = 0;
    st.session_start_s = 0;
    st.last_focus_change_s = 0;
    st.last_focus_name = &[_]u8{};
    st.app_times.clearAndFree();
    freeIfSet(alloc, st.session_folder);
    st.session_folder = &[_]u8{};
    // Note: keep task_name? We'll clear to empty
    freeIfSet(alloc, st.task_name);
    st.task_name = &[_]u8{};
}

export fn zig_on_tick_write_title(buf: [*]u8, buf_len: usize) callconv(.C) usize {
    const st = ensureState();
    var out = buf[0..buf_len];
    const n = formatElapsed(st, out);
    if (n < buf_len) out[n] = 0; // NUL terminate if space
    return n;
}

export fn zig_take_screenshot() void {
    std.log.debug("Skipping screenshot taking", .{});

    // var st = ensureState();
    // const alloc = st.arena.allocator();
    // const shot_path = nextScreenshotPath(st) catch return;
    // const z = dupZ(alloc, shot_path) catch return;
    // _ = ui_take_screenshot_at(z);
}

export fn zig_on_focus_changed_stable(app_c: [*:0]const u8) callconv(.C) void {
    const st = ensureState();
    const app = std.mem.sliceTo(app_c, 0);
    // Accrue previous
    if (st.is_running and st.last_focus_name.len != 0 and st.last_focus_change_s != 0) {
        const delta = nowEpochSeconds() - st.last_focus_change_s;
        appTimeAccrue(st, st.last_focus_name, delta) catch {};
    }
    const alloc = st.arena.allocator();
    st.last_focus_name = alloc.dupe(u8, app) catch st.last_focus_name;
    st.last_focus_change_s = nowEpochSeconds();

    zig_take_screenshot();
}

export fn zig_on_periodic_screenshot() callconv(.C) void {
    const st = ensureState();
    if (!st.is_running) return;
    zig_take_screenshot();
}

export fn zig_get_tasks_root_path(buf: [*]u8, buf_len: usize) callconv(.C) usize {
    const st = ensureState();
    _ = st;
    const alloc = std.heap.page_allocator;
    const root = tasksRoot(alloc) catch return 0;
    defer alloc.free(root);
    const n = if (buf_len < root.len + 1) buf_len else root.len + 1;
    std.mem.copyForwards(u8, buf[0 .. n - 1], root);
    buf[n - 1] = 0;
    return n - 1;
}

// Returns a UTF-8 text snapshot of app usage times as lines:
// "<app_name>\t<seconds>\n". Truncates to the provided buffer size.
export fn zig_get_app_times(buf: [*]u8, buf_len: usize) callconv(.C) usize {
    const st = ensureState();
    var fbs = std.io.fixedBufferStream(buf[0..buf_len]);
    const w = fbs.writer();

    const now_s = nowEpochSeconds();
    var it = st.app_times.iterator();
    var last_added = false;
    while (it.next()) |e| {
        var secs = e.value_ptr.*;
        if (st.is_running and st.last_focus_name.len != 0 and st.last_focus_change_s != 0 and
            std.mem.eql(u8, e.key_ptr.*, st.last_focus_name))
        {
            secs += now_s - st.last_focus_change_s;
            last_added = true;
        }
        if (secs == 0) continue;
        // Format: name TAB seconds NEWLINE
        _ = w.print("{s}\t{d}\n", .{ e.key_ptr.*, secs }) catch break;
    }

    if (!last_added and st.is_running and st.last_focus_name.len != 0 and st.last_focus_change_s != 0) {
        const delta = now_s - st.last_focus_change_s;
        if (delta > 0) {
            _ = w.print("{s}\t{d}\n", .{ st.last_focus_name, delta }) catch {};
        }
    }

    return fbs.pos;
}

// pub fn visionDescribeImage(allocator: std.mem.Allocator, image_path: []const u8) ![]const u8 {
//     std.log.debug("Visually AIing...", .{});
//     // 1) Read image & build data URL
//     const img_bytes = try std.fs.cwd().readFileAlloc(allocator, image_path, 50 * 1024 * 1024);
//     defer allocator.free(img_bytes);

//     // const mime = "image/jpeg";
//     const b64 = try base64EncodeAlloc(allocator, img_bytes);
//     defer allocator.free(b64);

//     // const data_url = try std.fmt.allocPrint(allocator, "data:{s};base64,{s}", .{ mime, b64 });
//     // defer allocator.free(data_url);

//     // 2) Build JSON body for Responses API
//     // Using the new "input" array schema with content parts.
//     const system_prompt =
//         "You are a concise visual analyst. Describe the image clearly and list any notable details.";

//     var ollama = Ollama.init(allocator, .{});
//     defer ollama.deinit();
//     // std.debug.print("base64is: {}", data_url);
//     //
//     const res = ollama.generate(.{
//         .model = "gemma3:4b",
//         .prompt = system_prompt,
//         .images = &[_][]u8{b64},
//         .stream = false,
//     }) catch |err| {
//         std.log.err("Ollama generate error: {}", .{err});
//         return "Error generating description";
//     };

//     std.debug.print("{s}", .{res.response});
//     return res.response;
// }

// ---------- helpers ----------

fn base64EncodeAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const enc = std.base64.standard.Encoder;
    const out_len = enc.calcSize(bytes.len);
    const out = try allocator.alloc(u8, out_len);
    _ = enc.encode(out, bytes);
    return out;
}
