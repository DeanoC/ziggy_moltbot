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
}
