#include <emscripten/emscripten.h>

EM_JS(char*, molt_storage_get_js, (const char* key), {
  const k = UTF8ToString(key);
  const value = localStorage.getItem(k);
  if (value === null) return 0;
  const len = lengthBytesUTF8(value) + 1;
  const ptr = _malloc(len);
  stringToUTF8(value, ptr, len);
  return ptr;
});

EM_JS(void, molt_storage_set_js, (const char* key, const char* value), {
  const k = UTF8ToString(key);
  const v = UTF8ToString(value);
  localStorage.setItem(k, v);
});

EM_JS(void, molt_storage_remove_js, (const char* key), {
  const k = UTF8ToString(key);
  localStorage.removeItem(k);
});

extern "C" char* molt_storage_get(const char* key) {
  return molt_storage_get_js(key);
}

extern "C" void molt_storage_set(const char* key, const char* value) {
  molt_storage_set_js(key, value);
}

extern "C" void molt_storage_remove(const char* key) {
  molt_storage_remove_js(key);
}
