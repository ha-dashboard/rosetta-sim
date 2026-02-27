/*
 * ios8_frontboard_fix.m — Fix crashes in iOS 8.2 simulator on macOS 26
 *
 * Fixes:
 * 1. BKSHIDEventCreateClientAttributes crash (CFDictionaryCreate with nil values)
 *    — replaced via fishhook-style GOT rebinding of CFDictionaryCreate
 * 2. Nil-safe NSMutableArray (catches nil addObject:/insertObject:atIndex:)
 * 3. Crash signal handler for diagnostics
 *
 * Build (x86_64 — runs inside Rosetta sim):
 *   clang -arch x86_64 -dynamiclib -framework Foundation -framework CoreFoundation \
 *     -mios-simulator-version-min=8.0 \
 *     -isysroot $(xcrun --show-sdk-path --sdk iphonesimulator) \
 *     -install_name /usr/lib/ios8_frontboard_fix.dylib \
 *     -o ios8_frontboard_fix.dylib ios8_frontboard_fix.m
 *
 * Injection: via insert_dylib on SpringBoard binary + codesign
 */

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#include <stdio.h>
#include <execinfo.h>
#include <signal.h>
#include <unistd.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <mach-o/nlist.h>
#include <mach-o/loader.h>

/* ================================================================
 * Fishhook-style GOT rebinding for CFDictionaryCreate
 *
 * Since DYLD __interpose only works with DYLD_INSERT_LIBRARIES,
 * we manually patch the lazy/non-lazy binding table (GOT) to redirect
 * CFDictionaryCreate calls to our nil-safe wrapper.
 * ================================================================ */

static CFDictionaryRef (*orig_CFDictionaryCreate)(CFAllocatorRef, const void **,
    const void **, CFIndex, const CFDictionaryKeyCallBacks *,
    const CFDictionaryValueCallBacks *);

static CFDictionaryRef safe_CFDictionaryCreate(CFAllocatorRef allocator,
    const void **keys, const void **values, CFIndex numValues,
    const CFDictionaryKeyCallBacks *keyCallBacks,
    const CFDictionaryValueCallBacks *valueCallBacks) {

    if (numValues > 0 && keys && values) {
        /* Check for nil keys/values */
        int has_nil = 0;
        for (CFIndex i = 0; i < numValues; i++) {
            if (keys[i] == NULL || values[i] == NULL) { has_nil = 1; break; }
        }
        if (has_nil) {
            const void *safeKeys[numValues];
            const void *safeValues[numValues];
            CFIndex safeCount = 0;
            for (CFIndex i = 0; i < numValues; i++) {
                if (keys[i] != NULL && values[i] != NULL) {
                    safeKeys[safeCount] = keys[i];
                    safeValues[safeCount] = values[i];
                    safeCount++;
                }
            }
            return orig_CFDictionaryCreate(allocator, safeKeys, safeValues,
                                           safeCount, keyCallBacks, valueCallBacks);
        }
    }
    return orig_CFDictionaryCreate(allocator, keys, values, numValues,
                                   keyCallBacks, valueCallBacks);
}

/* Minimal fishhook: rebind a symbol in all loaded images' GOT */
static void rebind_symbol(const char *name, void *replacement, void **original) {
    void *sym = dlsym(RTLD_DEFAULT, name);
    if (sym && original) *original = sym;

    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const struct mach_header_64 *header =
            (const struct mach_header_64 *)_dyld_get_image_header(i);
        if (!header || header->magic != MH_MAGIC_64) continue;

        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        const struct load_command *cmd = (void *)((char *)header + sizeof(*header));

        const struct segment_command_64 *linkedit_seg = NULL;
        const struct segment_command_64 *data_seg = NULL;
        const struct symtab_command *symtab = NULL;
        const struct dysymtab_command *dysymtab = NULL;

        for (uint32_t j = 0; j < header->ncmds; j++) {
            if (cmd->cmd == LC_SEGMENT_64) {
                const struct segment_command_64 *seg = (void *)cmd;
                if (strcmp(seg->segname, "__LINKEDIT") == 0) linkedit_seg = seg;
                else if (strcmp(seg->segname, "__DATA") == 0) data_seg = seg;
            } else if (cmd->cmd == LC_SYMTAB) {
                symtab = (void *)cmd;
            } else if (cmd->cmd == LC_DYSYMTAB) {
                dysymtab = (void *)cmd;
            }
            cmd = (void *)((char *)cmd + cmd->cmdsize);
        }
        if (!linkedit_seg || !data_seg || !symtab || !dysymtab) continue;

        uintptr_t linkedit_base = slide + linkedit_seg->vmaddr - linkedit_seg->fileoff;
        const struct nlist_64 *syms = (void *)(linkedit_base + symtab->symoff);
        const char *strtab = (void *)(linkedit_base + symtab->stroff);
        const uint32_t *indirect_syms = (void *)(linkedit_base + dysymtab->indirectsymoff);

        /* Walk __DATA sections looking for __la_symbol_ptr and __got */
        const struct section_64 *sec = (void *)((char *)data_seg + sizeof(*data_seg));
        for (uint32_t s = 0; s < data_seg->nsects; s++, sec++) {
            uint32_t type = sec->flags & SECTION_TYPE;
            if (type != S_LAZY_SYMBOL_POINTERS && type != S_NON_LAZY_SYMBOL_POINTERS)
                continue;

            uint32_t stride = sizeof(void *);
            uint32_t nptrs = (uint32_t)(sec->size / stride);
            void **ptrs = (void **)(slide + sec->addr);

            for (uint32_t p = 0; p < nptrs; p++) {
                uint32_t symidx = indirect_syms[sec->reserved1 + p];
                if (symidx == INDIRECT_SYMBOL_ABS || symidx == INDIRECT_SYMBOL_LOCAL)
                    continue;
                if (symidx >= symtab->nsyms) continue;

                const char *sname = strtab + syms[symidx].n_un.n_strx;
                /* Symbol names have a leading underscore */
                if (sname[0] == '_') sname++;
                if (strcmp(sname, name) == 0) {
                    if (original && *original == NULL) *original = ptrs[p];
                    ptrs[p] = replacement;
                }
            }
        }
    }
}

