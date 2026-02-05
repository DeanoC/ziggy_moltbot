const builtin = @import("builtin");

const c = if (builtin.abi == .android or builtin.cpu.arch == .wasm32)
    @cImport({
        if (builtin.abi == .android) {
            @cInclude("SDL_opengles2.h");
        } else {
            @cInclude("GLES3/gl3.h");
        }
    })
else
    struct {};

pub const TextureError = error{TextureCreateFailed};

pub fn createTextureRGBA(pixels: []const u8, width: u32, height: u32) TextureError!u32 {
    if (builtin.abi == .android or builtin.cpu.arch == .wasm32) {
        var tex: c_uint = 0;
        c.glGenTextures(1, &tex);
        if (tex == 0) return error.TextureCreateFailed;
        c.glBindTexture(c.GL_TEXTURE_2D, tex);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
        c.glPixelStorei(c.GL_UNPACK_ALIGNMENT, 1);
        c.glTexImage2D(
            c.GL_TEXTURE_2D,
            0,
            c.GL_RGBA,
            @intCast(width),
            @intCast(height),
            0,
            c.GL_RGBA,
            c.GL_UNSIGNED_BYTE,
            pixels.ptr,
        );
        return @intCast(tex);
    }

    return error.TextureCreateFailed;
}

pub fn destroyTexture(handle: u32) void {
    if (handle == 0) return;
    if (builtin.abi == .android or builtin.cpu.arch == .wasm32) {
        var tex: c_uint = @intCast(handle);
        c.glDeleteTextures(1, &tex);
        return;
    }
    return;
}
