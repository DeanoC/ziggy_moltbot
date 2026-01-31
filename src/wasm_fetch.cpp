#include <emscripten/emscripten.h>
#include <stdint.h>

EM_JS(void, zsc_wasm_fetch_js, (const char* url, uintptr_t ctx), {
    const u = UTF8ToString(url);
    fetch(u)
        .then((res) => {
            if (!res.ok) throw new Error('HTTP ' + res.status);
            return res.arrayBuffer();
        })
        .then((buf) => {
            const len = buf.byteLength;
            const ptr = Module._malloc(len);
            if (!ptr) throw new Error('malloc failed');
            const heap = new Uint8Array(Module.HEAPU8.buffer, ptr, len);
            heap.set(new Uint8Array(buf));
            if (Module._zsc_wasm_fetch_on_success) {
                Module._zsc_wasm_fetch_on_success(ctx, ptr, len);
            }
            Module._free(ptr);
        })
        .catch((err) => {
            const msg = (err && err.message) ? err.message : 'fetch failed';
            const len = lengthBytesUTF8(msg) + 1;
            const ptr = Module._malloc(len);
            if (ptr) {
                stringToUTF8(msg, ptr, len);
                if (Module._zsc_wasm_fetch_on_error) {
                    Module._zsc_wasm_fetch_on_error(ctx, ptr);
                }
                Module._free(ptr);
            } else if (Module._zsc_wasm_fetch_on_error) {
                Module._zsc_wasm_fetch_on_error(ctx, 0);
            }
        });
});

extern "C" void zsc_wasm_fetch(const char* url, uintptr_t ctx) {
    zsc_wasm_fetch_js(url, ctx);
}
