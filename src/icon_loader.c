#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"
#include "icon_loader.h"

unsigned char* zsc_load_icon_rgba_from_memory(const unsigned char* data, int len, int* width, int* height) {
    return stbi_load_from_memory(data, len, width, height, NULL, 4);
}

void zsc_free_icon(void* pixels) {
    stbi_image_free(pixels);
}

unsigned char* zsc_load_image_rgba_from_memory(const unsigned char* data, int len, int* width, int* height) {
    return stbi_load_from_memory(data, len, width, height, NULL, 4);
}

void zsc_free_image(void* pixels) {
    stbi_image_free(pixels);
}
