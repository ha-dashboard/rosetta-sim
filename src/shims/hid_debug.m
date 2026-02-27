/*
 * hid_debug.m — Diagnostic dylib for HID system debugging
 *
 * Logs IndigoHID state when loaded into backboardd:
 * 1. Whether IndigoHIDSystemSpawnLoopback symbol exists
 * 2. Whether IndigoHIDRegistrationPort is in bootstrap namespace
 * 3. Relevant environment variables
 *
 * Build:
 *   clang -arch x86_64 -dynamiclib -framework Foundation \
 *     -mios-simulator-version-min=9.0 \
 *     -isysroot $(xcrun --show-sdk-path --sdk iphonesimulator) \
 *     -install_name /usr/lib/hid_debug.dylib \
 *     -Wl,-not_for_dyld_shared_cache \
 *     -o hid_debug.dylib hid_debug.m
 *
 * Deploy: insert_dylib into backboardd + codesign
 */

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>

extern kern_return_t bootstrap_look_up(mach_port_t bp, const char *name, mach_port_t *sp);
extern mach_port_t bootstrap_port;

/* ================================================================
 * Fishhook GOT rebinding (minimal, same approach as ios8_frontboard_fix)
 * ================================================================ */

#include <mach-o/nlist.h>
#include <mach-o/loader.h>

