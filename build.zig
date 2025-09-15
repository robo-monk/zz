const std = @import("std");

fn sdkPath(comptime suffix: []const u8) []const u8 {
    if (suffix[0] != '/') @compileError("suffix must be an absolute path");
    return comptime blk: {
        const root_dir = std.fs.path.dirname(@src().file) orelse ".";
        break :blk root_dir ++ suffix;
    };
}

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    // compile the swift stuff
    //
    // Compile all Swift sources together so they share one Swift module,
    // enabling direct Swift-to-Swift calls across files.
    const swift_build_cmd = b.addSystemCommand(&[_][]const u8{
        "swiftc",
        "-emit-object",
        "-parse-as-library",
        "src/auth.swift",
        "src/tray.swift",
    });

    const swift_step = b.step("build-swift", "Compile Swift UI/auth code");
    swift_step.dependOn(&swift_build_cmd.step);

    // We will also create a module for our other entry point, 'main.zig'.
    // const exe_mod = b.createModule(.{
    //     // `root_source_file` is the Zig "entry point" of the module. If a module
    //     // only contains e.g. external object files, you can make this `null`.
    //     // In this case the main source file is merely a path, however, in more
    //     // complicated build scripts, this could be a generated file.
    //     .root_source_file = b.path("src/main.zig"),
    //     .target = target,
    //     .optimize = optimize,
    // });

    // exe_mod.addCSourceFile("build/sw-auth.o", .{});
    // This creates another `std.Build.Step.Compile`, but this one builds an executable
    // rather than a static library.
    const exe = b.addExecutable(.{ .name = "zz", .root_source_file = b.path("src/main.zig"), .optimize = optimize, .target = target });

    exe.step.dependOn(swift_step);

    exe.addSystemIncludePath(.{ .cwd_relative = sdkPath("/macosx-sdks/include") });
    exe.addLibraryPath(.{ .cwd_relative = sdkPath("/macosx-sdks/lib") });
    exe.addLibraryPath(.{ .cwd_relative = sdkPath("/macosx-sdks/lib/swift") });
    exe.addSystemFrameworkPath(.{ .cwd_relative = sdkPath("/macosx-sdks/Frameworks") });

    // exe.addCSourceFile(.{ .file = b.path("sw-auth.o"), .flags = &.{} });
    exe.linkLibC();
    exe.addObjectFile(b.path("auth.o"));
    exe.addObjectFile(b.path("tray.o"));

    // link to swift libs
    // exe.addLibraryPath(b.path("libs/macosx/swift")); // or the actual path returned
    // exe.addSystemFrameworkPath(.{ .cwd_relative = b.path("libs/macosx/Foundation") });
    // exe.addSystemFrameworkPath(.{ .cwd_relative = sdkPath("/libs/macosx/Frameworks") });
    // exe.addSystemIncludePath(.{ .cwd_relative = sdkPath("/include") });

    exe.linkSystemLibrary("swiftCore");
    exe.linkSystemLibrary("swiftSwiftOnoneSupport"); // sometimes needed

    const swiftLibs = [_][]const u8{
        "swiftCore",
        "swiftCoreFoundation",
        "swiftDarwin",
        "swiftDispatch",
        "swiftIOKit",
        "swiftObjectiveC",
        "swiftXPC",
        // Swift overlays often required by AppKit usage
        "swiftCoreImage",
        "swiftMetal",
        "swiftQuartzCore",
        "swiftUniformTypeIdentifiers",
        "swiftos",
    };

    for (swiftLibs) |lib| {
        exe.linkSystemLibrary(lib);
    }
    // Transitive dependencies, explicit linkage of these works around
    // ziglang/zig#17130
    exe.linkFramework("CFNetwork");
    exe.linkFramework("ApplicationServices");
    exe.linkFramework("LocalAuthentication");
    exe.linkFramework("ColorSync");
    exe.linkFramework("CoreText");
    exe.linkFramework("ImageIO");
    exe.linkSystemLibrary("objc");

    exe.linkFramework("IOKit");
    exe.linkFramework("CoreFoundation");
    exe.linkFramework("AppKit");
    exe.linkFramework("CoreServices");
    exe.linkFramework("CoreGraphics");
    exe.linkFramework("QuartzCore");
    exe.linkFramework("CoreImage");
    exe.linkFramework("UniformTypeIdentifiers");
    exe.linkFramework("Metal");
    exe.linkFramework("Foundation");

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    b.installArtifact(exe);

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(exe);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        // .root_source_file = exe,
        // .root_module = exe_mod,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
