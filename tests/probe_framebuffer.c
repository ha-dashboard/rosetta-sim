/* probe_framebuffer.c - Diagnostic tool to probe SimFramebuffer connection in iOS 12.4 simulator
 * Compile: clang -arch x86_64 -isysroot $SDK -mios-simulator-version-min=12.0 -o probe_fb probe_framebuffer.c
 * Run: DYLD_ROOT_PATH=$RUNTIME_ROOT ./probe_fb
 */
#include <stdio.h>
#include <stdlib.h>
#include <dlfcn.h>
#include <string.h>
#include <mach/mach.h>
#include <mach/mach_port.h>

/* bootstrap.h is not always available, declare manually */
extern kern_return_t bootstrap_look_up(mach_port_t bp, const char *name, mach_port_t *sp);

int main(int argc, char *argv[]) {
    printf("=== SimFramebuffer Probe ===\n\n");

    /* 1. Check environment variables */
    const char *fb_fw = getenv("SIMULATOR_FRAMEBUFFER_FRAMEWORK");
    const char *hid_mgr = getenv("SIMULATOR_HID_SYSTEM_MANAGER");
    const char *cookie = getenv("simFramebufferRandomCookie");
    printf("SIMULATOR_FRAMEBUFFER_FRAMEWORK: %s\n", fb_fw ? fb_fw : "(not set)");
    printf("SIMULATOR_HID_SYSTEM_MANAGER: %s\n", hid_mgr ? hid_mgr : "(not set)");
    printf("simFramebufferRandomCookie: %s\n", cookie ? cookie : "(not set)");
    printf("\n");

    /* 2. Try to dlopen SimFramebuffer */
    if (!fb_fw) {
        printf("ERROR: SIMULATOR_FRAMEBUFFER_FRAMEWORK not set\n");
        return 1;
    }

    printf("Trying to dlopen: %s\n", fb_fw);
    void *handle = dlopen(fb_fw, RTLD_LAZY);
    if (!handle) {
        printf("dlopen FAILED: %s\n", dlerror());
        return 1;
    }
    printf("dlopen SUCCESS\n\n");

    /* 3. Look up simFramebufferServerPortName */
    typedef const char* (*port_name_fn)(void);
    port_name_fn get_port_name = (port_name_fn)dlsym(handle, "simFramebufferServerPortName");
    if (get_port_name) {
        const char *name = get_port_name();
        printf("simFramebufferServerPortName: %s\n", name ? name : "(null)");

        /* 4. Try bootstrap_look_up for this service */
        if (name) {
            mach_port_t bp = MACH_PORT_NULL;
            task_get_bootstrap_port(mach_task_self(), &bp);
            printf("Bootstrap port: 0x%x\n", bp);

            mach_port_t sp = MACH_PORT_NULL;
            kern_return_t kr = bootstrap_look_up(bp, name, &sp);
            printf("bootstrap_look_up(%s): kr=%d (0x%x), port=0x%x\n",
                   name, kr, kr, sp);
            if (kr == 0 && sp != MACH_PORT_NULL) {
                printf("*** SERVICE FOUND! Port is valid ***\n");
            } else {
                printf("Service NOT found (expected if not in sim bootstrap)\n");
            }
        }
    } else {
        printf("simFramebufferServerPortName not found in framework\n");
    }
    printf("\n");

    /* 5. Try looking up other possible service names */
    const char *service_names[] = {
        "com.apple.CoreSimulator.SimFramebufferServer",
        "com.apple.CoreSimulator.IndigoFramebufferServices.Display",
        "com.apple.SimFramebuffer.0",
        "com.apple.SimFramebuffer.1",
        NULL
    };

    mach_port_t bp = MACH_PORT_NULL;
    task_get_bootstrap_port(mach_task_self(), &bp);

    printf("=== Probing known service names ===\n");
    for (int i = 0; service_names[i]; i++) {
        mach_port_t sp = MACH_PORT_NULL;
        kern_return_t kr = bootstrap_look_up(bp, service_names[i], &sp);
        printf("  %-55s -> kr=%d port=0x%x %s\n",
               service_names[i], kr, sp,
               (kr == 0 && sp != MACH_PORT_NULL) ? "FOUND" : "not found");
    }

    /* 6. Check SFBClientInitialize if available */
    typedef int (*sfb_init_fn)(void);
    sfb_init_fn sfb_init = (sfb_init_fn)dlsym(handle, "SFBClientInitialize");
    if (sfb_init) {
        printf("\nSFBClientInitialize found in SimFramebuffer (Xcode 13 style)\n");
    } else {
        printf("\nSFBClientInitialize NOT in SimFramebuffer (Xcode 10 style - old API)\n");
    }

    /* 7. Check what exports are available */
    const char *symbols[] = {
        "simFramebufferMessageCreate",
        "simFramebufferMessageSendWithReply",
        "SFBConnectionCreate",
        "SFBConnectionConnect",
        "_SFBGetServerPort",
        "_SFBSetServerPort",
        NULL
    };

    printf("\n=== Symbol availability ===\n");
    for (int i = 0; symbols[i]; i++) {
        void *sym = dlsym(handle, symbols[i]);
        printf("  %-40s -> %s\n", symbols[i], sym ? "PRESENT" : "absent");
    }

    dlclose(handle);
    printf("\n=== Probe complete ===\n");
    return 0;
}
