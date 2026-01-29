#include <emscripten/emscripten.h>

EM_JS(void, molt_ws_open_js, (const char* url), {
  const target = UTF8ToString(url);
  if (Module.moltWs) {
    try { Module.moltWs.close(); } catch (e) {}
  }
  const ws = new WebSocket(target);
  ws.binaryType = "arraybuffer";
  ws.onopen = function () {
    if (Module._molt_ws_on_open) Module._molt_ws_on_open();
  };
  ws.onclose = function (ev) {
    if (Module._molt_ws_on_close) Module._molt_ws_on_close(ev.code || 0);
  };
  ws.onerror = function () {
    if (Module._molt_ws_on_error) Module._molt_ws_on_error();
  };
  ws.onmessage = function (ev) {
    let text = "";
    if (typeof ev.data === "string") {
      text = ev.data;
    } else if (ev.data instanceof ArrayBuffer) {
      text = new TextDecoder("utf-8").decode(ev.data);
    } else if (ev.data && ev.data.buffer) {
      text = new TextDecoder("utf-8").decode(ev.data.buffer);
    }
    const len = lengthBytesUTF8(text) + 1;
    const ptr = _malloc(len);
    stringToUTF8(text, ptr, len);
    if (Module._molt_ws_on_message) Module._molt_ws_on_message(ptr, len - 1);
    _free(ptr);
  };
  Module.moltWs = ws;
});

EM_JS(void, molt_ws_send_js, (const char* text), {
  if (!Module.moltWs || Module.moltWs.readyState !== 1) return;
  Module.moltWs.send(UTF8ToString(text));
});

EM_JS(void, molt_ws_close_js, (), {
  if (!Module.moltWs) return;
  try { Module.moltWs.close(); } catch (e) {}
});

EM_JS(int, molt_ws_ready_state_js, (), {
  if (!Module.moltWs) return 0;
  return Module.moltWs.readyState;
});

extern "C" void molt_ws_open(const char* url) {
  molt_ws_open_js(url);
}

extern "C" void molt_ws_send(const char* text) {
  molt_ws_send_js(text);
}

extern "C" void molt_ws_close(void) {
  molt_ws_close_js();
}

extern "C" int molt_ws_ready_state(void) {
  return molt_ws_ready_state_js();
}
