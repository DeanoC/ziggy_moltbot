#include <stddef.h>
#include "imgui.h"

extern "C" {
const char* zsc_imgui_save_ini_settings_to_memory(size_t* out_size) {
    return ImGui::SaveIniSettingsToMemory(out_size);
}

void zsc_imgui_load_ini_settings_from_memory(const char* data, size_t size) {
    ImGui::LoadIniSettingsFromMemory(data, size);
}

void zsc_imgui_set_next_window_dock_id(ImGuiID dock_id, ImGuiCond cond) {
    ImGui::SetNextWindowDockID(dock_id, cond);
}

ImGuiID zsc_imgui_get_window_dock_id() {
    return ImGui::GetWindowDockID();
}

bool zsc_imgui_get_want_save_ini_settings() {
    return ImGui::GetIO().WantSaveIniSettings;
}

void zsc_imgui_clear_want_save_ini_settings() {
    ImGui::GetIO().WantSaveIniSettings = false;
}

static size_t zsc_utf8_len(ImWchar c) {
    if (c < 0x80) return 1;
    if (c < 0x800) return 2;
    if (c < 0x10000) return 3;
    if (c < 0x110000) return 4;
    return 0;
}

static size_t zsc_utf8_encode(char* out, ImWchar c) {
    if (c < 0x80) {
        out[0] = static_cast<char>(c);
        return 1;
    }
    if (c < 0x800) {
        out[0] = static_cast<char>(0xC0 | (c >> 6));
        out[1] = static_cast<char>(0x80 | (c & 0x3F));
        return 2;
    }
    if (c < 0x10000) {
        out[0] = static_cast<char>(0xE0 | (c >> 12));
        out[1] = static_cast<char>(0x80 | ((c >> 6) & 0x3F));
        out[2] = static_cast<char>(0x80 | (c & 0x3F));
        return 3;
    }
    if (c < 0x110000) {
        out[0] = static_cast<char>(0xF0 | (c >> 18));
        out[1] = static_cast<char>(0x80 | ((c >> 12) & 0x3F));
        out[2] = static_cast<char>(0x80 | ((c >> 6) & 0x3F));
        out[3] = static_cast<char>(0x80 | (c & 0x3F));
        return 4;
    }
    return 0;
}

size_t zsc_imgui_peek_input_queue_utf8(char* out_buf, size_t buf_size) {
    const ImVector<ImWchar>& queue = ImGui::GetIO().InputQueueCharacters;
    size_t needed = 0;
    for (int i = 0; i < queue.Size; ++i) {
        needed += zsc_utf8_len(queue[i]);
    }
    if (out_buf == nullptr || buf_size < needed) {
        return needed;
    }
    char* cursor = out_buf;
    for (int i = 0; i < queue.Size; ++i) {
        cursor += zsc_utf8_encode(cursor, queue[i]);
    }
    return needed;
}

float zsc_imgui_get_mouse_wheel() {
    return ImGui::GetIO().MouseWheel;
}

float zsc_imgui_get_mouse_wheel_h() {
    return ImGui::GetIO().MouseWheelH;
}

void zsc_imgui_set_want_text_input(bool value) {
    ImGui::GetIO().WantTextInput = value;
}

void zsc_imgui_set_ime_data(float x, float y, float line_height, bool want_visible) {
    ImGuiPlatformIO& pio = ImGui::GetPlatformIO();
    if (pio.Platform_SetImeDataFn == NULL)
        return;
    ImGuiViewport* viewport = ImGui::GetMainViewport();
    ImGuiPlatformImeData data;
    data.WantVisible = want_visible;
    data.WantTextInput = want_visible;
    data.InputPos = ImVec2(x, y);
    data.InputLineHeight = line_height;
    data.ViewportId = viewport ? viewport->ID : 0;
    pio.Platform_SetImeDataFn(ImGui::GetCurrentContext(), viewport, &data);
}

void zsc_imgui_set_next_window_size_constraints(float min_w, float min_h, float max_w, float max_h) {
    ImGui::SetNextWindowSizeConstraints(ImVec2(min_w, min_h), ImVec2(max_w, max_h));
}
}
