const std = @import("std");
const node_context = @import("node_context.zig");
const NodeContext = node_context.NodeContext;
const logger = @import("../utils/logger.zig");

/// Process state
pub const ProcessState = enum {
    running,
    completed,
    failed,
    killed,
};

/// Background process entry
pub const BackgroundProcess = struct {
    id: []const u8,
    command: []const u8,
    pid: ?std.process.Child.Id = null,
    state: ProcessState,
    exit_code: ?i32 = null,
    start_time_ms: i64,
    end_time_ms: ?i64 = null,
    stdout: std.ArrayList(u8),
    stderr: std.ArrayList(u8),
    child: ?std.process.Child = null,
    
    pub fn deinit(self: *BackgroundProcess, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.command);
        self.stdout.deinit(allocator);
        self.stderr.deinit(allocator);
        if (self.child) |*child| {
            _ = child.kill() catch {};
        }
    }
};

/// Process manager for background execution
pub const ProcessManager = struct {
    allocator: std.mem.Allocator,
    processes: std.StringHashMap(*BackgroundProcess),
    next_id: u64 = 1,
    mutex: std.Thread.Mutex,
    
    pub fn init(allocator: std.mem.Allocator) ProcessManager {
        return .{
            .allocator = allocator,
            .processes = std.StringHashMap(*BackgroundProcess).init(allocator),
            .next_id = 1,
            .mutex = .{},
        };
    }
    
    pub fn deinit(self: *ProcessManager) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        var iter = self.processes.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.deinit(self.allocator);
            self.allocator.destroy(entry.value_ptr.*);
            self.allocator.free(entry.key_ptr.*);
        }
        self.processes.deinit();
    }
    
    /// Spawn a background process
    pub fn spawn(
        self: *ProcessManager,
        command: []const []const u8,
        cwd: ?[]const u8,
    ) ![]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // Generate process ID
        const id = try std.fmt.allocPrint(self.allocator, "proc_{d}", .{self.next_id});
        self.next_id += 1;
        const id_key = try self.allocator.dupe(u8, id);
        
        // Build command string for display
        var cmd_buf = std.ArrayList(u8).empty;
        defer cmd_buf.deinit(self.allocator);
        for (command, 0..) |part, i| {
            if (i > 0) try cmd_buf.append(self.allocator, ' ');
            try cmd_buf.appendSlice(self.allocator, part);
        }
        const cmd_str = try self.allocator.dupe(u8, cmd_buf.items);
        
        // Initialize process entry
        const proc_ptr = try self.allocator.create(BackgroundProcess);
        proc_ptr.* = BackgroundProcess{
            .id = id,
            .command = cmd_str,
            .state = .running,
            .start_time_ms = std.time.milliTimestamp(),
            .stdout = std.ArrayList(u8).empty,
            .stderr = std.ArrayList(u8).empty,
        };
        
        // Spawn child process
        var child = std.process.Child.init(command, self.allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        if (cwd) |dir| {
            child.cwd = dir;
        }
        
        // TODO: Set environment if provided (env_map type changed in Zig 0.15)
        
        try child.spawn();
        proc_ptr.pid = child.id;
        proc_ptr.child = child;
        
        // Start output collection threads
        const stdout_reader = proc_ptr.child.?.stdout.?;
        const stderr_reader = proc_ptr.child.?.stderr.?;

        const stdout_thread = try std.Thread.spawn(.{}, struct {
            fn readOutput(reader: anytype, buf: *std.ArrayList(u8), alloc: std.mem.Allocator, proc_id: []const u8) void {
                var tmp: [4096]u8 = undefined;
                while (true) {
                    const n = reader.read(&tmp) catch break;
                    if (n == 0) break;
                    buf.appendSlice(alloc, tmp[0..n]) catch {
                        logger.err("Failed to append stdout for process {s}", .{proc_id});
                        break;
                    };
                }
            }
        }.readOutput, .{ stdout_reader, &proc_ptr.stdout, self.allocator, id });
        
        const stderr_thread = try std.Thread.spawn(.{}, struct {
            fn readOutput(reader: anytype, buf: *std.ArrayList(u8), alloc: std.mem.Allocator, proc_id: []const u8) void {
                var tmp: [4096]u8 = undefined;
                while (true) {
                    const n = reader.read(&tmp) catch break;
                    if (n == 0) break;
                    buf.appendSlice(alloc, tmp[0..n]) catch {
                        logger.err("Failed to append stderr for process {s}", .{proc_id});
                        break;
                    };
                }
            }
        }.readOutput, .{ stderr_reader, &proc_ptr.stderr, self.allocator, id });
        
        // Store process and detach threads
        try self.processes.put(id_key, proc_ptr);
        
        // Start completion monitor thread
        _ = try std.Thread.spawn(.{}, struct {
            fn monitor(manager: *ProcessManager, proc_id: []const u8, proc: *BackgroundProcess, stdout_t: std.Thread, stderr_t: std.Thread) void {
                defer {
                    stdout_t.join();
                    stderr_t.join();
                }
                
                const child_proc = if (proc.child) |*child_value| child_value else {
                    manager.updateProcessState(proc_id, .failed, null);
                    return;
                };
                const term = child_proc.wait() catch |err| {
                    logger.err("Process {s} wait failed: {s}", .{ proc_id, @errorName(err) });
                    manager.updateProcessState(proc_id, .failed, null);
                    return;
                };
                
                const exit_code: i32 = switch (term) {
                    .Exited => |code| @intCast(code),
                    .Signal => |sig| @intCast(sig),
                    .Stopped => |sig| @intCast(sig),
                    .Unknown => |code| @intCast(code),
                };
                
                const state: ProcessState = if (term == .Signal and exit_code == 9) .killed else .completed;
                manager.updateProcessState(proc_id, state, exit_code);
            }
        }.monitor, .{ self, id, proc_ptr, stdout_thread, stderr_thread });
        
        return id;
    }
    
    /// Update process state (called from monitor thread)
    fn updateProcessState(self: *ProcessManager, id: []const u8, state: ProcessState, exit_code: ?i32) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (self.processes.getPtr(id)) |proc_ptr| {
            proc_ptr.*.state = state;
            proc_ptr.*.exit_code = exit_code;
            proc_ptr.*.end_time_ms = std.time.milliTimestamp();
            proc_ptr.*.child = null; // Child is now complete
        }
    }
    
    /// Get process info
    pub fn getProcess(self: *ProcessManager, id: []const u8) ?BackgroundProcess {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (self.processes.get(id)) |proc_ptr| {
            return proc_ptr.*;
        }
        return null;
    }
    
    /// Get process status as JSON
    pub fn getProcessStatus(self: *ProcessManager, allocator: std.mem.Allocator, id: []const u8) !?std.json.Value {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        const proc_ptr = self.processes.get(id) orelse return null;
        const proc = proc_ptr.*;
        
        var result = std.json.ObjectMap.init(allocator);
        try result.put("id", std.json.Value{ .string = try allocator.dupe(u8, proc.id) });
        try result.put("command", std.json.Value{ .string = try allocator.dupe(u8, proc.command) });
        try result.put("state", std.json.Value{ .string = try allocator.dupe(u8, @tagName(proc.state)) });
        try result.put("pid", if (proc.pid) |p| std.json.Value{ .integer = p } else std.json.Value{ .null = {} });
        try result.put("exitCode", if (proc.exit_code) |e| std.json.Value{ .integer = e } else std.json.Value{ .null = {} });
        try result.put("startTime", std.json.Value{ .integer = proc.start_time_ms });
        try result.put("endTime", if (proc.end_time_ms) |e| std.json.Value{ .integer = e } else std.json.Value{ .null = {} });
        
        // Include output (truncated if too large)
        const max_output = 10000;
        const stdout_slice = if (proc.stdout.items.len > max_output) 
            proc.stdout.items[proc.stdout.items.len - max_output..] 
        else 
            proc.stdout.items;
        const stderr_slice = if (proc.stderr.items.len > max_output)
            proc.stderr.items[proc.stderr.items.len - max_output..]
        else
            proc.stderr.items;
        
        try result.put("stdout", std.json.Value{ .string = try allocator.dupe(u8, stdout_slice) });
        try result.put("stderr", std.json.Value{ .string = try allocator.dupe(u8, stderr_slice) });
        
        return std.json.Value{ .object = result };
    }
    
    /// List all processes
    pub fn listProcesses(self: *ProcessManager, allocator: std.mem.Allocator) !std.json.Value {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        var list = std.json.Array.init(allocator);
        
        var iter = self.processes.iterator();
        while (iter.next()) |entry| {
            const proc_ptr = entry.value_ptr.*;
            const proc = proc_ptr.*;
            var obj = std.json.ObjectMap.init(allocator);
            try obj.put("id", std.json.Value{ .string = try allocator.dupe(u8, proc.id) });
            try obj.put("command", std.json.Value{ .string = try allocator.dupe(u8, proc.command) });
            try obj.put("state", std.json.Value{ .string = try allocator.dupe(u8, @tagName(proc.state)) });
            try obj.put("pid", if (proc.pid) |p| std.json.Value{ .integer = p } else std.json.Value{ .null = {} });
            try list.append(std.json.Value{ .object = obj });
        }
        
        return std.json.Value{ .array = list };
    }
    
    /// Kill a process
    pub fn killProcess(self: *ProcessManager, id: []const u8) !bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        const proc_ptr = self.processes.getPtr(id) orelse return false;
        if (proc_ptr.*.state != .running or proc_ptr.*.child == null) {
            return false;
        }
        
        if (proc_ptr.*.child) |*child| {
            _ = child.kill() catch {};
        }
        
        proc_ptr.*.state = .killed;
        proc_ptr.*.end_time_ms = std.time.milliTimestamp();
        return true;
    }
    
    /// Cleanup completed processes older than max_age_ms
    pub fn cleanup(self: *ProcessManager, max_age_ms: i64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        const now = std.time.milliTimestamp();
        var to_remove = std.ArrayList([]const u8).empty;
        defer to_remove.deinit(self.allocator);
        
        var iter = self.processes.iterator();
        while (iter.next()) |entry| {
            const proc_ptr = entry.value_ptr.*;
            const proc = proc_ptr.*;
            if (proc.state != .running) {
                if (proc.end_time_ms) |end| {
                    if (now - end > max_age_ms) {
                        to_remove.append(self.allocator, entry.key_ptr.*) catch break;
                    }
                }
            }
        }
        
        for (to_remove.items) |id| {
            if (self.processes.fetchRemove(id)) |kv| {
                kv.value.deinit(self.allocator);
                self.allocator.destroy(kv.value);
                self.allocator.free(kv.key);
            }
        }
    }
};
