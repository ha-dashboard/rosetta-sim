/*
 * sim_scale_fix.c — DYLD interpose to fix BSMainScreenScale in legacy iOS simulators
 *
 * Problem: backboardd calls BSMainScreenScale() which returns ≤0 on our system,
 * causing it to fall back to scale=1.0. This breaks the display pipeline —
 * native_scale stays at 0, Display::set_size produces empty clip bounds,
 * and the renderer only fills a fraction of the pixel buffer.
 *
 * Fix: Interpose BSMainScreenScale to return the correct scale (default 2.0).
 * Injected into sim processes via SIMCTL_CHILD_DYLD_INSERT_LIBRARIES.
 *
 * Build (x86_64 — runs inside Rosetta sim):
 *   /usr/bin/cc -arch x86_64 -shared -o sim_scale_fix.dylib sim_scale_fix.c
 *
 * Usage:
 *   export SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=/path/to/sim_scale_fix.dylib
 *   export SIMCTL_CHILD_ROSETTA_SCREEN_SCALE=2
 *   xcrun simctl boot <UDID>
 */

#include <stdio.h>
#include <stdlib.h>

/* Replacement: return scale from env or default 2.0 */
double replacement_BSMainScreenScale(void) {
    const char *s = getenv("ROSETTA_SCREEN_SCALE");
    double scale = s ? atof(s) : 2.0;
    static int logged = 0;
    if (!logged) {
        fprintf(stderr, "[scale_fix] BSMainScreenScale -> %.1f\n", scale);
        logged = 1;
    }
    return scale;
}

/* Declare original symbol */
extern double BSMainScreenScale(void);

/* DYLD interpose directive */
__attribute__((used, section("__DATA,__interpose")))
static struct { void *replacement; void *original; } interpose[] = {
    { (void *)replacement_BSMainScreenScale, (void *)BSMainScreenScale },
};