static void rebind_symbol(const char *name, void *replacement, void **original) {
    void *sym = dlsym(RTLD_DEFAULT, name);
    if (sym && original) *original = sym;
    uint32_t imgcount = _dyld_image_count();
    for (uint32_t i = 0; i < imgcount; i++) {
        const struct mach_header_64 *header =
            (const struct mach_header_64 *)_dyld_get_image_header(i);
        if (!header || header->magic != MH_MAGIC_64) continue;
        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        const struct load_command *cmd = (void *)((char *)header + sizeof(*header));
        const struct segment_command_64 *linkedit_seg = NULL, *data_seg = NULL;
        const struct symtab_command *symtab = NULL;
        const struct dysymtab_command *dysymtab = NULL;
        for (uint32_t j = 0; j < header->ncmds; j++) {
            if (cmd->cmd == LC_SEGMENT_64) {
                const struct segment_command_64 *seg = (void *)cmd;
                if (strcmp(seg->segname, "__LINKEDIT") == 0) linkedit_seg = seg;
                else if (strcmp(seg->segname, "__DATA") == 0) data_seg = seg;
            } else if (cmd->cmd == LC_SYMTAB) symtab = (void *)cmd;
            else if (cmd->cmd == LC_DYSYMTAB) dysymtab = (void *)cmd;
            cmd = (void *)((char *)cmd + cmd->cmdsize);
        }
        if (!linkedit_seg || !data_seg || !symtab || !dysymtab) continue;
        uintptr_t linkedit_base = slide + linkedit_seg->vmaddr - linkedit_seg->fileoff;
        const struct nlist_64 *syms = (void *)(linkedit_base + symtab->symoff);
        const char *strtab = (void *)(linkedit_base + symtab->stroff);
        const uint32_t *indirect_syms = (void *)(linkedit_base + dysymtab->indirectsymoff);
        const struct section_64 *sec = (void *)((char *)data_seg + sizeof(*data_seg));
        for (uint32_t s = 0; s < data_seg->nsects; s++, sec++) {
            uint32_t type = sec->flags & SECTION_TYPE;
            if (type != S_LAZY_SYMBOL_POINTERS && type != S_NON_LAZY_SYMBOL_POINTERS) continue;
            uint32_t nptrs = (uint32_t)(sec->size / sizeof(void *));
            void **ptrs = (void **)(slide + sec->addr);
            for (uint32_t p = 0; p < nptrs; p++) {
                uint32_t symidx = indirect_syms[sec->reserved1 + p];
                if (symidx == INDIRECT_SYMBOL_ABS || symidx == INDIRECT_SYMBOL_LOCAL) continue;
                if (symidx >= symtab->nsyms) continue;
                const char *sname = strtab + syms[symidx].n_un.n_strx;
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
 * IndigoHIDSystemSpawnLoopback hook
 * ================================================================ */

static bool (*orig_IndigoHIDSystemSpawnLoopback)(void *);

static bool hook_IndigoHIDSystemSpawnLoopback(void *hidSystem) {
    bool result = orig_IndigoHIDSystemSpawnLoopback(hidSystem);
    int fd = open("/tmp/rosettasim_hid_debug.txt", O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) {
        char buf[256];
        int len = snprintf(buf, sizeof(buf),
            "[HID-DEBUG] IndigoHIDSystemSpawnLoopback(%p) returned: %d pid=%d\n",
            hidSystem, result, getpid());
        write(fd, buf, len);
        close(fd);
    }
    return result;
}

__attribute__((constructor))
static void hid_debug_init(void) {
    int fd = open("/tmp/rosettasim_hid_debug.txt", O_WRONLY | O_CREAT | O_APPEND, 0644);
    FILE *out = fd >= 0 ? fdopen(fd, "a") : stderr;

    fprintf(out, "\n=== [HID-DEBUG] pid=%d prog=%s ===\n", getpid(), getprogname());

    /* 1. Check IndigoHID symbols */
    void *sym1 = dlsym(RTLD_DEFAULT, "IndigoHIDSystemSpawnLoopback");
    void *sym2 = dlsym(RTLD_DEFAULT, "IndigoHIDSystemCreateLoopback");
    void *sym3 = dlsym(RTLD_DEFAULT, "IndigoHIDSystemCreate");
    fprintf(out, "  IndigoHIDSystemSpawnLoopback: %p\n", sym1);
    fprintf(out, "  IndigoHIDSystemCreateLoopback: %p\n", sym2);
    fprintf(out, "  IndigoHIDSystemCreate: %p\n", sym3);

    /* 2. Check bootstrap port lookups */
    mach_port_t port = MACH_PORT_NULL;
    kern_return_t kr;

    kr = bootstrap_look_up(bootstrap_port, "IndigoHIDRegistrationPort", &port);
    fprintf(out, "  IndigoHIDRegistrationPort: kr=%d port=0x%x\n", kr, port);

    port = MACH_PORT_NULL;
    kr = bootstrap_look_up(bootstrap_port, "PurpleFBServer", &port);
    fprintf(out, "  PurpleFBServer: kr=%d port=0x%x\n", kr, port);

    port = MACH_PORT_NULL;
    kr = bootstrap_look_up(bootstrap_port, "PurpleFBTVOutServer", &port);
    fprintf(out, "  PurpleFBTVOutServer: kr=%d port=0x%x\n", kr, port);

    /* 3. Relevant env vars */
    const char *envs[] = {
        "SIMULATOR_UDID", "IPHONE_SIMULATOR_DEVICE",
        "SIMULATOR_RUNTIME_VERSION", "DYLD_ROOT_PATH",
        "SIMULATOR_FRAMEBUFFER_FRAMEWORK",
        "SIMULATOR_HID_SYSTEM_MANAGER",
        "SIMULATOR_LEGACY_ASSET_SUFFIX",
        "SIMULATOR_DEVICE_NAME", NULL
    };
    for (int i = 0; envs[i]; i++) {
        const char *val = getenv(envs[i]);
        fprintf(out, "  env %s = %s\n", envs[i], val ?: "(null)");
    }

    /* 4. Check loaded dylibs for SimulatorClient / IndigoHID */
    uint32_t count = _dyld_image_count();
    fprintf(out, "  Loaded images: %u\n", count);
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && (strstr(name, "Indigo") || strstr(name, "Simulator") ||
                     strstr(name, "hid_debug") || strstr(name, "HID"))) {
            fprintf(out, "    [%u] %s\n", i, name);
        }
    }

    fprintf(out, "=== [HID-DEBUG] constructor done, fishhook active ===\n");
    if (out != stderr) fclose(out);

    /* 5. Fishhook IndigoHIDSystemSpawnLoopback to log call + return */
    if (sym1) {
        rebind_symbol("IndigoHIDSystemSpawnLoopback",
                      (void *)hook_IndigoHIDSystemSpawnLoopback,
                      (void **)&orig_IndigoHIDSystemSpawnLoopback);
    }
}
