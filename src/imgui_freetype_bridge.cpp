#include "imgui.h"
#include "misc/freetype/imgui_freetype.h"

extern "C" void zsc_imgui_use_freetype() {
    ImGuiIO& io = ImGui::GetIO();
    io.Fonts->SetFontLoader(ImGuiFreeType::GetFontLoader());
}
