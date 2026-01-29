#include <emscripten/emscripten.h>
#include "imgui.h"

EM_JS(void, molt_clipboard_init_js, (), {
  if (Module.moltClipboard) return;
  Module.moltClipboard = { text: "" };
  document.addEventListener("paste", function (e) {
    if (!e || !e.clipboardData) return;
    const text = e.clipboardData.getData("text/plain");
    if (typeof text === "string") Module.moltClipboard.text = text;
  });
});

EM_JS(void, molt_clipboard_set_js, (const char* text), {
  const value = text ? UTF8ToString(text) : "";
  if (!Module.moltClipboard) Module.moltClipboard = { text: "" };
  Module.moltClipboard.text = value;
  if (navigator.clipboard && navigator.clipboard.writeText) {
    navigator.clipboard.writeText(value).catch(() => {});
  }
});

EM_JS(char*, molt_clipboard_get_js, (), {
  const value = (Module.moltClipboard && Module.moltClipboard.text) ? Module.moltClipboard.text : "";
  const len = lengthBytesUTF8(value) + 1;
  const ptr = _malloc(len);
  stringToUTF8(value, ptr, len);
  return ptr;
});

static const char* molt_clipboard_get(ImGuiContext* ctx) {
  (void)ctx;
  return molt_clipboard_get_js();
}

static void molt_clipboard_set(ImGuiContext* ctx, const char* text) {
  (void)ctx;
  molt_clipboard_set_js(text);
}

extern "C" void molt_clipboard_init(void) {
  molt_clipboard_init_js();
  ImGuiPlatformIO& platform_io = ImGui::GetPlatformIO();
  platform_io.Platform_SetClipboardTextFn = molt_clipboard_set;
  platform_io.Platform_GetClipboardTextFn = molt_clipboard_get;
  platform_io.Platform_ClipboardUserData = nullptr;
}
