const std = @import("std");

/// Location backend support for the current host.
pub const BackendSupport = struct {
    get: bool,
};

/// Detect whether location.get is executable on this host.
///
/// The backend is intentionally conservative until platform-specific location
/// providers are implemented.
pub fn detectBackendSupport(_: std.mem.Allocator) BackendSupport {
    return .{ .get = false };
}

pub const DesiredAccuracy = enum {
    coarse,
    balanced,
    precise,
};

pub const GetLocationOptions = struct {
    maxAgeMs: ?u32 = null,
    locationTimeoutMs: ?u32 = null,
    desiredAccuracy: ?DesiredAccuracy = null,
};

pub const LocationFix = struct {
    latitude: f64,
    longitude: f64,
    accuracyM: ?f64 = null,
    timestampMs: ?i64 = null,
};

pub const GetLocationError = error{
    NotSupported,
    InvalidParams,
    PermissionDenied,
    Timeout,
    ExecutionFailed,
};

pub fn getLocation(_: std.mem.Allocator, _: GetLocationOptions) GetLocationError!LocationFix {
    return error.NotSupported;
}