/* ================================================================
 * Crash signal handler — writes backtrace to file
 * ================================================================ */

static void crash_handler(int sig) {
    void *bt[64];
    int count = backtrace(bt, 64);
    int fd = open("/tmp/rosettasim_crash_backtrace.txt",
                  O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) {
        char buf[128];
        int len = snprintf(buf, sizeof(buf),
            "[RosettaSim] CRASH signal=%d pid=%d\n", sig, getpid());
        write(fd, buf, len);
        backtrace_symbols_fd(bt, count, fd);
        close(fd);
    }
    fprintf(stderr, "\n[RosettaSim] CRASH signal=%d pid=%d\n", sig, getpid());
    backtrace_symbols_fd(bt, count, STDERR_FILENO);
    _exit(128 + sig);
}

/* ================================================================
 * Nil-safe NSMutableArray swizzle
 * ================================================================ */

static void (*orig_insertObject)(id, SEL, id, NSUInteger);
static void (*orig_addObject)(id, SEL, id);

static void safe_insertObject(id self, SEL _cmd, id obj, NSUInteger idx) {
    if (obj == nil) return;
    orig_insertObject(self, _cmd, obj, idx);
}

static void safe_addObject(id self, SEL _cmd, id obj) {
    if (obj == nil) return;
    orig_addObject(self, _cmd, obj);
}

/* ================================================================
 * C++ exception logging — intercept __cxa_throw and __cxa_bad_cast
 * ================================================================ */

static void (*orig_cxa_throw)(void *, void *, void (*)(void *));
static void my_cxa_throw(void *thrown_exception, void *tinfo, void (*dest)(void *)) {
    void *bt[32];
    int count = backtrace(bt, 32);
    int fd = open("/tmp/rosettasim_cxa_throw.txt",
                  O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) {
        char buf[256];
        /* Try to get type name from typeinfo */
        const char *tname = "unknown";
        if (tinfo) {
            /* std::type_info layout: vtable ptr at [0], name at [1] */
            const char **ti = (const char **)tinfo;
            if (ti[1]) tname = ti[1];
        }
        int len = snprintf(buf, sizeof(buf),
            "[RosettaSim] __cxa_throw: type=%s tinfo=%p pid=%d\n",
            tname, tinfo, getpid());
        write(fd, buf, len);
        backtrace_symbols_fd(bt, count, fd);
        write(fd, "\n", 1);
        close(fd);
    }
    orig_cxa_throw(thrown_exception, tinfo, dest);
    __builtin_unreachable();
}

static void (*orig_cxa_bad_cast)(void);
static void my_cxa_bad_cast(void) {
    void *bt[32];
    int count = backtrace(bt, 32);
    int fd = open("/tmp/rosettasim_cxa_throw.txt",
                  O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) {
        char buf[128];
        int len = snprintf(buf, sizeof(buf),
            "[RosettaSim] __cxa_bad_cast pid=%d\n", getpid());
        write(fd, buf, len);
        backtrace_symbols_fd(bt, count, fd);
        write(fd, "\n", 1);
        close(fd);
    }
    orig_cxa_bad_cast();
    __builtin_unreachable();
}

/* ================================================================
 * [NSBundle mainBundle] nil fix
 * ================================================================ */

