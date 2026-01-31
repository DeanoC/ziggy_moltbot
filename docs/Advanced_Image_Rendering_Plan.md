# Advanced Image Rendering Plan (Next Commit)

## Goals
- Render high-quality inline images across native, Windows, WASM, and Android with correct color, scaling, and performance.
- Support more formats (WebP, GIF/APNG animations, SVG where feasible) while keeping memory bounded.
- Make image loading resilient (progress, retries, size limits, cache persistence).

## Non-Goals (for this phase)
- Video playback.
- Full HTML/CSS rendering.
- Server-side image transforms.

## Baseline (current)
- Data URI + URL fetch support.
- STB decode to RGBA, OpenGL texture upload, in-memory LRU cache.
- WASM fetch bridge and per-frame pending uploads.

## Plan Overview
This plan assumes incremental commits with clear platform parity. Each step lists key changes and files.

### 1) Core Image Pipeline Extensions
- Add a unified image descriptor with metadata (format, pixel format, color space, animation info).
- Expand decode path to support additional formats and animated frames.
- Implement size limits and robust error reporting.

Files:
- `src/ui/image_cache.zig` (image descriptor, animation state, decode limits)
- `src/ui/image_fetch.zig` (content-type sniffing + size guard)
- `src/ui/data_uri.zig` (MIME parsing improvements)
- `src/icon_loader.c` / `src/icon_loader.h` (format support toggles, decode API extensions)

### 2) Format Support
- WebP (static/animated): add libwebp for native/Windows/Android; WASM uses browser decode.
- GIF/APNG: decode to RGBA frames with frame timing.
- SVG (optional): rasterize via nanosvg for native/Windows/Android; WASM uses browser rasterize.

Files:
- `build.zig` (new deps; conditional per target)
- `deps/` (libwebp, giflib or stb-based apng; nanosvg)
- `src/ui/image_cache.zig` (frame scheduler + per-frame texture update)

### 3) Texture Management
- Add texture atlas option for small images to reduce state changes.
- Add optional mipmap generation for high DPI scaling.
- Track GPU memory usage; evict textures when over budget.

Files:
- `src/ui/texture_gl.zig` (atlas support, mipmap generation)
- `src/ui/image_cache.zig` (GPU memory accounting + eviction)
- `src/opengl_loader.c` (mipmap helpers)

### 4) Color & Alpha Correctness
- Standardize on premultiplied alpha on upload.
- Use sRGB textures where available.
- Provide a per-image flag for linear vs. sRGB sampling.

Files:
- `src/ui/texture_gl.zig` (sRGB upload path)
- `src/ui/image_cache.zig` (alpha/space conversions)

### 5) WASM-Specific Path
- Use `fetch` + `createImageBitmap` (browser decode) for large images/animations.
- Transfer pixel buffers into WASM memory only when needed.
- Keep a JS-side cache of decoded frames to reduce memory copying.

Files:
- `src/wasm_fetch.cpp` (decode path + callbacks)
- `src/ui/image_fetch.zig` (wasm decode selection)
- `web/shell.html` (JS helpers, if needed)

### 6) Android-Specific Path
- Use `AImageDecoder` for modern decoding (API 28+), fallback to stb.
- Prefer hardware-accelerated decode when possible.

Files:
- `src/ui/image_cache.zig` (android decode hook)
- `build.zig` (ndk libs / flags)

### 7) Disk Cache (Optional but recommended)
- Add persistent disk cache for downloaded images (size capped).
- Cache key = URL + transform parameters.

Files:
- `src/ui/image_cache.zig` (cache interface)
- `src/utils/fs_cache.zig` (new)

### 8) UI/UX Enhancements
- Progressive loading UI (skeleton, fade-in).
- Image hover tooltip with metadata (dimensions, size, format).
- Context menu: open in browser / copy URL.

Files:
- `src/ui/chat_view.zig` (UI enhancements)

## Acceptance Criteria
- Static images: PNG/JPG/WebP render correctly on all targets.
- Animated images: GIF/APNG/WebP animation renders with correct timing on native + Windows, and WASM.
- Memory budgets enforced (configurable).
- No blocking on UI thread for decode.

## Tests & Validation
- Unit tests for MIME parsing, data URI decoding.
- Decode tests for supported formats with golden pixel checks.
- Runtime tests for LRU eviction and memory budget handling.
- Manual smoke tests on all platforms.

## Rollout Notes
- Gate new formats behind feature flags.
- Keep logging for decode failures and fallback paths.
- Provide a config to disable animation for low-power devices.
