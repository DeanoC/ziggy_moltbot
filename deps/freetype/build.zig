const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const use_system_zlib = b.option(bool, "use_system_zlib", "Use system zlib") orelse false;
    const enable_brotli = b.option(bool, "enable_brotli", "Build Brotli") orelse true;
    const enable_png = b.option(bool, "enable_png", "Build PNG support") orelse true;
    const emsdk_sysroot_include = b.option([]const u8, "emsdk_sysroot_include", "Emscripten sysroot include path");

    const lib_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
    });
    const lib = b.addLibrary(.{
        .name = "freetype",
        .root_module = lib_module,
        .linkage = .static,
    });
    lib.root_module.link_libc = true;
    lib.root_module.addIncludePath(b.path("include"));
    lib.root_module.addCMacro("FT2_BUILD_LIBRARY", "1");

    if (use_system_zlib) {
        lib.root_module.addCMacro("FT_CONFIG_OPTION_SYSTEM_ZLIB", "1");
    }

    const cflags: []const []const u8 = if (target.result.os.tag == .emscripten)
        &[_][]const u8{
            "-fno-sanitize=undefined",
            "-mllvm",
            "-enable-emscripten-sjlj",
        }
    else
        &[_][]const u8{};

    if (enable_brotli) {
        lib.root_module.addCMacro("FT_CONFIG_OPTION_USE_BROTLI", "1");
        if (b.lazyDependency("brotli", .{
            .target = target,
            .optimize = optimize,
        })) |dep| lib.linkLibrary(dep.artifact("brotli"));
    }

    if (enable_png) {
        lib.root_module.addCMacro("FT_CONFIG_OPTION_USE_PNG", "1");

        const libpng_src = b.lazyDependency("libpng_src", .{});
        const libpng_conf = b.lazyDependency("libpng", .{});
        const zlib_src = b.lazyDependency("zlib_src", .{});

        if (libpng_src) |png_src| {
            if (target.result.os.tag == .emscripten) if (emsdk_sysroot_include) |path| {
                lib.root_module.addSystemIncludePath(.{ .cwd_relative = path });
            };

            lib.root_module.addIncludePath(png_src.path(""));
            if (libpng_conf) |png_conf| {
                // pnglibconf.h lives in the wrapper root.
                lib.root_module.addIncludePath(png_conf.path(""));
            }

            var png_flags: std.ArrayList([]const u8) = .empty;
            defer png_flags.deinit(b.allocator);
            png_flags.appendSlice(b.allocator, &.{
                "-DPNG_ARM_NEON_OPT=0",
                "-DPNG_POWERPC_VSX_OPT=0",
                "-DPNG_INTEL_SSE_OPT=0",
                "-DPNG_MIPS_MSA_OPT=0",
            }) catch unreachable;
            if (cflags.len > 0) {
                png_flags.appendSlice(b.allocator, cflags) catch unreachable;
            }
            lib.root_module.addCSourceFiles(.{
                .root = png_src.path(""),
                .files = &png_sources,
                .flags = png_flags.items,
            });

            if (zlib_src) |z_src| {
                lib.root_module.addIncludePath(z_src.path(""));
                var zlib_flags: std.ArrayList([]const u8) = .empty;
                defer zlib_flags.deinit(b.allocator);
                zlib_flags.appendSlice(b.allocator, &.{
                    "-DHAVE_SYS_TYPES_H",
                    "-DHAVE_STDINT_H",
                    "-DHAVE_STDDEF_H",
                    "-DZ_HAVE_UNISTD_H",
                }) catch unreachable;
                if (cflags.len > 0) {
                    zlib_flags.appendSlice(b.allocator, cflags) catch unreachable;
                }
                lib.root_module.addCSourceFiles(.{
                    .root = z_src.path(""),
                    .files = &zlib_sources,
                    .flags = zlib_flags.items,
                });
            }
        }
    }

    lib.root_module.addCMacro("HAVE_UNISTD_H", "1");
    lib.root_module.addCSourceFiles(.{ .files = &sources, .flags = cflags });
    if (target.result.os.tag == .macos) lib.root_module.addCSourceFile(.{
        .file = b.path("src/base/ftmac.c"),
        .flags = cflags,
    });
    lib.installHeadersDirectory(b.path("include/freetype"), "freetype", .{});
    lib.installHeader(b.path("include/ft2build.h"), "ft2build.h");
    b.installArtifact(lib);
}

const sources = [_][]const u8{
    "src/autofit/autofit.c",
    "src/base/ftbase.c",
    "src/base/ftsystem.c",
    "src/base/ftdebug.c",
    "src/base/ftbbox.c",
    "src/base/ftbdf.c",
    "src/base/ftbitmap.c",
    "src/base/ftcid.c",
    "src/base/ftfstype.c",
    "src/base/ftgasp.c",
    "src/base/ftglyph.c",
    "src/base/ftgxval.c",
    "src/base/ftinit.c",
    "src/base/ftmm.c",
    "src/base/ftotval.c",
    "src/base/ftpatent.c",
    "src/base/ftpfr.c",
    "src/base/ftstroke.c",
    "src/base/ftsynth.c",
    "src/base/fttype1.c",
    "src/base/ftwinfnt.c",
    "src/bdf/bdf.c",
    "src/bzip2/ftbzip2.c",
    "src/cache/ftcache.c",
    "src/cff/cff.c",
    "src/cid/type1cid.c",
    "src/gzip/ftgzip.c",
    "src/lzw/ftlzw.c",
    "src/pcf/pcf.c",
    "src/pfr/pfr.c",
    "src/psaux/psaux.c",
    "src/pshinter/pshinter.c",
    "src/psnames/psnames.c",
    "src/raster/raster.c",
    "src/sdf/sdf.c",
    "src/sfnt/sfnt.c",
    "src/smooth/smooth.c",
    "src/svg/svg.c",
    "src/truetype/truetype.c",
    "src/type1/type1.c",
    "src/type42/type42.c",
    "src/winfonts/winfnt.c",
};

const png_sources = [_][]const u8{
    "png.c",
    "pngerror.c",
    "pngget.c",
    "pngmem.c",
    "pngpread.c",
    "pngread.c",
    "pngrio.c",
    "pngrtran.c",
    "pngrutil.c",
    "pngset.c",
    "pngtrans.c",
    "pngwio.c",
    "pngwrite.c",
    "pngwtran.c",
    "pngwutil.c",
};

const zlib_sources = [_][]const u8{
    "adler32.c",
    "crc32.c",
    "deflate.c",
    "infback.c",
    "inffast.c",
    "inflate.c",
    "inftrees.c",
    "trees.c",
    "zutil.c",
    "compress.c",
    "uncompr.c",
    "gzclose.c",
    "gzlib.c",
    "gzread.c",
    "gzwrite.c",
};
