const std = @import("std");
const builtin = @import("builtin");
const attachment_fetch = @import("attachment_fetch.zig");

pub const AttachmentState = enum {
    loading,
    ready,
    failed,
};

pub const EntryView = struct {
    state: AttachmentState,
    data: ?[]const u8,
    error_message: ?[]const u8,
};

const Entry = struct {
    state: AttachmentState,
    data: ?[]u8,
    bytes: usize,
    last_used_ms: i64,
    error_message: ?[]u8,
};

const FetchContext = struct {
    cache: *AttachmentCache,
    url: []u8,
    max_bytes: usize,
};

pub const AttachmentCache = struct {
    allocator: std.mem.Allocator,
    entries: std.StringHashMap(Entry),
    mutex: std.Thread.Mutex = .{},
    max_bytes: usize = 8 * 1024 * 1024,
    used_bytes: usize = 0,
};

var cache_state: ?AttachmentCache = null;
var enabled: bool = true;

pub fn init(allocator: std.mem.Allocator) void {
    if (cache_state != null) return;
    cache_state = AttachmentCache{
        .allocator = allocator,
        .entries = std.StringHashMap(Entry).init(allocator),
    };
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
        if (entry.value_ptr.data) |data| {
            cache.allocator.free(data);
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

pub fn request(url: []const u8, max_bytes: usize) void {
    if (cache_state == null or !enabled) return;
    if (url.len == 0) return;
    if (!std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "https://")) return;

    var cache = &cache_state.?;
    cache.mutex.lock();
    if (cache.entries.getPtr(url)) |entry| {
        entry.last_used_ms = std.time.milliTimestamp();
        cache.mutex.unlock();
        return;
    }

    const key = cache.allocator.dupe(u8, url) catch {
        cache.mutex.unlock();
        return;
    };
    cache.entries.put(key, Entry{
        .state = .loading,
        .data = null,
        .bytes = 0,
        .last_used_ms = std.time.milliTimestamp(),
        .error_message = null,
    }) catch {
        cache.allocator.free(key);
        cache.mutex.unlock();
        return;
    };
    cache.mutex.unlock();

    if (builtin.cpu.arch == .wasm32) {
        setFailed(cache, key, "fetch unsupported");
        return;
    }

    const ctx = cache.allocator.create(FetchContext) catch {
        setFailed(cache, key, "fetch alloc failed");
        return;
    };
    ctx.* = .{ .cache = cache, .url = key, .max_bytes = max_bytes };
    _ = std.Thread.spawn(.{}, fetchThread, .{ctx}) catch {
        cache.allocator.destroy(ctx);
        setFailed(cache, key, "fetch thread spawn failed");
    };
}

pub fn get(url: []const u8) ?EntryView {
    if (cache_state == null or !enabled) return null;
    var cache = &cache_state.?;
    cache.mutex.lock();
    defer cache.mutex.unlock();
    if (cache.entries.getPtr(url)) |entry| {
        entry.last_used_ms = std.time.milliTimestamp();
        return .{
            .state = entry.state,
            .data = entry.data,
            .error_message = entry.error_message,
        };
    }
    return null;
}

fn fetchThread(ctx: *FetchContext) void {
    const cache = ctx.cache;
    defer cache.allocator.destroy(ctx);

    const bytes = attachment_fetch.fetchHttpBytesLimited(cache.allocator, ctx.url, ctx.max_bytes) catch |err| {
        const msg = switch (err) {
            error.TooLarge => "attachment too large",
            error.HttpStatus => "http error",
            else => @errorName(err),
        };
        setFailed(cache, ctx.url, msg);
        return;
    };
    if (!std.unicode.utf8ValidateSlice(bytes)) {
        cache.allocator.free(bytes);
        setFailed(cache, ctx.url, "binary attachment");
        return;
    }

    cache.mutex.lock();
    defer cache.mutex.unlock();
    if (cache.entries.getPtr(ctx.url)) |entry| {
        if (entry.data) |data| cache.allocator.free(data);
        if (entry.bytes > 0 and cache.used_bytes >= entry.bytes) {
            cache.used_bytes -= entry.bytes;
        }
        if (entry.error_message) |err| {
            cache.allocator.free(err);
            entry.error_message = null;
        }
        entry.state = .ready;
        entry.data = bytes;
        entry.bytes = bytes.len;
        entry.last_used_ms = std.time.milliTimestamp();
        cache.used_bytes += bytes.len;
        evictIfNeeded(cache);
    } else {
        cache.allocator.free(bytes);
    }
}

fn setFailed(cache: *AttachmentCache, key: []const u8, msg: []const u8) void {
    cache.mutex.lock();
    defer cache.mutex.unlock();
    if (cache.entries.getPtr(key)) |entry| {
        entry.state = .failed;
        if (entry.data) |data| {
            cache.allocator.free(data);
            entry.data = null;
            if (entry.bytes > 0 and cache.used_bytes >= entry.bytes) {
                cache.used_bytes -= entry.bytes;
            }
            entry.bytes = 0;
        }
        if (entry.error_message) |err| cache.allocator.free(err);
        entry.error_message = dupeError(cache.allocator, msg);
    }
}

fn dupeError(allocator: std.mem.Allocator, msg: []const u8) ?[]u8 {
    return allocator.dupe(u8, msg) catch null;
}

fn evictIfNeeded(cache: *AttachmentCache) void {
    while (cache.used_bytes > cache.max_bytes) {
        var oldest_key: ?[]const u8 = null;
        var oldest_ts: i64 = 0;
        var it = cache.entries.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.state != .ready) continue;
            if (oldest_key == null or entry.value_ptr.last_used_ms < oldest_ts) {
                oldest_key = entry.key_ptr.*;
                oldest_ts = entry.value_ptr.last_used_ms;
            }
        }
        if (oldest_key == null) break;
        removeEntry(cache, oldest_key.?);
    }
}

fn removeEntry(cache: *AttachmentCache, key: []const u8) void {
    if (cache.entries.fetchRemove(key)) |kv| {
        if (kv.value.data) |data| {
            cache.allocator.free(data);
        }
        if (kv.value.error_message) |err| {
            cache.allocator.free(err);
        }
        if (kv.value.bytes > 0 and cache.used_bytes >= kv.value.bytes) {
            cache.used_bytes -= kv.value.bytes;
        }
        cache.allocator.free(kv.key);
    }
}
