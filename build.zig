const std = @import("std");
const android = @import("android");
const zemscripten_build = @import("zemscripten");

const FreetypeInfo = struct {
    lib: *std.Build.Step.Compile,
    include_path: std.Build.LazyPath,
};

fn addFreetype(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) FreetypeInfo {
    const freetype_dep = b.dependency("freetype", .{
        .target = target,
        .optimize = optimize,
        .enable_brotli = false,
    });
    return .{
        .lib = freetype_dep.artifact("freetype"),
        .include_path = freetype_dep.path("include"),
    };
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const build_wasm = b.option(bool, "wasm", "Build wasm target") orelse false;
    const android_targets = android.standardTargets(b, target);
    const build_android = android_targets.len > 0;
    const app_version = readAppVersion(b);
    const use_webgpu = b.option(bool, "webgpu", "Enable WebGPU renderer") orelse false;
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "app_version", app_version);
    build_options.addOption(bool, "use_webgpu", use_webgpu);
    const imgui_cpp_flags = &.{
        "-std=c++17",
        "-DIMGUI_ENABLE_FREETYPE",
        "-DIMGUI_USE_WCHAR32",
    };

    const app_module = b.addModule("ziggystarclaw", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    app_module.addIncludePath(b.path("src"));

    const ws_native = b.dependency("websocket", .{
        .target = target,
        .optimize = optimize,
    }).module("websocket");
    app_module.addImport("websocket", ws_native);


    const zgui_pkg = blk: {
        if (use_webgpu) {
            break :blk b.dependency("zgui", .{
                .target = target,
                .optimize = optimize,
                .backend = .glfw_wgpu,
                .use_wchar32 = true,
            });
        } else {
            break :blk b.dependency("zgui", .{
                .target = target,
                .optimize = optimize,
                .backend = .glfw_opengl3,
                .use_wchar32 = true,
            });
        }
    };
    const zgui_native = zgui_pkg.module("root");

    const zglfw_pkg = b.dependency("zglfw", .{
        .target = target,
        .optimize = optimize,
    });
    const zglfw_native = zglfw_pkg.module("root");

    if (!build_wasm) {
        const native_module = b.createModule(.{
            .root_source_file = b.path("src/main_native.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "websocket", .module = ws_native },
                .{ .name = "zgui", .module = zgui_native },
                .{ .name = "zglfw", .module = zglfw_native },
            },
        });
        native_module.addEmbedPath(b.path("assets/icons"));

        const native_exe = b.addExecutable(.{
            .name = "ziggystarclaw-client",
            .root_module = native_module,
        });
        native_exe.root_module.addOptions("build_options", build_options);
        const freetype_native = addFreetype(b, target, optimize);

        native_exe.root_module.addIncludePath(b.path("src"));
        native_exe.root_module.addIncludePath(zgui_pkg.path("libs/imgui"));
        native_exe.root_module.addCSourceFile(.{
            .file = b.path("src/icon_loader.c"),
            .flags = &.{},
        });
        native_exe.root_module.addCSourceFile(.{
            .file = b.path("src/imgui_ini_bridge.cpp"),
            .flags = imgui_cpp_flags,
        });
        native_exe.root_module.addCSourceFile(.{
            .file = b.path("src/imgui_freetype_bridge.cpp"),
            .flags = imgui_cpp_flags,
        });
        native_exe.root_module.addIncludePath(freetype_native.include_path);

        const zgui_imgui = zgui_pkg.artifact("imgui");
        zgui_imgui.root_module.addCMacro("IMGUI_ENABLE_FREETYPE", "");
        zgui_imgui.root_module.addCMacro("IMGUI_USE_WCHAR32", "");
        zgui_imgui.root_module.addIncludePath(freetype_native.include_path);
        zgui_imgui.root_module.addCSourceFile(.{
            .file = zgui_pkg.path("libs/imgui/misc/freetype/imgui_freetype.cpp"),
            .flags = imgui_cpp_flags,
        });
        if (use_webgpu) {
            const zgpu_pkg = b.dependency("zgpu", .{
                .target = target,
                .optimize = optimize,
            });
            native_module.addImport("zgpu", zgpu_pkg.module("root"));
            if (target.result.os.tag != .emscripten) {
                zgui_imgui.root_module.addCMacro("IMGUI_IMPL_WEBGPU_BACKEND_DAWN", "");
            }
            native_exe.root_module.addIncludePath(zgpu_pkg.path("libs/dawn/include"));
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
                else => {},
            }
        } else {
            native_exe.root_module.addIncludePath(zgui_pkg.path("libs/imgui/backends"));
            native_exe.root_module.addCSourceFile(.{
                .file = b.path("src/opengl_loader.c"),
                .flags = &.{},
            });
            switch (target.result.os.tag) {
                .linux => native_exe.root_module.linkSystemLibrary("GL", .{}),
                .windows => native_exe.root_module.linkSystemLibrary("opengl32", .{}),
                .macos => native_exe.root_module.linkFramework("OpenGL", .{}),
                else => {},
            }
        }

        native_exe.linkLibrary(zgui_imgui);
        native_exe.linkLibrary(freetype_native.lib);
        native_exe.linkLibrary(zglfw_pkg.artifact("glfw"));
        if (target.result.os.tag == .windows) {
            native_exe.root_module.addWin32ResourceFile(.{
                .file = b.path("assets/icons/ziggystarclaw.rc"),
            });
        }

        b.installArtifact(native_exe);

        const cli_module = b.createModule(.{
            .root_source_file = b.path("src/main_cli.zig"),
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
            "tests/image_cache_tests.zig",
            "tests/update_checker_tests.zig",
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

        const zgui_wasm_pkg = b.dependency("zgui", .{
            .target = wasm_target,
            .optimize = optimize,
            .backend = .no_backend,
            .use_wchar32 = true,
        });
        const zglfw_wasm_pkg = b.dependency("zglfw", .{
            .target = wasm_target,
            .optimize = optimize,
        });
        wasm.root_module.addImport("zgui", zgui_wasm_pkg.module("root"));
        wasm.root_module.addImport("zglfw", zglfw_wasm_pkg.module("root"));
        wasm.root_module.addSystemIncludePath(.{ .cwd_relative = emsdk_sysroot_include });
        wasm.root_module.addIncludePath(b.path("src"));
        wasm.root_module.addIncludePath(zgui_wasm_pkg.path("libs"));
        wasm.root_module.addIncludePath(zgui_wasm_pkg.path("libs/imgui"));
        wasm.root_module.addIncludePath(zgui_wasm_pkg.path("libs/imgui/backends"));
        // freetype include path added after freetype_wasm is created
        const imgui_backend_flags = &.{
            "-DIMGUI_IMPL_OPENGL_ES3",
            "-DIMGUI_IMPL_API=extern \"C\"",
            "-fno-sanitize=undefined",
            "-DIMGUI_DISABLE_OBSOLETE_FUNCTIONS",
            "-DIMGUI_ENABLE_FREETYPE",
            "-DIMGUI_USE_WCHAR32",
            "-std=c++17",
        };
        wasm.root_module.addCSourceFile(.{
            .file = zgui_wasm_pkg.path("libs/imgui/backends/imgui_impl_glfw.cpp"),
            .flags = imgui_backend_flags,
        });
        wasm.root_module.addCSourceFile(.{
            .file = zgui_wasm_pkg.path("libs/imgui/backends/imgui_impl_opengl3.cpp"),
            .flags = imgui_backend_flags,
        });
        wasm.root_module.addCSourceFile(.{
            .file = b.path("src/icon_loader.c"),
            .flags = &.{ "-fno-sanitize=undefined" },
        });
        wasm.root_module.addCSourceFile(.{
            .file = b.path("src/wasm_clipboard.cpp"),
            .flags = imgui_backend_flags,
        });
        wasm.root_module.addCSourceFile(.{
            .file = b.path("src/wasm_ws.cpp"),
            .flags = imgui_backend_flags,
        });
        wasm.root_module.addCSourceFile(.{
            .file = b.path("src/wasm_storage.cpp"),
            .flags = imgui_backend_flags,
        });
        wasm.root_module.addCSourceFile(.{
            .file = b.path("src/wasm_open_url.cpp"),
            .flags = imgui_backend_flags,
        });
        wasm.root_module.addCSourceFile(.{
            .file = b.path("src/imgui_ini_bridge.cpp"),
            .flags = imgui_backend_flags,
        });
        wasm.root_module.addCSourceFile(.{
            .file = b.path("src/imgui_freetype_bridge.cpp"),
            .flags = imgui_backend_flags,
        });
        wasm.root_module.addCSourceFile(.{
            .file = b.path("src/wasm_fetch.cpp"),
            .flags = imgui_backend_flags,
        });
        const zgui_wasm_imgui = zgui_wasm_pkg.artifact("imgui");
        const freetype_wasm = addFreetype(b, wasm_target, optimize);
        freetype_wasm.lib.root_module.addSystemIncludePath(.{ .cwd_relative = emsdk_sysroot_include });
        zgui_wasm_imgui.root_module.addCMacro("IMGUI_ENABLE_FREETYPE", "");
        zgui_wasm_imgui.root_module.addCMacro("IMGUI_USE_WCHAR32", "");
        zgui_wasm_imgui.root_module.addIncludePath(freetype_wasm.include_path);
        zgui_wasm_imgui.root_module.addCSourceFile(.{
            .file = zgui_wasm_pkg.path("libs/imgui/misc/freetype/imgui_freetype.cpp"),
            .flags = imgui_backend_flags,
        });
        zgui_wasm_imgui.root_module.addSystemIncludePath(.{ .cwd_relative = emsdk_sysroot_include });
        wasm.linkLibrary(zgui_wasm_imgui);
        wasm.linkLibrary(freetype_wasm.lib);
        wasm.root_module.addIncludePath(freetype_wasm.include_path);

        const zemscripten = b.dependency("zemscripten", .{});
        wasm.root_module.addImport("zemscripten", zemscripten.module("root"));

        var emcc_flags = zemscripten_build.emccDefaultFlags(b.allocator, .{
            .optimize = optimize,
            .fsanitize = false,
        });
        emcc_flags.put("-sUSE_GLFW=3", {}) catch unreachable;
        emcc_flags.put("-sUSE_WEBGL2=1", {}) catch unreachable;
        emcc_flags.put("-sFULL_ES3=1", {}) catch unreachable;
        emcc_flags.put("-sGL_ENABLE_GET_PROC_ADDRESS=1", {}) catch unreachable;
        var emcc_settings = zemscripten_build.emccDefaultSettings(b.allocator, .{
            .optimize = optimize,
            .emsdk_allocator = .emmalloc,
        });
        emcc_settings.put("ALLOW_MEMORY_GROWTH", "1") catch unreachable;
        emcc_settings.put("SUPPORT_LONGJMP", "1") catch unreachable;
        emcc_settings.put(
            "EXPORTED_FUNCTIONS",
            "['_main','_malloc','_free','_molt_ws_on_open','_molt_ws_on_close','_molt_ws_on_error','_molt_ws_on_message','_zsc_wasm_fetch_on_success','_zsc_wasm_fetch_on_error']",
        ) catch unreachable;
        emcc_settings.put(
            "EXPORTED_RUNTIME_METHODS",
            "['UTF8ToString','stringToUTF8','lengthBytesUTF8']",
        ) catch unreachable;

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
                .shell_file_path = b.path("web/shell.html"),
                .js_library_path = null,
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

        const sdl_java_root = b.dependency("SDL", .{
            .target = target,
            .optimize = optimize,
            .use_hidapi = false,
        }).path("android-project/app/src/main/java/org/libsdl/app");
        const sdl_java_files = &[_][]const u8{
            "SDL.java",
            "SDLSurface.java",
            "SDLActivity.java",
            "SDLAudioManager.java",
            "SDLControllerManager.java",
            "HIDDevice.java",
            "HIDDeviceUSB.java",
            "HIDDeviceManager.java",
            "HIDDeviceBLESteamController.java",
        };
        apk.addJavaSourceFiles(.{
            .root = sdl_java_root,
            .files = sdl_java_files,
        });

        for (android_targets) |android_target| {
            const android_module = b.createModule(.{
                .root_source_file = b.path("src/main_android.zig"),
                .target = android_target,
                .optimize = optimize,
            });
            const ws_android = b.dependency("websocket", .{
                .target = android_target,
                .optimize = optimize,
            }).module("websocket");
            const zgui_android_pkg = b.dependency("zgui", .{
                .target = android_target,
                .optimize = optimize,
                .backend = .no_backend,
                .use_wchar32 = true,
            });
            const freetype_android = addFreetype(b, android_target, optimize);
            android_module.addImport("websocket", ws_android);
            android_module.addImport("zgui", zgui_android_pkg.module("root"));

            const android_lib = b.addLibrary(.{
                .name = "ziggystarclaw_android",
                .root_module = android_module,
                .linkage = .dynamic,
            });
            android_lib.root_module.addOptions("build_options", build_options);
            android_lib.root_module.addIncludePath(b.path("src"));
            android_lib.root_module.link_libc = true;
            android_lib.root_module.link_libcpp = true;
            android_lib.root_module.linkSystemLibrary("GLESv2", .{});
            android_lib.root_module.linkSystemLibrary("EGL", .{});
            android_lib.root_module.addSystemIncludePath(.{ .cwd_relative = apk.ndk.include_path });
            android_lib.root_module.addCSourceFile(.{
                .file = b.path("src/android_hid_stub.c"),
                .flags = &.{},
            });
            android_lib.root_module.addCSourceFile(.{
                .file = b.path("src/icon_loader.c"),
                .flags = &.{ "-fno-sanitize=undefined" },
            });
            android_lib.root_module.addCSourceFile(.{
                .file = b.path("src/imgui_ini_bridge.cpp"),
                .flags = imgui_cpp_flags,
            });
            android_lib.root_module.addCSourceFile(.{
                .file = b.path("src/imgui_freetype_bridge.cpp"),
                .flags = imgui_cpp_flags,
            });
            android_lib.root_module.addIncludePath(freetype_android.include_path);

            const sdl_dep = b.dependency("SDL", .{
                .target = android_target,
                .optimize = optimize,
                .use_hidapi = false,
            });
            const sdl_lib = sdl_dep.artifact("SDL2");
            sdl_lib.root_module.addCMacro("SDL_HIDAPI_DISABLED", "1");
            sdl_lib.root_module.addCMacro("SDL_JOYSTICK_HIDAPI", "0");
            android_lib.root_module.addIncludePath(sdl_dep.path("include"));
            android_lib.root_module.addIncludePath(sdl_dep.path("include-pregen"));
            android_lib.linkLibrary(sdl_lib);

            const zgui_imgui = zgui_android_pkg.artifact("imgui");
            zgui_imgui.root_module.link_libcpp = false;
            zgui_imgui.root_module.link_libc = true;
            zgui_imgui.root_module.addIncludePath(sdl_dep.path("include"));
            zgui_imgui.root_module.addIncludePath(sdl_dep.path("include-pregen"));
            zgui_imgui.root_module.addCMacro("IMGUI_ENABLE_FREETYPE", "");
            zgui_imgui.root_module.addCMacro("IMGUI_USE_WCHAR32", "");
            zgui_imgui.root_module.addIncludePath(freetype_android.include_path);
            zgui_imgui.root_module.addCSourceFile(.{
                .file = zgui_android_pkg.path("libs/imgui/misc/freetype/imgui_freetype.cpp"),
                .flags = imgui_cpp_flags,
            });
            android_lib.root_module.addIncludePath(zgui_android_pkg.path("libs"));
            android_lib.root_module.addIncludePath(zgui_android_pkg.path("libs/imgui"));
            android_lib.root_module.addIncludePath(zgui_android_pkg.path("libs/imgui/backends"));
            android_lib.root_module.addCSourceFile(.{
                .file = b.path("src/imgui_impl_sdl2_android.cpp"),
                .flags = &.{
                    "-DIMGUI_IMPL_API=extern \"C\"",
                    "-fno-sanitize=undefined",
                    "-DIMGUI_DISABLE_OBSOLETE_FUNCTIONS",
                    "-DIMGUI_ENABLE_FREETYPE",
                    "-DIMGUI_USE_WCHAR32",
                },
            });
            android_lib.root_module.addCSourceFile(.{
                .file = zgui_android_pkg.path("libs/imgui/backends/imgui_impl_opengl3.cpp"),
                .flags = &.{
                    "-DIMGUI_IMPL_OPENGL_ES2",
                    "-DIMGUI_IMPL_API=extern \"C\"",
                    "-fno-sanitize=undefined",
                    "-DIMGUI_DISABLE_OBSOLETE_FUNCTIONS",
                    "-DIMGUI_ENABLE_FREETYPE",
                    "-DIMGUI_USE_WCHAR32",
                },
            });
            android_lib.linkLibrary(zgui_imgui);
            android_lib.linkLibrary(freetype_android.lib);

            apk.addArtifact(android_lib);
        }

        const apk_install = apk.addInstallApk();
        const apk_step = b.step("apk", "Build Android APK");
        apk_step.dependOn(&apk_install.step);
        b.getInstallStep().dependOn(&apk_install.step);
    }
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
