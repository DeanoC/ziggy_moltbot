#define GLAPI
#include "opengl-decls.h"
#undef GLAPI

#if defined(__unix__) || defined(__APPLE__)
#include <dlfcn.h>
#endif

// GLFW exposes glfwGetProcAddress; declare it as returning void* for loader use.
extern void* glfwGetProcAddress(const char*);

static void* zgui_fallback_sym(const char* name) {
#if defined(__unix__) || defined(__APPLE__)
    void* sym = dlsym(RTLD_DEFAULT, name);
    return sym;
#else
    (void)name;
    return 0;
#endif
}

int zgui_opengl_load(void) {
    int missing = 0;
    #define LOAD(name, type) do { \
        void* ptr = glfwGetProcAddress(#name); \
        if (!ptr) ptr = zgui_fallback_sym(#name); \
        name = (type)ptr; \
        if (!name) missing++; \
    } while (0)
    LOAD(glPolygonMode, PFNGLPOLYGONMODEPROC);
    LOAD(glScissor, PFNGLSCISSORPROC);
    LOAD(glTexParameteri, PFNGLTEXPARAMETERIPROC);
    LOAD(glTexImage2D, PFNGLTEXIMAGE2DPROC);
    LOAD(glClear, PFNGLCLEARPROC);
    LOAD(glClearColor, PFNGLCLEARCOLORPROC);
    LOAD(glDisable, PFNGLDISABLEPROC);
    LOAD(glEnable, PFNGLENABLEPROC);
    LOAD(glFlush, PFNGLFLUSHPROC);
    LOAD(glPixelStorei, PFNGLPIXELSTOREIPROC);
    LOAD(glReadPixels, PFNGLREADPIXELSPROC);
    LOAD(glGetError, PFNGLGETERRORPROC);
    LOAD(glGetIntegerv, PFNGLGETINTEGERVPROC);
    LOAD(glGetString, PFNGLGETSTRINGPROC);
    LOAD(glIsEnabled, PFNGLISENABLEDPROC);
    LOAD(glViewport, PFNGLVIEWPORTPROC);
    LOAD(glDrawElements, PFNGLDRAWELEMENTSPROC);
    LOAD(glTexSubImage2D, PFNGLTEXSUBIMAGE2DPROC);
    LOAD(glBindTexture, PFNGLBINDTEXTUREPROC);
    LOAD(glDeleteTextures, PFNGLDELETETEXTURESPROC);
    LOAD(glGenTextures, PFNGLGENTEXTURESPROC);
    LOAD(glActiveTexture, PFNGLACTIVETEXTUREPROC);
    LOAD(glBlendFuncSeparate, PFNGLBLENDFUNCSEPARATEPROC);
    LOAD(glBlendEquation, PFNGLBLENDEQUATIONPROC);
    LOAD(glBindBuffer, PFNGLBINDBUFFERPROC);
    LOAD(glDeleteBuffers, PFNGLDELETEBUFFERSPROC);
    LOAD(glGenBuffers, PFNGLGENBUFFERSPROC);
    LOAD(glBufferData, PFNGLBUFFERDATAPROC);
    LOAD(glBufferSubData, PFNGLBUFFERSUBDATAPROC);
    LOAD(glBlendEquationSeparate, PFNGLBLENDEQUATIONSEPARATEPROC);
    LOAD(glAttachShader, PFNGLATTACHSHADERPROC);
    LOAD(glCompileShader, PFNGLCOMPILESHADERPROC);
    LOAD(glCreateProgram, PFNGLCREATEPROGRAMPROC);
    LOAD(glCreateShader, PFNGLCREATESHADERPROC);
    LOAD(glDeleteProgram, PFNGLDELETEPROGRAMPROC);
    LOAD(glDeleteShader, PFNGLDELETESHADERPROC);
    LOAD(glDetachShader, PFNGLDETACHSHADERPROC);
    LOAD(glDisableVertexAttribArray, PFNGLDISABLEVERTEXATTRIBARRAYPROC);
    LOAD(glEnableVertexAttribArray, PFNGLENABLEVERTEXATTRIBARRAYPROC);
    LOAD(glGetAttribLocation, PFNGLGETATTRIBLOCATIONPROC);
    LOAD(glGetProgramiv, PFNGLGETPROGRAMIVPROC);
    LOAD(glGetProgramInfoLog, PFNGLGETPROGRAMINFOLOGPROC);
    LOAD(glGetShaderiv, PFNGLGETSHADERIVPROC);
    LOAD(glGetShaderInfoLog, PFNGLGETSHADERINFOLOGPROC);
    LOAD(glGetUniformLocation, PFNGLGETUNIFORMLOCATIONPROC);
    LOAD(glGetVertexAttribiv, PFNGLGETVERTEXATTRIBIVPROC);
    LOAD(glGetVertexAttribPointerv, PFNGLGETVERTEXATTRIBPOINTERVPROC);
    LOAD(glIsProgram, PFNGLISPROGRAMPROC);
    LOAD(glLinkProgram, PFNGLLINKPROGRAMPROC);
    LOAD(glShaderSource, PFNGLSHADERSOURCEPROC);
    LOAD(glUseProgram, PFNGLUSEPROGRAMPROC);
    LOAD(glUniform1i, PFNGLUNIFORM1IPROC);
    LOAD(glUniformMatrix4fv, PFNGLUNIFORMMATRIX4FVPROC);
    LOAD(glVertexAttribPointer, PFNGLVERTEXATTRIBPOINTERPROC);
    LOAD(glGetStringi, PFNGLGETSTRINGIPROC);
    LOAD(glBindVertexArray, PFNGLBINDVERTEXARRAYPROC);
    LOAD(glDeleteVertexArrays, PFNGLDELETEVERTEXARRAYSPROC);
    LOAD(glGenVertexArrays, PFNGLGENVERTEXARRAYSPROC);
    LOAD(glDrawElementsBaseVertex, PFNGLDRAWELEMENTSBASEVERTEXPROC);
    LOAD(glBindSampler, PFNGLBINDSAMPLERPROC);
    #undef LOAD
    return missing;
}

void zgui_glViewport(int x, int y, int w, int h) {
    if (glViewport) glViewport(x, y, w, h);
}

void zgui_glClearColor(float r, float g, float b, float a) {
    if (glClearColor) glClearColor(r, g, b, a);
}

void zgui_glClear(unsigned int mask) {
    if (glClear) glClear(mask);
}
