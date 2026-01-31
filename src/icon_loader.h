#ifndef ZIGGYSTARCLAW_ICON_LOADER_H
#define ZIGGYSTARCLAW_ICON_LOADER_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

unsigned char* zsc_load_icon_rgba_from_memory(const unsigned char* data, int len, int* width, int* height);
void zsc_free_icon(void* pixels);
unsigned char* zsc_load_image_rgba_from_memory(const unsigned char* data, int len, int* width, int* height);
void zsc_free_image(void* pixels);

#ifdef __cplusplus
}
#endif

#endif
