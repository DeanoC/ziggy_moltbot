const std = @import("std");
const android = @import("android");
const zemscripten_build = @import("zemscripten");

const FreetypeInfo = struct {
    lib: *std.Build.Step.Compile,
    include_path: std.Build.LazyPath,
};

fn addFreetype(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    emsdk_sysroot_include: ?[]const u8,
) FreetypeInfo {
    const freetype_dep = b.dependency("freetype", .{
        .target = target,
        .optimize = optimize,
        .enable_brotli = false,
        .emsdk_sysroot_include = emsdk_sysroot_include,
    });
    return .{
        .lib = freetype_dep.artifact("freetype"),
        .include_path = freetype_dep.path("include"),
    };
}

fn unzipToOutputDir(b: *std.Build, zip_file: std.Build.LazyPath, basename: []const u8) std.Build.LazyPath {
    const unzip = b.addSystemCommand(&.{ "unzip", "-q" });
    unzip.addFileArg(zip_file);
    unzip.addArg("-d");
    return unzip.addOutputDirectoryArg(basename);
}

fn downloadToOutputFile(b: *std.Build, url: []const u8, basename: []const u8) std.Build.LazyPath {
    // Zig 0.15's `zig fetch` can't consume some Maven endpoints due to headers.
    // For those, we download using curl and treat the result as a zip/aar to unzip.
    const curl = b.addSystemCommand(&.{ "curl", "-L", "--fail", "--silent", "--show-error", "-o" });
    const out = curl.addOutputFileArg(basename);
    curl.addArg(url);
    return out;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const build_wasm = b.option(bool, "wasm", "Build wasm target") orelse false;
    const android_targets = android.standardTargets(b, target);
    const build_android = android_targets.len > 0;
    const enable_ztracy = b.option(bool, "enable_ztracy", "Enable Tracy profile markers") orelse false;
    const enable_ztracy_android = b.option(bool, "enable_ztracy_android", "Enable Tracy client on Android (opt-in)") orelse false;
    const enable_tracy_fibers = b.option(bool, "enable_tracy_fibers", "Enable Tracy fiber support") orelse false;
    const tracy_on_demand = b.option(bool, "tracy_on_demand", "Build Tracy with TRACY_ON_DEMAND") orelse false;
    const tracy_callstack = b.option(u32, "tracy_callstack", "Tracy callstack depth (0=off)") orelse 0;
    const enable_wasm_perf_markers = b.option(bool, "enable_wasm_perf_markers", "On WASM, emit JS performance marks/measures for profiler zones") orelse false;
    const app_version = readAppVersion(b);
    const git_rev = readGitRev(b);
    const build_client = b.option(bool, "client", "Build native UI client") orelse true;
    const cli_operator = b.option(bool, "cli_operator", "Include operator client commands in ziggystarclaw-cli") orelse true;
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "app_version", app_version);
    build_options.addOption([]const u8, "git_rev", git_rev);
    build_options.addOption(bool, "enable_ztracy", enable_ztracy);
    build_options.addOption(bool, "enable_ztracy_android", enable_ztracy_android);
    build_options.addOption(bool, "enable_wasm_perf_markers", enable_wasm_perf_markers);
    build_options.addOption(bool, "cli_enable_operator", cli_operator);
    const app_module = b.addModule("ziggystarclaw", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    app_module.addIncludePath(b.path("src"));
    app_module.addOptions("build_options", build_options);

    const ws_native = b.dependency("websocket", .{
        .target = target,
        .optimize = optimize,
    }).module("websocket");
    app_module.addImport("websocket", ws_native);

    // Tracy profiling support:
    // profiler.zig uses @import("ztracy") when enable_ztracy is on, so any module
    // compiled with that option must have the import wired up (including app_module
    // used by tests).
    const ztracy_pkg = if (enable_ztracy) b.dependency("ztracy", .{
        .target = target,
        .optimize = optimize,
        .enable_ztracy = enable_ztracy,
        .enable_fibers = enable_tracy_fibers,
        .on_demand = tracy_on_demand,
        .callstack = tracy_callstack,
    }) else null;
    if (enable_ztracy) {
        app_module.addImport("ztracy", ztracy_pkg.?.module("root"));
    }

    // Allow building only the CLI (useful for node-mode / headless sandbox runs)
    // without pulling in UI deps.
    if (!build_client) {
        const cli_module = b.createModule(.{
            .root_source_file = b.path("main_cli_entry.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "websocket", .module = ws_native },
            },
        });
        if (enable_ztracy) {
            cli_module.addImport("ztracy", ztracy_pkg.?.module("root"));
        }

        const cli_exe = b.addExecutable(.{
            .name = "ziggystarclaw-cli",
            .root_module = cli_module,
        });
        cli_exe.root_module.addOptions("build_options", build_options);
        if (target.result.os.tag == .windows) {
            // For named-pipe supervisor control channel security descriptor helpers.
            cli_exe.root_module.linkSystemLibrary("advapi32", .{});
            // Windows screen monitor discovery uses user32 APIs.
            cli_exe.root_module.linkSystemLibrary("user32", .{});
        }
        if (enable_ztracy) {
            cli_exe.linkLibrary(ztracy_pkg.?.artifact("tracy"));
        }

        b.installArtifact(cli_exe);

        const run_cli_step = b.step("run-cli", "Run the CLI client");
        const run_cli_cmd = b.addRunArtifact(cli_exe);
        run_cli_step.dependOn(&run_cli_cmd.step);
        run_cli_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            run_cli_cmd.addArgs(args);
        }

        return;
    }
    if (!build_wasm) {
        const native_module = b.createModule(.{
            .root_source_file = b.path("src/main_native.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "websocket", .module = ws_native },
            },
        });
        native_module.addEmbedPath(b.path("assets/icons"));

        const native_exe = b.addExecutable(.{
            .name = "ziggystarclaw-client",
            .root_module = native_module,
        });
        native_exe.root_module.addOptions("build_options", build_options);
        const freetype_native = addFreetype(b, target, optimize, null);
        const sdl3_pkg = b.dependency("sdl3", .{
            .target = target,
            .optimize = optimize,
        });

        native_exe.root_module.addIncludePath(b.path("src"));
        native_exe.root_module.addIncludePath(sdl3_pkg.path("include"));
        native_exe.root_module.addCSourceFile(.{
            .file = b.path("src/icon_loader.c"),
            .flags = &.{},
        });
        native_exe.root_module.addIncludePath(freetype_native.include_path);
        const zgpu_pkg = b.dependency("zgpu", .{
            .target = target,
            .optimize = optimize,
        });
        native_module.addImport("zgpu", zgpu_pkg.module("root"));
        native_exe.root_module.addIncludePath(zgpu_pkg.path("libs/dawn/include"));
        if (enable_ztracy) {
            native_module.addImport("ztracy", ztracy_pkg.?.module("root"));
            native_exe.linkLibrary(ztracy_pkg.?.artifact("tracy"));
        }
        native_exe.root_module.addCSourceFile(.{
            .file = zgpu_pkg.path("src/dawn.cpp"),
            .flags = &.{ "-std=c++17", "-fno-sanitize=undefined" },
        });
        native_exe.root_module.addCSourceFile(.{
            .file = zgpu_pkg.path("src/dawn_proc.c"),
            .flags = &.{"-fno-sanitize=undefined"},
        });
        if (target.result.abi != .msvc) {
            native_exe.root_module.link_libcpp = true;
        }
        @import("zgpu").addLibraryPathsTo(native_exe);
        native_exe.root_module.linkSystemLibrary("dawn", .{});
        switch (target.result.os.tag) {
            .windows => {
                native_exe.root_module.linkSystemLibrary("ole32", .{});
                native_exe.root_module.linkSystemLibrary("dxguid", .{});
            },
            .macos => {
                native_exe.root_module.linkSystemLibrary("objc", .{});
                native_exe.root_module.linkFramework("Metal", .{});
                native_exe.root_module.linkFramework("CoreGraphics", .{});
                native_exe.root_module.linkFramework("Foundation", .{});
                native_exe.root_module.linkFramework("IOKit", .{});
                native_exe.root_module.linkFramework("IOSurface", .{});
                native_exe.root_module.linkFramework("QuartzCore", .{});
            },
            .linux => {
                native_exe.root_module.linkSystemLibrary("X11", .{});
            },
            else => {},
        }
        native_exe.linkLibrary(freetype_native.lib);
        native_exe.linkLibrary(sdl3_pkg.artifact("SDL3"));
        if (target.result.os.tag == .windows) {
            native_exe.root_module.addWin32ResourceFile(.{
                .file = b.path("assets/icons/ziggystarclaw.rc"),
            });
        }

        b.installArtifact(native_exe);
        // Ship a default example theme pack alongside the executable so theme packs work
        // consistently in dev (zig-out) and deployed installs.
        const clean_example_theme = b.addInstallDirectory(.{
            .source_dir = b.path("docs/theme_engine/examples/zsc_clean"),
            .install_dir = .bin,
            .install_subdir = "themes/zsc_clean",
        });
        b.getInstallStep().dependOn(&clean_example_theme.step);
        const showcase_example_theme = b.addInstallDirectory(.{
            .source_dir = b.path("docs/theme_engine/examples/zsc_showcase"),
            .install_dir = .bin,
            .install_subdir = "themes/zsc_showcase",
        });
        b.getInstallStep().dependOn(&showcase_example_theme.step);
        const brushed_metal_example_theme = b.addInstallDirectory(.{
            .source_dir = b.path("docs/theme_engine/examples/zsc_brushed_metal"),
            .install_dir = .bin,
            .install_subdir = "themes/zsc_brushed_metal",
        });
        b.getInstallStep().dependOn(&brushed_metal_example_theme.step);

        const cli_module = b.createModule(.{
            .root_source_file = b.path("main_cli_entry.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "websocket", .module = ws_native },
            },
        });

        const cli_exe = b.addExecutable(.{
            .name = "ziggystarclaw-cli",
            .root_module = cli_module,
        });
        cli_exe.root_module.addOptions("build_options", build_options);
        if (target.result.os.tag == .windows) {
            // For named-pipe supervisor control channel security descriptor helpers.
            cli_exe.root_module.linkSystemLibrary("advapi32", .{});
            // Windows screen monitor discovery uses user32 APIs.
            cli_exe.root_module.linkSystemLibrary("user32", .{});
        }
        if (enable_ztracy) {
            cli_module.addImport("ztracy", ztracy_pkg.?.module("root"));
            cli_exe.linkLibrary(ztracy_pkg.?.artifact("tracy"));
        }

        b.installArtifact(cli_exe);

        // Windows-only tray app (MVP): status + start/stop/restart + open logs.
        if (target.result.os.tag == .windows) {
            const tray_module = b.createModule(.{
                .root_source_file = b.path("src/main_tray.zig"),
                .target = target,
                .optimize = optimize,
            });
            const tray_exe = b.addExecutable(.{
                .name = "ziggystarclaw-tray",
                .root_module = tray_module,
            });
            tray_exe.linkLibC();
            tray_exe.subsystem = .Windows;
            tray_exe.root_module.addOptions("build_options", build_options);
            tray_exe.root_module.linkSystemLibrary("user32", .{});
            tray_exe.root_module.linkSystemLibrary("shell32", .{});
            tray_exe.root_module.linkSystemLibrary("gdi32", .{});
            tray_exe.root_module.linkSystemLibrary("advapi32", .{});
            tray_exe.root_module.addWin32ResourceFile(.{
                .file = b.path("assets/icons/ziggystarclaw.rc"),
            });
            b.installArtifact(tray_exe);
        }

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
            "tests/image_cache_tests.zig",
            "tests/update_checker_tests.zig",
            "tests/theme_engine_tests.zig",
            "tests/unified_config_programdata_tests.zig",
            "tests/docking_tests.zig",
            "tests/windows_camera_tests.zig",
            "tests/windows_screen_tests.zig",
            "tests/node_context_windows_camera_caps_tests.zig",
            "tests/node_context_windows_screen_caps_tests.zig",
            "tests/node_context_location_caps_tests.zig",
            "tests/command_router_location_tests.zig",
        };

        for (test_files) |test_path| {
            const test_mod = b.createModule(.{
                .root_source_file = b.path(test_path),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "ziggystarclaw", .module = app_module },
                },
            });
            test_mod.addIncludePath(b.path("src"));
            const tests = b.addTest(.{ .root_module = test_mod });
            tests.addCSourceFile(.{ .file = b.path("src/icon_loader.c"), .flags = &.{} });
            if (enable_ztracy) {
                tests.linkLibrary(ztracy_pkg.?.artifact("tracy"));
            }
            const run_tests = b.addRunArtifact(tests);
            test_step.dependOn(&run_tests.step);
        }
    }

    if (build_wasm) {
        const wasm_target = b.resolveTargetQuery(.{
            .cpu_arch = .wasm32,
            .os_tag = .emscripten,
        });
        const emsdk = b.dependency("emsdk", .{});
        const emsdk_sysroot = b.pathJoin(&.{
            emsdk.path("").getPath(b),
            "upstream",
            "emscripten",
            "cache",
            "sysroot",
        });
        const emsdk_sysroot_include = b.pathJoin(&.{ emsdk_sysroot, "include" });

        // Some deps (notably SDL3) require a sysroot when building for Emscripten.
        b.sysroot = emsdk_sysroot;

        const wasm_module = b.createModule(.{
            .root_source_file = b.path("src/main_wasm.zig"),
            .target = wasm_target,
            .optimize = optimize,
        });

        const wasm = b.addLibrary(.{
            .name = "ziggystarclaw-client",
            .root_module = wasm_module,
            .linkage = .static,
        });
        wasm.root_module.addOptions("build_options", build_options);

        wasm.root_module.addSystemIncludePath(.{ .cwd_relative = emsdk_sysroot_include });
        wasm.root_module.addIncludePath(b.path("src"));

        const zgpu_pkg = b.dependency("zgpu", .{
            .target = wasm_target,
            .optimize = optimize,
        });
        wasm_module.addImport("zgpu", zgpu_pkg.module("root"));
        @import("zgpu").addLibraryPathsTo(wasm);

        const sdl3_pkg = b.dependency("sdl3", .{
            .target = wasm_target,
            .optimize = optimize,
            .sanitize_c = .off,
        });
        wasm.root_module.addIncludePath(sdl3_pkg.path("include"));
        wasm.linkLibrary(sdl3_pkg.artifact("SDL3"));

        wasm.root_module.addCSourceFile(.{
            .file = b.path("src/icon_loader.c"),
            .flags = &.{"-fno-sanitize=undefined"},
        });

        const wasm_cpp_flags = &.{ "-std=c++17", "-fno-sanitize=undefined" };
        wasm.root_module.addCSourceFile(.{
            .file = b.path("src/wasm_ws.cpp"),
            .flags = wasm_cpp_flags,
        });
        wasm.root_module.addCSourceFile(.{
            .file = b.path("src/wasm_storage.cpp"),
            .flags = wasm_cpp_flags,
        });
        wasm.root_module.addCSourceFile(.{
            .file = b.path("src/wasm_open_url.cpp"),
            .flags = wasm_cpp_flags,
        });
        wasm.root_module.addCSourceFile(.{
            .file = b.path("src/wasm_fetch.cpp"),
            .flags = wasm_cpp_flags,
        });
        wasm.root_module.addCSourceFile(.{
            .file = b.path("src/wasm_clipboard_plain.cpp"),
            .flags = wasm_cpp_flags,
        });
        const freetype_wasm = addFreetype(b, wasm_target, optimize, emsdk_sysroot_include);
        freetype_wasm.lib.root_module.addSystemIncludePath(.{ .cwd_relative = emsdk_sysroot_include });
        wasm.linkLibrary(freetype_wasm.lib);
        wasm.root_module.addIncludePath(freetype_wasm.include_path);

        const zemscripten = b.dependency("zemscripten", .{});
        wasm.root_module.addImport("zemscripten", zemscripten.module("root"));

        var emcc_flags = zemscripten_build.emccDefaultFlags(b.allocator, .{
            .optimize = optimize,
            .fsanitize = false,
        });
        emcc_flags.put("--use-port=emdawnwebgpu", {}) catch unreachable;
        var emcc_settings = zemscripten_build.emccDefaultSettings(b.allocator, .{
            .optimize = optimize,
            .emsdk_allocator = .emmalloc,
        });
        emcc_settings.put("ALLOW_MEMORY_GROWTH", "1") catch unreachable;
        emcc_settings.put("SUPPORT_LONGJMP", "1") catch unreachable;
        emcc_settings.put("ASYNCIFY", "1") catch unreachable;
        emcc_settings.put(
            "EXPORTED_FUNCTIONS",
            "['_main','_malloc','_free','_molt_ws_on_open','_molt_ws_on_close','_molt_ws_on_error','_molt_ws_on_message','_zsc_wasm_fetch_on_success','_zsc_wasm_fetch_on_error','_zsc_wasm_on_paste']",
        ) catch unreachable;
        emcc_settings.put(
            "EXPORTED_RUNTIME_METHODS",
            "['UTF8ToString','stringToUTF8','lengthBytesUTF8','setCanvasSize']",
        ) catch unreachable;

        const emcc_step = zemscripten_build.emccStep(
            b,
            &.{},
            &.{wasm},
            .{
                .optimize = optimize,
                .flags = emcc_flags,
                .settings = emcc_settings,
                .use_preload_plugins = false,
                .embed_paths = null,
                .preload_paths = null,
                .shell_file_path = b.path("web/shell.html"),
                // Optional: map profiler zones to Performance marks/measures so Chrome/Firefox traces
                // show the same zone names as native Tracy.
                .js_library_path = if (enable_wasm_perf_markers) b.path("web/zsc_perf_markers.js") else null,
                .out_file_name = "ziggystarclaw-client.html",
                .install_dir = .{ .custom = "web" },
            },
        );

        const web_assets = b.addInstallDirectory(.{
            .source_dir = b.path("web"),
            .install_dir = .{ .custom = "web" },
            .install_subdir = "",
        });
        emcc_step.dependOn(&web_assets.step);

        if (target.result.os.tag != .windows) {
            const chmod_emcc = b.addSystemCommand(&.{ "chmod", "+x", zemscripten_build.emccPath(b) });
            emcc_step.dependOn(&chmod_emcc.step);
        }

        b.getInstallStep().dependOn(emcc_step);
    }

    if (build_android) {
        const android_sdk = android.Sdk.create(b, .{});
        const build_tools_version = b.option(
            []const u8,
            "android-build-tools",
            "Android build tools version (eg. 35.0.0)",
        ) orelse "35.0.0";
        const ndk_version = b.option(
            []const u8,
            "android-ndk",
            "Android NDK version (eg. 27.0.12077973)",
        ) orelse "27.0.12077973";
        const api_level_value = b.option(
            u32,
            "android-api",
            "Android API level (eg. 34)",
        ) orelse 34;

        const apk = android_sdk.createApk(.{
            .build_tools_version = build_tools_version,
            .ndk_version = ndk_version,
            .api_level = @enumFromInt(api_level_value),
        });

        apk.setAndroidManifest(b.path("android/AndroidManifest.xml"));
        const android_res = b.addWriteFiles();
        _ = android_res.addCopyFile(b.path("android/res/values/strings.xml"), "values/strings.xml");
        _ = android_res.addCopyFile(b.path("android/res/drawable/app_icon.png"), "drawable/app_icon.png");
        apk.addResourceDirectory(android_res.getDirectory());
        apk.setKeyStore(android_sdk.createKeyStore(.example));

        // Consume SDL3's classes.jar from the official Android AAR.
        const sdl3_android_zip = b.dependency("sdl3_android_zip", .{});
        const sdl3_aar = sdl3_android_zip.path("SDL3-3.2.28.aar");
        const sdl3_aar_extracted = unzipToOutputDir(b, sdl3_aar, "sdl3_android_aar");
        apk.addJavaLibraryJar(sdl3_aar_extracted.path(b, "classes.jar"));

        for (android_targets) |android_target| {
            // Keep Android scope small for now.
            if (android_target.result.cpu.arch != .aarch64) continue;

            const android_module = b.createModule(.{
                .root_source_file = b.path("src/main_android_wgpu.zig"),
                .target = android_target,
                .optimize = optimize,
            });
            const freetype_android = addFreetype(b, android_target, optimize, null);

            const android_lib = b.addLibrary(.{
                // SDL's Android Java glue expects the app library to be `libmain.so`.
                .name = "main",
                .root_module = android_module,
                .linkage = .dynamic,
            });
            android_lib.root_module.addOptions("build_options", build_options);
            android_lib.root_module.addIncludePath(b.path("src"));
            android_lib.root_module.link_libc = true;
            android_lib.root_module.addSystemIncludePath(.{ .cwd_relative = apk.ndk.include_path });
            android_lib.root_module.addCSourceFile(.{
                .file = b.path("src/icon_loader.c"),
                .flags = &.{"-fno-sanitize=undefined"},
            });
            android_lib.root_module.addIncludePath(freetype_android.include_path);

            android_lib.linkLibrary(freetype_android.lib);

            // SDL3 headers (for @cImport) are consumed from the Zig SDL3 dependency, but the Android
            // native library + Java classes come from the official SDL3 Android AAR.
            const sdl3_headers = b.dependency("sdl3", .{ .target = android_target, .optimize = optimize });
            android_lib.root_module.addIncludePath(sdl3_headers.path("include"));

            const zgpu_pkg = b.dependency("zgpu", .{ .target = android_target, .optimize = optimize });
            android_module.addImport("zgpu", zgpu_pkg.module("root"));
            const ws_android = b.dependency("websocket", .{ .target = android_target, .optimize = optimize }).module("websocket");
            android_module.addImport("websocket", ws_android);

            if (enable_ztracy and enable_ztracy_android) {
                const ztracy_android = b.dependency("ztracy", .{
                    .target = android_target,
                    .optimize = optimize,
                    .enable_ztracy = enable_ztracy,
                    .enable_fibers = enable_tracy_fibers,
                    .on_demand = tracy_on_demand,
                    .callstack = tracy_callstack,
                });
                android_module.addImport("ztracy", ztracy_android.module("root"));
                android_lib.linkLibrary(ztracy_android.artifact("tracy"));
                // Tracy client is C++; ensure libc++ is available when linking.
                android_lib.root_module.link_libcpp = true;
            }

            const sdl3_lib_dir = sdl3_aar_extracted.path(b, "prefab/modules/SDL3-shared/libs/android.arm64-v8a");
            android_lib.root_module.addLibraryPath(sdl3_lib_dir);
            android_lib.root_module.linkSystemLibrary("SDL3", .{});
            apk.addNativeLibraryFile(.{
                .file = sdl3_lib_dir.path(b, "libSDL3.so"),
                .abi = "arm64-v8a",
                .dest_name = "libSDL3.so",
            });

            const webgpu_aar = downloadToOutputFile(
                b,
                "https://dl.google.com/dl/android/maven2/androidx/webgpu/webgpu/1.0.0-alpha03/webgpu-1.0.0-alpha03.aar",
                "webgpu-1.0.0-alpha03.aar",
            );
            const webgpu_aar_extracted = unzipToOutputDir(b, webgpu_aar, "androidx_webgpu_aar");
            const webgpu_lib_dir = webgpu_aar_extracted.path(b, "jni/arm64-v8a");
            android_lib.root_module.addLibraryPath(webgpu_lib_dir);
            android_lib.root_module.linkSystemLibrary("webgpu_c_bundled", .{});
            apk.addNativeLibraryFile(.{
                .file = webgpu_lib_dir.path(b, "libwebgpu_c_bundled.so"),
                .abi = "arm64-v8a",
                .dest_name = "libwebgpu_c_bundled.so",
            });

            // Android system libs commonly required by SDL + native WebGPU builds.
            android_lib.root_module.linkSystemLibrary("log", .{});
            android_lib.root_module.linkSystemLibrary("android", .{});
            android_lib.root_module.linkSystemLibrary("dl", .{});

            apk.addArtifact(android_lib);
        }

        const apk_install = apk.addInstallApk();
        const apk_step = b.step("apk", "Build Android APK");
        apk_step.dependOn(&apk_install.step);
        b.getInstallStep().dependOn(&apk_install.step);
    }

    // ---------------------------------------------------------------------
    // Node port scaffolding (Android + WASM)
    //
    // These are compile-only stubs that establish a place for platform-specific
    // node runtime glue without impacting the default desktop builds or CI.
    //
    // Usage:
    //   zig build node-ports
    //
    const node_ports_step = b.step("node-ports", "Build Android/WASM node scaffolding stubs");

    // WASM: use wasm32-freestanding to avoid requiring emsdk for this scaffold.
    const wasm_scaffold_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const wasm_scaffold_mod = b.createModule(.{
        .root_source_file = b.path("src/node/ports/wasm_scaffold.zig"),
        .target = wasm_scaffold_target,
        .optimize = optimize,
    });
    const wasm_scaffold_lib = b.addLibrary(.{
        .name = "zsc_node_wasm_scaffold",
        .root_module = wasm_scaffold_mod,
        .linkage = .static,
    });
    const wasm_scaffold_install = b.addInstallArtifact(wasm_scaffold_lib, .{});
    node_ports_step.dependOn(&wasm_scaffold_install.step);

    // Android: pick a single ABI for now (aarch64). This is just a compile-time
    // scaffold library; it does not require NDK headers.
    const android_scaffold_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .linux,
        .abi = .android,
    });
    const android_scaffold_mod = b.createModule(.{
        .root_source_file = b.path("src/node/ports/android_scaffold.zig"),
        .target = android_scaffold_target,
        .optimize = optimize,
    });
    const android_scaffold_lib = b.addLibrary(.{
        .name = "zsc_node_android_scaffold",
        .root_module = android_scaffold_mod,
        .linkage = .static,
    });
    const android_scaffold_install = b.addInstallArtifact(android_scaffold_lib, .{});
    node_ports_step.dependOn(&android_scaffold_install.step);

    // ---------------------------------------------------------------------
    // WASM node runtime (connect-only skeleton)
    //
    // This produces a standalone `.wasm` module for a future node runtime.
    // It is intentionally freestanding-friendly and does not require emsdk.
    //
    // Usage:
    //   zig build node-wasm
    //
    const node_wasm_step = b.step("node-wasm", "Build WASM node runtime (connect-only skeleton)");
    const wasm_node_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const wasm_node_mod = b.createModule(.{
        .root_source_file = b.path("src/node/wasm/main.zig"),
        .target = wasm_node_target,
        .optimize = optimize,
    });
    const wasm_node_exe = b.addExecutable(.{
        .name = "ziggystarclaw-node",
        .root_module = wasm_node_mod,
    });
    wasm_node_exe.root_module.addOptions("build_options", build_options);

    // No `_start`/`main` entrypoint yet; this module is driven by exports.
    wasm_node_exe.entry = .disabled;
    // Keep exports visible when linking; exports are also marked `export`.
    wasm_node_exe.rdynamic = true;

    const wasm_node_install = b.addInstallArtifact(wasm_node_exe, .{});
    node_wasm_step.dependOn(&wasm_node_install.step);

    // ---------------------------------------------------------------------
    // Android node runtime (connect-only skeleton)
    //
    // This produces a static library for a future Android node runtime.
    // It is intentionally libc/NDK independent so it can cross-compile on CI.
    //
    // Usage:
    //   zig build node-android
    //
    const node_android_step = b.step("node-android", "Build Android node runtime (connect-only skeleton)");
    const android_node_target = b.resolveTargetQuery(.{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .android });
    const android_node_mod = b.createModule(.{
        .root_source_file = b.path("src/node/android/main.zig"),
        .target = android_node_target,
        .optimize = optimize,
    });
    const android_node_lib = b.addLibrary(.{
        .name = "zsc_node_android",
        .root_module = android_node_mod,
        .linkage = .static,
    });
    android_node_lib.root_module.addOptions("build_options", build_options);
    android_node_lib.root_module.link_libc = false;
    android_node_lib.root_module.link_libcpp = false;

    const android_node_install = b.addInstallArtifact(android_node_lib, .{});
    node_android_step.dependOn(&android_node_install.step);
}

