const std = @import("std");
const zemscripten_build = @import("zemscripten");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const build_wasm = b.option(bool, "wasm", "Build wasm target") orelse false;

    const app_module = b.addModule("moltbot", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const ws_native = b.dependency("websocket", .{
        .target = target,
        .optimize = optimize,
    }).module("websocket");

    const zgui_pkg = b.dependency("zgui", .{
        .target = target,
        .optimize = optimize,
        .backend = .glfw_opengl3,
    });
    const zgui_native = zgui_pkg.module("root");

    const zglfw_pkg = b.dependency("zglfw", .{
        .target = target,
        .optimize = optimize,
    });
    const zglfw_native = zglfw_pkg.module("root");

    const native_module = b.createModule(.{
        .root_source_file = b.path("src/main_native.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "websocket", .module = ws_native },
            .{ .name = "zgui", .module = zgui_native },
            .{ .name = "zglfw", .module = zglfw_native },
            .{ .name = "moltbot", .module = app_module },
        },
    });

    const native_exe = b.addExecutable(.{
        .name = "moltbot-client",
        .root_module = native_module,
    });

    native_exe.root_module.addIncludePath(zgui_pkg.path("libs/imgui/backends"));
    native_exe.root_module.addCSourceFile(.{
        .file = b.path("src/opengl_loader.c"),
        .flags = &.{},
    });

    native_exe.linkLibrary(zgui_pkg.artifact("imgui"));
    native_exe.linkLibrary(zglfw_pkg.artifact("glfw"));

    switch (target.result.os.tag) {
        .linux => native_exe.root_module.linkSystemLibrary("GL", .{}),
        .windows => native_exe.root_module.linkSystemLibrary("opengl32", .{}),
        .macos => native_exe.root_module.linkFramework("OpenGL", .{}),
        else => {},
    }

    b.installArtifact(native_exe);

    const cli_module = b.createModule(.{
        .root_source_file = b.path("src/main_cli.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "websocket", .module = ws_native },
            .{ .name = "moltbot", .module = app_module },
        },
    });

    const cli_exe = b.addExecutable(.{
        .name = "moltbot-cli",
        .root_module = cli_module,
    });

    b.installArtifact(cli_exe);

    const run_cli_step = b.step("run-cli", "Run the CLI client");
    const run_cli_cmd = b.addRunArtifact(cli_exe);
    run_cli_step.dependOn(&run_cli_cmd.step);
    run_cli_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cli_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the native application");
    const run_cmd = b.addRunArtifact(native_exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const test_step = b.step("test", "Run tests");
    const test_files = [_][]const u8{
        "tests/protocol_tests.zig",
        "tests/client_tests.zig",
        "tests/logger_tests.zig",
        "tests/ui_tests.zig",
    };

    for (test_files) |test_path| {
        const test_mod = b.createModule(.{
            .root_source_file = b.path(test_path),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "moltbot", .module = app_module },
            },
        });
        const tests = b.addTest(.{ .root_module = test_mod });
        const run_tests = b.addRunArtifact(tests);
        test_step.dependOn(&run_tests.step);
    }

    if (build_wasm) {
        const wasm_target = b.resolveTargetQuery(.{
            .cpu_arch = .wasm32,
            .os_tag = .emscripten,
        });

        const wasm_module = b.createModule(.{
            .root_source_file = b.path("src/main_wasm.zig"),
            .target = wasm_target,
            .optimize = optimize,
        });

        const wasm = b.addLibrary(.{
            .name = "moltbot-client",
            .root_module = wasm_module,
            .linkage = .static,
        });

        const zemscripten = b.dependency("zemscripten", .{});
        wasm.root_module.addImport("zemscripten", zemscripten.module("root"));

        const emcc_flags = zemscripten_build.emccDefaultFlags(b.allocator, .{
            .optimize = optimize,
            .fsanitize = false,
        });
        var emcc_settings = zemscripten_build.emccDefaultSettings(b.allocator, .{
            .optimize = optimize,
            .emsdk_allocator = .emmalloc,
        });
        emcc_settings.put("ALLOW_MEMORY_GROWTH", "1") catch unreachable;

        const emcc_step = zemscripten_build.emccStep(
            b,
            &.{},
            &.{ wasm },
            .{
                .optimize = optimize,
                .flags = emcc_flags,
                .settings = emcc_settings,
                .use_preload_plugins = false,
                .embed_paths = null,
                .preload_paths = null,
                .shell_file_path = null,
                .js_library_path = null,
                .out_file_name = "moltbot-client.html",
                .install_dir = .{ .custom = "web" },
            },
        );

        const chmod_emcc = b.addSystemCommand(&.{ "chmod", "+x", zemscripten_build.emccPath(b) });
        emcc_step.dependOn(&chmod_emcc.step);

        b.getInstallStep().dependOn(emcc_step);
    }
}
