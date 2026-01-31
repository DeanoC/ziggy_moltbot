const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const use_system_zlib = b.option(bool, "use_system_zlib", "Use system zlib") orelse false;
    const enable_brotli = b.option(bool, "enable_brotli", "Build Brotli") orelse true;

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

    if (enable_brotli) {
        lib.root_module.addCMacro("FT_CONFIG_OPTION_USE_BROTLI", "1");
        if (b.lazyDependency("brotli", .{
            .target = target,
            .optimize = optimize,
        })) |dep| lib.linkLibrary(dep.artifact("brotli"));
    }

    lib.root_module.addCMacro("HAVE_UNISTD_H", "1");
    const cflags: []const []const u8 = if (target.result.os.tag == .emscripten)
        &[_][]const u8{
            "-fno-sanitize=undefined",
            "-mllvm",
            "-enable-emscripten-sjlj",
        }
    else
        &[_][]const u8{};
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
