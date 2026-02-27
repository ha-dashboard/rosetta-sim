/*
 * sim_framebuffer_stub.c — Stub for SimFramebufferClient framework
 *
 * Problem: iOS 13.7/14.5 backboardd loads SimFramebufferClient.framework which
 * calls __builtin_trap() (ud2) when SIMULATOR_FRAMEBUFFER_FRAMEWORK env var
 * isn't set. With headServices in profile, CoreSimulator doesn't set this env
 * var, causing backboardd to crash immediately.
 *
 * Fix: Replace SimFramebufferClient with a stub that returns NULL from all
 * public functions. This makes _detectSimDisplays return NO, causing QuartzCore
 * to fall back to PurpleFBServer (which our daemon provides).
 *
 * Build:
 *   clang -arch x86_64 -dynamiclib -o SimFramebufferClient \
 *     sim_framebuffer_stub.c \
 *     -install_name /System/Library/PrivateFrameworks/SimFramebufferClient.framework/SimFramebufferClient \
 *     -target x86_64-apple-ios13.0-simulator \
 *     -isysroot $(xcrun --show-sdk-path --sdk iphonesimulator)
 */

#include <stddef.h>

void* SFBConnectionCreate(void *allocator, void *name) { return NULL; }
int SFBConnectionConnect(void *conn, void **error) { return -1; }
void* SFBConnectionCopyDisplays(void *conn, void **error) { return NULL; }
void SFBConnectionInvalidate(void *conn) {}
void* SFBConnectionGetTypeID(void) { return NULL; }
void* SFBDisplayCreate(void *allocator, void *props) { return NULL; }
void* SFBDisplayGetTypeID(void) { return NULL; }
