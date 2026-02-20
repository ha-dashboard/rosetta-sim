/*
 * sfb_bridge.c — SimFramebufferClient Protocol Bridge
 *
 * Replaces the iOS 12.4 SimFramebufferClient (v554) with a bridge that
 * delegates to the iOS 14.5 SimFramebufferClient (v732.8), which speaks
 * the modern protocol compatible with Xcode 13's SimFramebuffer host.
 *
 * Build:
 *   clang -arch x86_64 -dynamiclib \
 *     -isysroot $SDK -mios-simulator-version-min=12.0 \
 *     -install_name /System/Library/PrivateFrameworks/SimFramebufferClient.framework/SimFramebufferClient \
 *     -framework CoreFoundation \
 *     -o sfb_bridge.dylib sfb_bridge.c
 *
 * Install: Replace SimFramebufferClient in iOS 12.4 runtime, rebuild shared cache.
 */

#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <mach/mach.h>

/* ========================================================================
 * Backend handle — the iOS 14.5 SimFramebufferClient loaded via dlopen
 * ======================================================================== */

static void *g_backend = NULL;
static int g_initialized = 0;

/* Path where we place the iOS 14.5 SimFramebufferClient binary */
#define BACKEND_PATH "/System/Library/PrivateFrameworks/SimFramebufferClient.framework/_SimFramebufferClient_v732"

static void ensure_backend(void) {
    if (g_backend) return;

    /* Try the co-located backend first */
    const char *root = getenv("IPHONE_SIMULATOR_ROOT");
    if (root) {
        char path[1024];
        snprintf(path, sizeof(path), "%s%s", root, BACKEND_PATH);
        g_backend = dlopen(path, RTLD_LAZY | RTLD_LOCAL);
        if (g_backend) {
            fprintf(stderr, "[sfb_bridge] loaded backend from %s\n", path);
            return;
        }
    }

    fprintf(stderr, "[sfb_bridge] ERROR: could not load backend: %s\n", dlerror());
}

