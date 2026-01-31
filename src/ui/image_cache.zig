const std = @import("std");
const builtin = @import("builtin");
const data_uri = @import("data_uri.zig");
const image_fetch = if (builtin.cpu.arch == .wasm32)
    struct {
        pub fn fetchHttpBytes(_: std.mem.Allocator, _: []const u8) ![]u8 {
            return error.Unsupported;
        }
    }
else
    @import("image_fetch.zig");
const texture_gl = @import("texture_gl.zig");

const icon = @cImport({
    @cInclude("icon_loader.h");
});

extern fn zsc_wasm_fetch(url: [*:0]const u8, ctx: usize) void;

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
    error_message: ?[]const u8,
};

const ImageEntry = struct {
    state: ImageState,
    texture_id: u32,
    width: u32,
    height: u32,
    bytes: usize,
    last_used_ms: i64,
    error_message: ?[]u8,
};

const PendingUpload = struct {
    url: []u8,
    pixels: []u8,
    width: u32,
    height: u32,
    bytes: usize,
};

const FetchContext = struct {
    cache: *ImageCache,
    url: []u8,
};

pub const ImageCache = struct {
    allocator: std.mem.Allocator,
    entries: std.StringHashMap(ImageEntry),
    pending: std.ArrayList(PendingUpload),
    mutex: std.Thread.Mutex = .{},
    max_bytes: usize = 64 * 1024 * 1024,
    used_bytes: usize = 0,

    pub fn init(allocator: std.mem.Allocator) ImageCache {
        return .{
            .allocator = allocator,
            .entries = std.StringHashMap(ImageEntry).init(allocator),
            .pending = .{},
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
        if (entry.value_ptr.texture_id != 0) {
            texture_gl.destroyTexture(entry.value_ptr.texture_id);
        }
        if (entry.value_ptr.error_message) |err| {
            cache.allocator.free(err);
        }
        cache.allocator.free(entry.key_ptr.*);
    }
    cache.entries.clearRetainingCapacity();
    for (cache.pending.items) |pending| {
        cache.allocator.free(pending.pixels);
    }
    cache.pending.clearRetainingCapacity();
    cache.mutex.unlock();

    cache.entries.deinit();
    cache.pending.deinit(cache.allocator);
    cache_state = null;
}

pub fn beginFrame() void {
    if (cache_state == null or !enabled) return;
    var cache = &cache_state.?;

    cache.mutex.lock();
    const pending = cache.pending.toOwnedSlice(cache.allocator) catch {
        cache.mutex.unlock();
        return;
    };
    cache.pending.clearRetainingCapacity();
    cache.mutex.unlock();

    for (pending) |item| {
        const tex = texture_gl.createTextureRGBA(item.pixels, item.width, item.height) catch 0;
        cache.mutex.lock();
        defer cache.mutex.unlock();
        if (cache.entries.getPtr(item.url)) |entry| {
            if (tex != 0) {
                entry.state = .ready;
                entry.texture_id = tex;
                entry.width = item.width;
                entry.height = item.height;
                entry.bytes = item.bytes;
                entry.last_used_ms = std.time.milliTimestamp();
                cache.used_bytes += item.bytes;
                evictIfNeeded(cache);
            } else {
                entry.state = .failed;
                entry.error_message = dupeError(cache.allocator, "texture upload failed");
            }
        }
        cache.allocator.free(item.pixels);
    }
    cache.allocator.free(pending);
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
    cache.entries.put(key, ImageEntry{
        .state = .loading,
        .texture_id = 0,
        .width = 0,
        .height = 0,
        .bytes = 0,
        .last_used_ms = std.time.milliTimestamp(),
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
            .error_message = entry.error_message,
        };
    }
    return null;
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

    const bytes = image_fetch.fetchHttpBytes(cache.allocator, ctx.url) catch |err| {
        setFailed(cache, ctx.url, @errorName(err));
        return;
    };
    defer cache.allocator.free(bytes);

    decodeImage(cache, ctx.url, bytes) catch |err| {
        setFailed(cache, ctx.url, @errorName(err));
    };
}

fn startWasmFetch(cache: *ImageCache, key: []u8) void {
    const ctx = cache.allocator.create(FetchContext) catch {
        setFailed(cache, key, "fetch alloc failed");
        return;
    };
    ctx.* = .{ .cache = cache, .url = key };
    const url_z = cache.allocator.dupeZ(u8, key) catch {
        cache.allocator.destroy(ctx);
        setFailed(cache, key, "url alloc failed");
        return;
    };
    defer cache.allocator.free(url_z);
    zsc_wasm_fetch(url_z.ptr, @intFromPtr(ctx));
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
    cache.pending.append(cache.allocator, .{
        .url = key,
        .pixels = pixels,
        .width = w,
        .height = h,
        .bytes = pixel_len,
    }) catch {
        cache.allocator.free(pixels);
        if (cache.entries.getPtr(key)) |entry| {
            entry.state = .failed;
            entry.error_message = dupeError(cache.allocator, "pending queue full");
        }
    };
    cache.mutex.unlock();
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
        if (kv.value.texture_id != 0) {
            texture_gl.destroyTexture(kv.value.texture_id);
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

pub export fn zsc_wasm_fetch_on_success(ctx: usize, ptr: [*]u8, len: usize) void {
    if (cache_state == null) return;
    const ctx_ptr: *FetchContext = @ptrFromInt(ctx);
    const bytes = ptr[0..len];
    decodeImage(ctx_ptr.cache, ctx_ptr.url, bytes) catch |err| {
        setFailed(ctx_ptr.cache, ctx_ptr.url, @errorName(err));
    };
    ctx_ptr.cache.allocator.destroy(ctx_ptr);
}

pub export fn zsc_wasm_fetch_on_error(ctx: usize, msg_ptr: [*:0]const u8) void {
    if (cache_state == null) return;
    const ctx_ptr: *FetchContext = @ptrFromInt(ctx);
    const msg = if (@intFromPtr(msg_ptr) == 0) "fetch failed" else std.mem.sliceTo(msg_ptr, 0);
    setFailed(ctx_ptr.cache, ctx_ptr.url, msg);
    ctx_ptr.cache.allocator.destroy(ctx_ptr);
}
