#include <stdlib.h>
#include <emscripten/emscripten.h>

// Synchronous clipboard on the web is not generally available.
// We keep an internal string that gets updated by "paste" events,
// and we also attempt to mirror writes to the real clipboard when permitted.

EM_JS(void, zsc_clipboard_init_js, (), {
  if (Module.zscClipboard) return;
  Module.zscClipboard = { text: "" };
  document.addEventListener("paste", function (e) {
    if (!e || !e.clipboardData) return;
    const text = e.clipboardData.getData("text/plain");
    if (typeof text === "string") Module.zscClipboard.text = text;

    // Feed paste text directly into the app. This avoids relying on synchronous
    // clipboard reads and ensures Ctrl+V works even when navigator.clipboard.readText()
    // isn't available (or is blocked).
    if (typeof text === "string" && Module._zsc_wasm_on_paste) {
      const len = lengthBytesUTF8(text);
      const ptr = Module._malloc(len + 1);
      if (ptr) {
        stringToUTF8(text, ptr, len + 1);
        Module._zsc_wasm_on_paste(ptr, len);
        Module._free(ptr);
      }
    }
  });
});

EM_JS(void, zsc_clipboard_set_js, (const char* text), {
  const value = text ? UTF8ToString(text) : "";
  if (!Module.zscClipboard) Module.zscClipboard = { text: "" };
  Module.zscClipboard.text = value;
  if (navigator.clipboard && navigator.clipboard.writeText) {
    navigator.clipboard.writeText(value).catch(() => {});
  }
});

EM_JS(int, zsc_clipboard_len_js, (), {
  const value = (Module.zscClipboard && Module.zscClipboard.text) ? Module.zscClipboard.text : "";
  return lengthBytesUTF8(value);
});

EM_JS(int, zsc_clipboard_copy_js, (char* dst, int dst_len), {
  const value = (Module.zscClipboard && Module.zscClipboard.text) ? Module.zscClipboard.text : "";
  const len = lengthBytesUTF8(value);
  // stringToUTF8 always writes a trailing NUL (if dst_len > 0) and truncates as needed.
  stringToUTF8(value, dst, dst_len);
  return len;
});

extern "C" {
void zsc_clipboard_init(void) { zsc_clipboard_init_js(); }
void zsc_clipboard_set(const char* text) { zsc_clipboard_set_js(text); }
int zsc_clipboard_len(void) { return zsc_clipboard_len_js(); }
int zsc_clipboard_copy(char* dst, int dst_len) { return zsc_clipboard_copy_js(dst, dst_len); }
}
