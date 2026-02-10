const std = @import("std");
const builtin = @import("builtin");
const data_uri = @import("data_uri.zig");
const wasm_fetch = @import("../platform/wasm_fetch.zig");
const profiler = @import("../utils/profiler.zig");
const image_fetch = if (builtin.cpu.arch == .wasm32)
    struct {
        pub fn fetchHttpBytes(_: std.mem.Allocator, _: []const u8) ![]u8 {
            return error.Unsupported;
        }
    }
else
    @import("image_fetch.zig");

const icon = @cImport({
    @cInclude("icon_loader.h");
});

pub const ImageState = enum {
    loading,
    ready,
    failed,
};

pub const ImageEntryView = struct {
    state: ImageState,
    texture_id: u32,
    width: u32,
    height: u32,
    pixels: ?[]const u8,
    error_message: ?[]const u8,
};

const ImageEntry = struct {
    state: ImageState,
    texture_id: u32,
    width: u32,
    height: u32,
    bytes: usize,
    last_used_ms: i64,
    pixels: ?[]u8,
    error_message: ?[]u8,
};

const FetchContext = struct {
    cache: *ImageCache,
    url: []u8,
};

pub const ImageCache = struct {
    allocator: std.mem.Allocator,
    entries: std.StringHashMap(ImageEntry),
    mutex: std.Thread.Mutex = .{},
    max_bytes: usize = 64 * 1024 * 1024,
    used_bytes: usize = 0,
    next_id: u32 = 1,

    pub fn init(allocator: std.mem.Allocator) ImageCache {
        return .{
            .allocator = allocator,
            .entries = std.StringHashMap(ImageEntry).init(allocator),
        };
    }
};

var cache_state: ?ImageCache = null;
var enabled: bool = true;

pub fn init(allocator: std.mem.Allocator) void {
    if (cache_state != null) return;
    cache_state = ImageCache.init(allocator);
}

pub fn setEnabled(value: bool) void {
    enabled = value;
}

pub fn deinit() void {
    if (cache_state == null) return;
    var cache = &cache_state.?;

    cache.mutex.lock();
    var it = cache.entries.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.pixels) |pixels| {
            cache.allocator.free(pixels);
        }
        if (entry.value_ptr.error_message) |err| {
            cache.allocator.free(err);
        }
        cache.allocator.free(entry.key_ptr.*);
    }
    cache.entries.clearRetainingCapacity();
    cache.mutex.unlock();

    cache.entries.deinit();
    cache_state = null;
}

pub fn beginFrame() void {
    // No-op: GPU upload is handled by the WebGPU renderer on demand.
}

pub fn request(url: []const u8) void {
    if (cache_state == null or !enabled) return;
    if (url.len == 0) return;
    var cache = &cache_state.?;

    cache.mutex.lock();
    if (cache.entries.contains(url)) {
        if (cache.entries.getPtr(url)) |entry| {
            entry.last_used_ms = std.time.milliTimestamp();
        }
        cache.mutex.unlock();
        return;
    }

    const key = cache.allocator.dupe(u8, url) catch {
        cache.mutex.unlock();
        return;
    };
    const texture_id: u32 = cache.next_id;
    cache.next_id += 1;
    cache.entries.put(key, ImageEntry{
        .state = .loading,
        .texture_id = texture_id,
        .width = 0,
        .height = 0,
        .bytes = 0,
        .last_used_ms = std.time.milliTimestamp(),
        .pixels = null,
        .error_message = null,
    }) catch {
        cache.allocator.free(key);
        cache.mutex.unlock();
        return;
    };
    cache.mutex.unlock();

    if (std.mem.startsWith(u8, url, "data:")) {
        decodeDataUri(cache, key);
        return;
    }

    if (builtin.cpu.arch == .wasm32) {
        // WASM builds have no general filesystem access; treat URLs as relative-to-origin fetches.
        startWasmFetch(cache, key);
    } else {
        startNativeFetch(cache, key);
    }
}

pub fn get(url: []const u8) ?ImageEntryView {
    if (cache_state == null or !enabled) return null;
    var cache = &cache_state.?;
    cache.mutex.lock();
    defer cache.mutex.unlock();
    if (cache.entries.getPtr(url)) |entry| {
        entry.last_used_ms = std.time.milliTimestamp();
        return .{
            .state = entry.state,
            .texture_id = entry.texture_id,
            .width = entry.width,
            .height = entry.height,
            .pixels = entry.pixels,
            .error_message = entry.error_message,
        };
    }
    return null;
}