static NSBundle *(*orig_mainBundle)(id, SEL);
static NSBundle *fixed_mainBundle(id self, SEL _cmd) {
    NSBundle *bundle = orig_mainBundle(self, _cmd);
    if (!bundle) {
        static NSBundle *fallback = nil;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            NSString *execPath = [NSProcessInfo processInfo].arguments.firstObject;
            if (execPath) {
                /* Walk up to find .app directory */
                NSString *path = execPath;
                while (path.length > 1 && ![[path pathExtension] isEqualToString:@"app"]) {
                    path = [path stringByDeletingLastPathComponent];
                }
                if ([[path pathExtension] isEqualToString:@"app"]) {
                    fallback = [NSBundle bundleWithPath:path];
                    NSLog(@"[RosettaSim] mainBundle fix: created fallback from %@", path);
                }
            }
            if (!fallback) {
                fallback = [NSBundle bundleForClass:NSClassFromString(@"SpringBoard")]
                    ?: [NSBundle bundleWithPath:@"/System/Library/CoreServices/SpringBoard.app"];
                NSLog(@"[RosettaSim] mainBundle fix: using last resort path");
            }
        });
        return fallback;
    }
    return bundle;
}

/* ================================================================
 * Constructor
 * ================================================================ */

__attribute__((constructor))
static void fix_frontboard(void) {
    /* Install crash signal handlers FIRST */
    signal(SIGABRT, crash_handler);
    signal(SIGSEGV, crash_handler);
    signal(SIGBUS, crash_handler);
    signal(SIGTRAP, crash_handler);
    signal(SIGILL, crash_handler);

    /* Write marker file */
    FILE *f = fopen("/tmp/rosettasim_frontboard_fix_loaded", "w");
    if (f) { fprintf(f, "loaded pid=%d\n", getpid()); fclose(f); }

    /* Rebind CFDictionaryCreate across all loaded images */
    orig_CFDictionaryCreate = NULL;
    rebind_symbol("CFDictionaryCreate", (void *)safe_CFDictionaryCreate,
                  (void **)&orig_CFDictionaryCreate);

    FILE *f2 = fopen("/tmp/rosettasim_frontboard_rebound", "w");
    if (f2) {
        fprintf(f2, "rebound pid=%d orig=%p\n", getpid(), (void *)orig_CFDictionaryCreate);
        fclose(f2);
    }

    /* Rebind __cxa_throw and __cxa_bad_cast for C++ exception logging */
    orig_cxa_throw = NULL;
    rebind_symbol("__cxa_throw", (void *)my_cxa_throw, (void **)&orig_cxa_throw);
    orig_cxa_bad_cast = NULL;
    rebind_symbol("__cxa_bad_cast", (void *)my_cxa_bad_cast, (void **)&orig_cxa_bad_cast);

    /* Swizzle __NSArrayM */
    Class cls = objc_getClass("__NSArrayM");
    if (cls) {
        Method m1 = class_getInstanceMethod(cls, sel_registerName("insertObject:atIndex:"));
        if (m1) {
            orig_insertObject = (void *)method_getImplementation(m1);
            method_setImplementation(m1, (IMP)safe_insertObject);
        }
        Method m2 = class_getInstanceMethod(cls, sel_registerName("addObject:"));
        if (m2) {
            orig_addObject = (void *)method_getImplementation(m2);
            method_setImplementation(m2, (IMP)safe_addObject);
        }
    }

    /* Fix [NSBundle mainBundle] returning nil */
    Method mainBundleMethod = class_getClassMethod([NSBundle class], @selector(mainBundle));
    if (mainBundleMethod) {
        orig_mainBundle = (NSBundle *(*)(id, SEL))method_getImplementation(mainBundleMethod);
        method_setImplementation(mainBundleMethod, (IMP)fixed_mainBundle);
    }

    /* Suppress NSAssert failures — turns exceptions into log messages.
     * Under Rosetta 2, ObjC exceptions → std::terminate → crash.
     * This intercepts ALL NSAssert/NSCAssert before they throw. */
    Class ahCls = objc_getClass("NSAssertionHandler");
    if (ahCls) {
        SEL sel1 = sel_registerName("handleFailureInMethod:object:file:lineNumber:description:");
        Method am1 = class_getInstanceMethod(ahCls, sel1);
        if (am1) {
            method_setImplementation(am1, imp_implementationWithBlock(
                ^(id self, SEL sel, id obj, NSString *file, NSInteger line, NSString *desc) {
                    NSLog(@"[RosettaSim] ASSERTION SUPPRESSED: %@ (line %ld in %@)",
                          desc, (long)line, file);
                }));
        }
        SEL sel2 = sel_registerName("handleFailureInFunction:file:lineNumber:description:");
        Method am2 = class_getInstanceMethod(ahCls, sel2);
        if (am2) {
            method_setImplementation(am2, imp_implementationWithBlock(
                ^(id self, NSString *func, NSString *file, NSInteger line, NSString *desc) {
                    NSLog(@"[RosettaSim] ASSERTION SUPPRESSED: %@ in %@ (line %ld in %@)",
                          desc, func, (long)line, file);
                }));
        }
    }
}