fn readAppVersion(b: *std.Build) []const u8 {
    const data = std.fs.cwd().readFileAlloc(b.allocator, "build.zig.zon", 64 * 1024) catch return "0.0.0";
    const needle = ".version";
    const idx = std.mem.indexOf(u8, data, needle) orelse return "0.0.0";
    const slice = data[idx..];
    const quote_start = std.mem.indexOfScalar(u8, slice, '"') orelse return "0.0.0";
    const after_start = slice[quote_start + 1 ..];
    const quote_end = std.mem.indexOfScalar(u8, after_start, '"') orelse return "0.0.0";
    return after_start[0..quote_end];
}

fn readGitRev(b: *std.Build) []const u8 {
    const res = std.process.Child.run(.{
        .allocator = b.allocator,
        .argv = &.{ "git", "rev-parse", "--short", "HEAD" },
    }) catch return "unknown";
    defer b.allocator.free(res.stdout);
    defer b.allocator.free(res.stderr);

    const rev_trim = std.mem.trim(u8, res.stdout, " \t\r\n");
    if (rev_trim.len == 0) return "unknown";

    const base = b.allocator.dupe(u8, rev_trim) catch return "unknown";

    // Mark dirty working tree (best effort). This helps avoid “wait, am I running the latest exe?”
    const res2 = std.process.Child.run(.{
        .allocator = b.allocator,
        .argv = &.{ "git", "status", "--porcelain" },
    }) catch return base;
    defer b.allocator.free(res2.stdout);
    defer b.allocator.free(res2.stderr);

    const dirty = std.mem.trim(u8, res2.stdout, " \t\r\n");
    if (dirty.len == 0) return base;

    return std.fmt.allocPrint(b.allocator, "{s}-dirty", .{base}) catch base;
}