pub fn getById(id: u32) ?ImageEntryView {
    if (cache_state == null or !enabled) return null;
    var cache = &cache_state.?;
    cache.mutex.lock();
    defer cache.mutex.unlock();
    var it = cache.entries.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.texture_id != id) continue;
        entry.value_ptr.last_used_ms = std.time.milliTimestamp();
        return .{
            .state = entry.value_ptr.state,
            .texture_id = entry.value_ptr.texture_id,
            .width = entry.value_ptr.width,
            .height = entry.value_ptr.height,
            .pixels = entry.value_ptr.pixels,
            .error_message = entry.value_ptr.error_message,
        };
    }
    return null;
}

pub fn releasePixels(id: u32) void {
    if (cache_state == null) return;
    var cache = &cache_state.?;
    cache.mutex.lock();
    defer cache.mutex.unlock();
    var it = cache.entries.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.texture_id != id) continue;
        if (entry.value_ptr.pixels) |pixels| {
            cache.allocator.free(pixels);
            entry.value_ptr.pixels = null;
            if (entry.value_ptr.bytes > 0 and cache.used_bytes >= entry.value_ptr.bytes) {
                cache.used_bytes -= entry.value_ptr.bytes;
                entry.value_ptr.bytes = 0;
            }
        }
        break;
    }
}

fn decodeDataUri(cache: *ImageCache, key: []u8) void {
    const bytes = data_uri.decodeDataUri(cache.allocator, key) catch |err| {
        setFailed(cache, key, @errorName(err));
        return;
    };
    defer cache.allocator.free(bytes);
    decodeImage(cache, key, bytes) catch |err| {
        setFailed(cache, key, @errorName(err));
    };
}

fn startNativeFetch(cache: *ImageCache, key: []u8) void {
    const ctx = cache.allocator.create(FetchContext) catch {
        setFailed(cache, key, "fetch alloc failed");
        return;
    };
    ctx.* = .{ .cache = cache, .url = key };
    _ = std.Thread.spawn(.{}, fetchThread, .{ctx}) catch {
        cache.allocator.destroy(ctx);
        setFailed(cache, key, "fetch thread spawn failed");
    };
}

fn fetchThread(ctx: *FetchContext) void {
    const cache = ctx.cache;
    defer cache.allocator.destroy(ctx);

    profiler.setThreadName("image.fetch");

    const zone = profiler.zone(@src(), "image.fetch");
    defer zone.end();

    var bytes: []u8 = undefined;
    {
        // If it looks like a URL, fetch over HTTP. Otherwise treat it as a filesystem path.
        const is_url = std.mem.indexOf(u8, ctx.url, "://") != null;
        if (is_url) {
            const z = profiler.zone(@src(), "image.fetch.http");
            defer z.end();
            bytes = image_fetch.fetchHttpBytes(cache.allocator, ctx.url) catch |err| {
                setFailed(cache, ctx.url, @errorName(err));
                return;
            };
        } else {
            const z = profiler.zone(@src(), "image.fetch.file");
            defer z.end();
            bytes = readFileBytes(cache.allocator, ctx.url) catch |err| {
                setFailed(cache, ctx.url, @errorName(err));
                return;
            };
        }
    }
    defer cache.allocator.free(bytes);

    {
        const z = profiler.zone(@src(), "image.decode");
        defer z.end();
        decodeImage(cache, ctx.url, bytes) catch |err| {
            setFailed(cache, ctx.url, @errorName(err));
        };
    }
}

fn readFileBytes(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const max_bytes: usize = 32 * 1024 * 1024;
    var f = if (std.fs.path.isAbsolute(path))
        try std.fs.openFileAbsolute(path, .{})
    else
        try std.fs.cwd().openFile(path, .{});
    defer f.close();
    return try f.readToEndAlloc(allocator, max_bytes);
}

fn startWasmFetch(cache: *ImageCache, key: []u8) void {
    const ctx = cache.allocator.create(FetchContext) catch {
        setFailed(cache, key, "fetch alloc failed");
        return;
    };
    ctx.* = .{ .cache = cache, .url = key };
    wasm_fetch.fetchBytes(cache.allocator, key, @intFromPtr(ctx), wasmFetchSuccess, wasmFetchError) catch {
        cache.allocator.destroy(ctx);
        setFailed(cache, key, "fetch start failed");
    };
}