/* Resolve a symbol from the backend, with caching */
#define RESOLVE(name) \
    static void *_fn_##name = NULL; \
    if (!_fn_##name) { \
        ensure_backend(); \
        if (g_backend) _fn_##name = dlsym(g_backend, #name); \
        if (!_fn_##name) fprintf(stderr, "[sfb_bridge] WARNING: " #name " not found in backend\n"); \
    }

/* ========================================================================
 * Opaque CF types used by the SFB API
 * ======================================================================== */

typedef const void *SFBConnectionRef;
typedef const void *SFBDisplayRef;
typedef const void *SFBSwapchainRef;
typedef CFTypeID SFBTypeID;

/* ========================================================================
 * SFBClientInitialize — THE critical bridge function
 *
 * In v554, this was the main entry point called by SimulatorClient's
 * IndigoHIDSystemSpawnLoopback. It dlopen'd SimFramebuffer.framework
 * and set up the display connection.
 *
 * In v732.8, this function doesn't exist. Instead, the backend does
 * auto-initialization when loaded. We trigger that by calling
 * SFBConnectionCreate + SFBConnectionConnect.
 * ======================================================================== */

int SFBClientInitialize(void) {
    fprintf(stderr, "[sfb_bridge] SFBClientInitialize called\n");

    ensure_backend();
    if (!g_backend) {
        fprintf(stderr, "[sfb_bridge] SFBClientInitialize: no backend\n");
        return 0;
    }

    if (g_initialized) return 1;
    g_initialized = 1;

    fprintf(stderr, "[sfb_bridge] SFBClientInitialize: backend loaded, init complete\n");
    return 1;
}

/* ========================================================================
 * Connection functions — shared between v554 and v732
 * ======================================================================== */

SFBTypeID SFBConnectionGetTypeID(void) {
    RESOLVE(SFBConnectionGetTypeID);
    if (_fn_SFBConnectionGetTypeID) {
        return ((SFBTypeID(*)(void))_fn_SFBConnectionGetTypeID)();
    }
    return 0;
}

SFBConnectionRef SFBConnectionCreate(CFAllocatorRef alloc) {
    ensure_backend();
    RESOLVE(SFBConnectionCreate);
    if (_fn_SFBConnectionCreate) {
        return ((SFBConnectionRef(*)(CFAllocatorRef))_fn_SFBConnectionCreate)(alloc);
    }
    return NULL;
}

int SFBConnectionConnect(SFBConnectionRef conn) {
    RESOLVE(SFBConnectionConnect);
    if (_fn_SFBConnectionConnect) {
        return ((int(*)(SFBConnectionRef))_fn_SFBConnectionConnect)(conn);
    }
    return 0;
}

CFArrayRef SFBConnectionCopyDisplays(SFBConnectionRef conn) {
    RESOLVE(SFBConnectionCopyDisplays);
    if (_fn_SFBConnectionCopyDisplays) {
        return ((CFArrayRef(*)(SFBConnectionRef))_fn_SFBConnectionCopyDisplays)(conn);
    }
    return NULL;
}

uint64_t SFBConnectionGetID(SFBConnectionRef conn) {
    RESOLVE(SFBConnectionGetID);
    if (_fn_SFBConnectionGetID) {
        return ((uint64_t(*)(SFBConnectionRef))_fn_SFBConnectionGetID)(conn);
    }
    return 0;
}

void SFBConnectionSetDisplayConnectedHandler(SFBConnectionRef conn, void *handler) {
    RESOLVE(SFBConnectionSetDisplayConnectedHandler);
    if (_fn_SFBConnectionSetDisplayConnectedHandler) {
        ((void(*)(SFBConnectionRef, void*))_fn_SFBConnectionSetDisplayConnectedHandler)(conn, handler);
    }
}

void SFBConnectionSetDisplayDisconnectedHandler(SFBConnectionRef conn, void *handler) {
    RESOLVE(SFBConnectionSetDisplayDisconnectedHandler);
    if (_fn_SFBConnectionSetDisplayDisconnectedHandler) {
        ((void(*)(SFBConnectionRef, void*))_fn_SFBConnectionSetDisplayDisconnectedHandler)(conn, handler);
    }
}

void SFBConnectionSetDisplayUpdatedHandler(SFBConnectionRef conn, void *handler) {
    RESOLVE(SFBConnectionSetDisplayUpdatedHandler);
    if (_fn_SFBConnectionSetDisplayUpdatedHandler) {
        ((void(*)(SFBConnectionRef, void*))_fn_SFBConnectionSetDisplayUpdatedHandler)(conn, handler);
    }
}

/* ========================================================================
 * Display functions — shared between v554 and v732
 * ======================================================================== */

SFBTypeID SFBDisplayGetTypeID(void) {
    RESOLVE(SFBDisplayGetTypeID);
    if (_fn_SFBDisplayGetTypeID) {
        return ((SFBTypeID(*)(void))_fn_SFBDisplayGetTypeID)();
    }
    return 0;
}

uint64_t SFBDisplayGetID(SFBDisplayRef disp) {
    RESOLVE(SFBDisplayGetID);
    if (_fn_SFBDisplayGetID) {
        return ((uint64_t(*)(SFBDisplayRef))_fn_SFBDisplayGetID)(disp);
    }
    return 0;
}

CFStringRef SFBDisplayGetName(SFBDisplayRef disp) {
    RESOLVE(SFBDisplayGetName);
    if (_fn_SFBDisplayGetName) {
        return ((CFStringRef(*)(SFBDisplayRef))_fn_SFBDisplayGetName)(disp);
    }
    return CFSTR("Default");
}

CFStringRef SFBDisplayGetDisplayUID(SFBDisplayRef disp) {
    RESOLVE(SFBDisplayGetDisplayUID);
    if (_fn_SFBDisplayGetDisplayUID) {
        return ((CFStringRef(*)(SFBDisplayRef))_fn_SFBDisplayGetDisplayUID)(disp);
    }
    return CFSTR("00000000-0000-0000-0000-000000000000");
}

uint64_t SFBDisplayGetConnectionID(SFBDisplayRef disp) {
    RESOLVE(SFBDisplayGetConnectionID);
    if (_fn_SFBDisplayGetConnectionID) {
        return ((uint64_t(*)(SFBDisplayRef))_fn_SFBDisplayGetConnectionID)(disp);
    }
    return 0;
}

typedef struct { uint32_t width; uint32_t height; } SFBSize;

SFBSize SFBDisplayGetDeviceSize(SFBDisplayRef disp) {
    RESOLVE(SFBDisplayGetDeviceSize);
    if (_fn_SFBDisplayGetDeviceSize) {
        return ((SFBSize(*)(SFBDisplayRef))_fn_SFBDisplayGetDeviceSize)(disp);
    }
    SFBSize s = {768, 1024};
    return s;
}

uint32_t SFBDisplayGetDotPitch(SFBDisplayRef disp) {
    RESOLVE(SFBDisplayGetDotPitch);
    if (_fn_SFBDisplayGetDotPitch) {
        return ((uint32_t(*)(SFBDisplayRef))_fn_SFBDisplayGetDotPitch)(disp);
    }
    return 264;
}

uint32_t SFBDisplayGetFlags(SFBDisplayRef disp) {
    RESOLVE(SFBDisplayGetFlags);
    if (_fn_SFBDisplayGetFlags) {
        return ((uint32_t(*)(SFBDisplayRef))_fn_SFBDisplayGetFlags)(disp);
    }
    return 0;
}

uint32_t SFBDisplayGetType(SFBDisplayRef disp) {
    RESOLVE(SFBDisplayGetType);
    if (_fn_SFBDisplayGetType) {
        return ((uint32_t(*)(SFBDisplayRef))_fn_SFBDisplayGetType)(disp);
    }
    return 0;
}

void *SFBDisplayGetExtendedProperties(SFBDisplayRef disp) {
    RESOLVE(SFBDisplayGetExtendedProperties);
    if (_fn_SFBDisplayGetExtendedProperties) {
        return ((void*(*)(SFBDisplayRef))_fn_SFBDisplayGetExtendedProperties)(disp);
    }
    return NULL;
}

CFArrayRef SFBDisplayCopyExtendedPropertyProtocols(SFBDisplayRef disp) {
    RESOLVE(SFBDisplayCopyExtendedPropertyProtocols);
    if (_fn_SFBDisplayCopyExtendedPropertyProtocols) {
        return ((CFArrayRef(*)(SFBDisplayRef))_fn_SFBDisplayCopyExtendedPropertyProtocols)(disp);
    }
    return NULL;
}

uint32_t SFBDisplayGetMaxLayerCount(SFBDisplayRef disp) {
    RESOLVE(SFBDisplayGetMaxLayerCount);
    if (_fn_SFBDisplayGetMaxLayerCount) {
        return ((uint32_t(*)(SFBDisplayRef))_fn_SFBDisplayGetMaxLayerCount)(disp);
    }
    return 1;
}

uint32_t SFBDisplayGetMaxSwapchainCount(SFBDisplayRef disp) {
    RESOLVE(SFBDisplayGetMaxSwapchainCount);
    if (_fn_SFBDisplayGetMaxSwapchainCount) {
        return ((uint32_t(*)(SFBDisplayRef))_fn_SFBDisplayGetMaxSwapchainCount)(disp);
    }
    return 3;
}

uint32_t SFBDisplayGetSupportedPresentationModes(SFBDisplayRef disp) {
    RESOLVE(SFBDisplayGetSupportedPresentationModes);
    if (_fn_SFBDisplayGetSupportedPresentationModes) {
        return ((uint32_t(*)(SFBDisplayRef))_fn_SFBDisplayGetSupportedPresentationModes)(disp);
    }
    return 0;
}

uint32_t SFBDisplayGetSupportedSurfaceFlags(SFBDisplayRef disp) {
    RESOLVE(SFBDisplayGetSupportedSurfaceFlags);
    if (_fn_SFBDisplayGetSupportedSurfaceFlags) {
        return ((uint32_t(*)(SFBDisplayRef))_fn_SFBDisplayGetSupportedSurfaceFlags)(disp);
    }
    return 0;
}

SFBSwapchainRef SFBDisplayCreateSwapchain(SFBDisplayRef disp, void *opts) {
    RESOLVE(SFBDisplayCreateSwapchain);
    if (_fn_SFBDisplayCreateSwapchain) {
        return ((SFBSwapchainRef(*)(SFBDisplayRef, void*))_fn_SFBDisplayCreateSwapchain)(disp, opts);
    }
    return NULL;
}

/* ========================================================================
 * Display functions — REMOVED in v732, need translation/stubs
 * ======================================================================== */

/* SFBDisplayGetRenderSize → delegate to SFBDisplayGetDeviceSize */
SFBSize SFBDisplayGetRenderSize(SFBDisplayRef disp) {
    return SFBDisplayGetDeviceSize(disp);
}

SFBSize SFBDisplayGetMaxRenderSize(SFBDisplayRef disp) {
    return SFBDisplayGetDeviceSize(disp);
}

SFBSize SFBDisplayGetMinRenderSize(SFBDisplayRef disp) {
    return SFBDisplayGetDeviceSize(disp);
}

float SFBDisplayGetPreferredUIScale(SFBDisplayRef disp) {
    /* Read from SIMULATOR_MAINSCREEN_SCALE env */
    const char *scale = getenv("SIMULATOR_MAINSCREEN_SCALE");
    if (scale) return (float)atof(scale);
    return 2.0f;
}

uint32_t SFBDisplayGetColorMode(SFBDisplayRef disp, uint32_t index) {
    (void)disp; (void)index;
    return 0; /* default color mode */
}

uint32_t SFBDisplayGetColorModeCount(SFBDisplayRef disp) {
    (void)disp;
    return 1;
}

uint32_t SFBDisplayGetMaxSwapchainSurfaceCount(SFBDisplayRef disp) {
    (void)disp;
    return 3;
}

/* SFBGetIsLegacyMode — indicates old protocol mode */
int SFBGetIsLegacyMode(void) {
    return 0; /* we're using the new protocol */
}

/* ========================================================================
 * Swapchain functions — shared
 * ======================================================================== */

SFBTypeID SFBSwapchainGetTypeID(void) {
    RESOLVE(SFBSwapchainGetTypeID);
    if (_fn_SFBSwapchainGetTypeID) {
        return ((SFBTypeID(*)(void))_fn_SFBSwapchainGetTypeID)();
    }
    return 0;
}

uint64_t SFBSwapchainGetID(SFBSwapchainRef sc) {
    RESOLVE(SFBSwapchainGetID);
    if (_fn_SFBSwapchainGetID) {
        return ((uint64_t(*)(SFBSwapchainRef))_fn_SFBSwapchainGetID)(sc);
    }
    return 0;
}

uint64_t SFBSwapchainGetDisplayID(SFBSwapchainRef sc) {
    RESOLVE(SFBSwapchainGetDisplayID);
    if (_fn_SFBSwapchainGetDisplayID) {
        return ((uint64_t(*)(SFBSwapchainRef))_fn_SFBSwapchainGetDisplayID)(sc);
    }
    return 0;
}

uint64_t SFBSwapchainGetConnectionID(SFBSwapchainRef sc) {
    RESOLVE(SFBSwapchainGetConnectionID);
    if (_fn_SFBSwapchainGetConnectionID) {
        return ((uint64_t(*)(SFBSwapchainRef))_fn_SFBSwapchainGetConnectionID)(sc);
    }
    return 0;
}

uint32_t SFBSwapchainGetPixelFormat(SFBSwapchainRef sc) {
    RESOLVE(SFBSwapchainGetPixelFormat);
    if (_fn_SFBSwapchainGetPixelFormat) {
        return ((uint32_t(*)(SFBSwapchainRef))_fn_SFBSwapchainGetPixelFormat)(sc);
    }
    return 0;
}

uint32_t SFBSwapchainGetColorspace(SFBSwapchainRef sc) {
    RESOLVE(SFBSwapchainGetColorspace);
    if (_fn_SFBSwapchainGetColorspace) {
        return ((uint32_t(*)(SFBSwapchainRef))_fn_SFBSwapchainGetColorspace)(sc);
    }
    return 0;
}

uint32_t SFBSwapchainGetPresentationMode(SFBSwapchainRef sc) {
    RESOLVE(SFBSwapchainGetPresentationMode);
    if (_fn_SFBSwapchainGetPresentationMode) {
        return ((uint32_t(*)(SFBSwapchainRef))_fn_SFBSwapchainGetPresentationMode)(sc);
    }
    return 0;
}

/* ========================================================================
 * Swapchain functions — REMOVED in v732, need translation
 *
 * Old model: AcquireSurface → write to shmem → PresentSurface
 * New model: SwapBegin → SwapAddSurface → SwapSubmit
 * ======================================================================== */

int SFBSwapchainAcquireSurface(SFBSwapchainRef sc, void *out_surface) {
    /* In the new API, this becomes AcquireSurfaceFence */
    RESOLVE(SFBSwapchainAcquireSurfaceFence);
    if (_fn_SFBSwapchainAcquireSurfaceFence) {
        return ((int(*)(SFBSwapchainRef, void*))_fn_SFBSwapchainAcquireSurfaceFence)(sc, out_surface);
    }
    return -1;
}

int SFBSwapchainPresentSurface(SFBSwapchainRef sc, void *params) {
    /* Translate old present to new swap model */
    RESOLVE(SFBSwapchainSwapBegin);
    RESOLVE(SFBSwapchainSwapSubmit);
    if (_fn_SFBSwapchainSwapBegin && _fn_SFBSwapchainSwapSubmit) {
        int ret = ((int(*)(SFBSwapchainRef))_fn_SFBSwapchainSwapBegin)(sc);
        if (ret != 0) return ret;
        return ((int(*)(SFBSwapchainRef))_fn_SFBSwapchainSwapSubmit)(sc);
    }
    return -1;
}

int SFBSwapchainPresentSurfaceAsync(SFBSwapchainRef sc, void *params) {
    /* Same as sync for now */
    return SFBSwapchainPresentSurface(sc, params);
}

/* Old surface property getters — stub with reasonable defaults */
uint32_t SFBSwapchainGetSurfaceCount(SFBSwapchainRef sc) { (void)sc; return 3; }
uint32_t SFBSwapchainGetSurfaceFlags(SFBSwapchainRef sc) { (void)sc; return 0; }
uint32_t SFBSwapchainGetSurfaceRowSize(SFBSwapchainRef sc) { (void)sc; return 0; }
void *SFBSwapchainGetSurfaceSharedMemoryPtr(SFBSwapchainRef sc) { (void)sc; return NULL; }
uint64_t SFBSwapchainGetSurfaceSharedMemorySize(SFBSwapchainRef sc) { (void)sc; return 0; }
SFBSize SFBSwapchainGetSurfaceSize(SFBSwapchainRef sc) { (void)sc; SFBSize s = {0,0}; return s; }
uint32_t SFBSwapchainGetSurfaceType(SFBSwapchainRef sc) { (void)sc; return 0; }
uint32_t SFBSwapchainGetRenderingDeviceFlags(SFBSwapchainRef sc) { (void)sc; return 0; }
uint32_t SFBSwapchainGetRenderingDeviceID(SFBSwapchainRef sc) { (void)sc; return 0; }

/* ========================================================================
 * Set utility functions — REMOVED in v732, provide simple implementations
 * ======================================================================== */

CFSetRef SFBSetCreateFromArray(CFAllocatorRef alloc, CFArrayRef array) {
    if (!array) return NULL;
    CFIndex count = CFArrayGetCount(array);
    const void **values = (const void **)malloc(count * sizeof(void*));
    CFArrayGetValues(array, CFRangeMake(0, count), values);
    CFSetRef set = CFSetCreate(alloc, values, count, &kCFTypeSetCallBacks);
    free(values);
    return set;
}

CFSetRef SFBSetCreateByAddingSet(CFSetRef a, CFSetRef b) {
    CFMutableSetRef result = CFSetCreateMutableCopy(NULL, 0, a);
    if (b) {
        CFIndex count = CFSetGetCount(b);
        const void **values = (const void **)malloc(count * sizeof(void*));
        CFSetGetValues(b, values);
        for (CFIndex i = 0; i < count; i++) CFSetAddValue(result, values[i]);
        free(values);
    }
    return result;
}

CFSetRef SFBSetCreateByIntersectingSet(CFSetRef a, CFSetRef b) {
    CFMutableSetRef result = CFSetCreateMutable(NULL, 0, &kCFTypeSetCallBacks);
    if (a && b) {
        CFIndex count = CFSetGetCount(a);
        const void **values = (const void **)malloc(count * sizeof(void*));
        CFSetGetValues(a, values);
        for (CFIndex i = 0; i < count; i++) {
            if (CFSetContainsValue(b, values[i])) CFSetAddValue(result, values[i]);
        }
        free(values);
    }
    return result;
}

CFSetRef SFBSetCreateBySubtractingSet(CFSetRef a, CFSetRef b) {
    CFMutableSetRef result = CFSetCreateMutableCopy(NULL, 0, a);
    if (b) {
        CFIndex count = CFSetGetCount(b);
        const void **values = (const void **)malloc(count * sizeof(void*));
        CFSetGetValues(b, values);
        for (CFIndex i = 0; i < count; i++) CFSetRemoveValue(result, values[i]);
        free(values);
    }
    return result;
}

CFSetRef SFBSetGetEmpty(void) {
    static CFSetRef empty = NULL;
    if (!empty) empty = CFSetCreate(NULL, NULL, 0, &kCFTypeSetCallBacks);
    return empty;
}