fn wasmFetchSuccess(user_ctx: usize, bytes: []const u8) void {
    if (cache_state == null) return;
    const ctx_ptr: *FetchContext = @ptrFromInt(user_ctx);
    decodeImage(ctx_ptr.cache, ctx_ptr.url, bytes) catch |err| {
        setFailed(ctx_ptr.cache, ctx_ptr.url, @errorName(err));
    };
    ctx_ptr.cache.allocator.destroy(ctx_ptr);
}

fn wasmFetchError(user_ctx: usize, msg: []const u8) void {
    if (cache_state == null) return;
    const ctx_ptr: *FetchContext = @ptrFromInt(user_ctx);
    setFailed(ctx_ptr.cache, ctx_ptr.url, msg);
    ctx_ptr.cache.allocator.destroy(ctx_ptr);
}

fn decodeImage(cache: *ImageCache, key: []u8, bytes: []const u8) !void {
    if (bytes.len > 16 * 1024 * 1024) return error.ImageTooLarge;

    var width: c_int = 0;
    var height: c_int = 0;
    const pixels_ptr = icon.zsc_load_image_rgba_from_memory(bytes.ptr, @intCast(bytes.len), &width, &height);
    if (pixels_ptr == null or width <= 0 or height <= 0) {
        return error.ImageDecodeFailed;
    }
    defer icon.zsc_free_image(pixels_ptr);

    const w: u32 = @intCast(width);
    const h: u32 = @intCast(height);
    if (w > 4096 or h > 4096) return error.ImageTooLarge;

    const pixel_len = @as(usize, w) * @as(usize, h) * 4;
    const pixels = try cache.allocator.alloc(u8, pixel_len);
    @memcpy(pixels, @as([*]u8, @ptrCast(pixels_ptr))[0..pixel_len]);

    cache.mutex.lock();
    defer cache.mutex.unlock();
    if (cache.entries.getPtr(key)) |entry| {
        if (entry.pixels) |old| {
            cache.allocator.free(old);
        }
        if (entry.bytes > 0 and cache.used_bytes >= entry.bytes) {
            cache.used_bytes -= entry.bytes;
        }
        entry.state = .ready;
        entry.width = w;
        entry.height = h;
        entry.bytes = pixel_len;
        entry.pixels = pixels;
        entry.last_used_ms = std.time.milliTimestamp();
        cache.used_bytes += pixel_len;
        evictIfNeeded(cache);
    } else {
        cache.allocator.free(pixels);
    }
}

fn setFailed(cache: *ImageCache, key: []const u8, msg: []const u8) void {
    cache.mutex.lock();
    defer cache.mutex.unlock();
    if (cache.entries.getPtr(key)) |entry| {
        entry.state = .failed;
        if (entry.error_message) |err| cache.allocator.free(err);
        entry.error_message = dupeError(cache.allocator, msg);
    }
}

fn dupeError(allocator: std.mem.Allocator, msg: []const u8) ?[]u8 {
    return allocator.dupe(u8, msg) catch null;
}

fn evictIfNeeded(self: *ImageCache) void {
    while (self.used_bytes > self.max_bytes) {
        var oldest_key: ?[]const u8 = null;
        var oldest_ts: i64 = 0;
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.state != .ready) continue;
            if (oldest_key == null or entry.value_ptr.last_used_ms < oldest_ts) {
                oldest_key = entry.key_ptr.*;
                oldest_ts = entry.value_ptr.last_used_ms;
            }
        }
        if (oldest_key == null) break;
        removeEntry(self, oldest_key.?);
    }
}

fn removeEntry(self: *ImageCache, key: []const u8) void {
    if (self.entries.fetchRemove(key)) |kv| {
        if (kv.value.pixels) |pixels| {
            self.allocator.free(pixels);
        }
        if (kv.value.error_message) |err| {
            self.allocator.free(err);
        }
        if (kv.value.bytes > 0 and self.used_bytes >= kv.value.bytes) {
            self.used_bytes -= kv.value.bytes;
        }
        self.allocator.free(kv.key);
    }
}

// zsc_wasm_fetch callbacks live in `src/platform/wasm_fetch.zig` now.
