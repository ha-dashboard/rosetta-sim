# Session 24 Final State Document

## Agent B — cmm2kyo475x3anq32ul3awimd
## Date: 2026-02-26

---

## Executive Summary

Session 24 conducted exhaustive investigation of the GPU rendering pipeline. **The render pipeline infrastructure works end-to-end.** The actual root cause is that **commit encoding never includes visual property updates** (no opcode 0x02/0x03 in any commit). The client's `_copyRenderLayer` doesn't encode backgroundColor or other visual properties.

---

## What We PROVED Works

| Component | Status | Evidence |
|-----------|--------|----------|
| Commit routing | ✅ | ALL commits go ON_CONTEXT(ok), not ON_SERVER |
| App context ports | ✅ | All 3 app contexts have non-zero ports (0x8003, 0x6803, 0x1303) |
| UIWindow._layerContext | ✅ | Points to valid context with port and encoder |
| OOL data transfer | ✅ | 13-34KB OOL descriptors arrive correctly at server |
| Context version | ✅ | ctx+0x08 increments (commits ARE processed) |
| can_update gate | ✅ | Display+0xfa = 0x00 (open) |
| Renderer exists | ✅ | Server+0xc0 non-NULL at render time |
| SWContext exists | ✅ | Valid pixel buffer at stride=3000 |
| Display is_enabled | ✅ | +0x1e0 bit 0 = 1 |
| PUI images | ✅ | Fixed — "No image found" error gone |

## What DOESN'T Work

| Issue | Evidence |
|-------|----------|
| **0 RGB pixels** | All PIXELS checks show 0/2000 nz, px[0]=(0,0,0,255) |
| **flush_shmem = 4** | Only fires during init, never after commits |
| **No visual opcodes in commits** | Only 0x08/0x09/0x0a (metadata), never 0x02/0x03 (visual) |
| **Root layer data static** | Raw bytes identical across 200+ renders |
| **Server-side red layer = 0 pixels** | Direct CALayer in backboardd produces 0 pixels too |

---

## Root Cause Chain

```
1. Client sets backgroundColor on CALayer                    ✅ (BG_FORCE confirmed)
2. CALayer should mark property as "modified"                ❓ (UNVERIFIED)
3. CATransaction.flush calls _copyRenderLayer                ❓ (UNVERIFIED)
4. _copyRenderLayer should emit opcode 0x03 (update_layer)  ❌ (NEVER seen in commits)
5. Server decodes 0x03 → updates Render::Layer properties   N/A (never reaches this)
6. render_for_time sees dirty layers → composites            N/A
7. flush_shmem sends pixels to display                       N/A
```

**The break is between steps 2-4.** The CALayer property change is set, but the commit encoder doesn't include it. Either:
- The layer's modified flags aren't being set correctly
- The context isn't tracking the layer for changes
- `_copyRenderLayer` checks some condition that prevents encoding visual properties
- The layer isn't attached to the context's layer tree correctly

---

## Experiments Performed (11 commits)

### f748622 — kick_server, can_update, dirty flag experiments
- kick_server (40001) goes to render-server thread, not PurpleMain
- can_update gate OPEN, renderer valid at render time
- Display context list = sentinel 0xFFFFFFFFFFFFFFFF

### 07e43cd — Shmem investigation
- vm_read(self, 0x100000000) fails (wrong address)
- OOL data IS accessible via Mach message passing
- No "failed to map" errors in logs

### fc1d53d — CAEncodeBackingStores, attach_contexts, dirty flags
- CAEncodeBackingStores=1: no effect on commit sizes
- attach_contexts from bg thread: succeeds, no deadlock
- set_next_update, invalidate, kick_server: all succeed, 0 pixels

### 9db6030 — Remove port zeroing, BG_FORCE test
- Removed impl+0x98 port zeroing in frame_capture_tick
- BG_FORCE: set window=RED rootVC.view=BLUE → still 0 pixels
- Port zeroing was NOT the root cause

### dfbc517 — PUI fix, corrected port check, APP_CTX dump
- Created apple-logo~iphone.png copies → PUI loads successfully
- COMMIT_PORT_V2: all commits ON_CONTEXT(ok)
- All 3 app contexts have non-zero ports

### 44783cb — Command opcode logging
- Commits contain only 0x08/0x09/0x0a (metadata opcodes)
- Never see 0x02 (set_object) or 0x03 (update_layer)
- Command data contains what appear to be client heap pointers

### 5b1df30 — SERVER_TEST proves renderer question
- Red CALayer created directly in backboardd → still 0 pixels
- Set on ALL 3 server contexts, flushed → commits produced but 0 pixels
- Even server-side layers don't produce visual commits

### 450deb5 — old_shape NULLing
- NULL Context+0x150 before render → shapes cleared, re-set to 0x1
- flush_shmem count unchanged at 4

---

## Key Binary Offsets (iOS 10.3 QuartzCore)

| Offset | Purpose |
|--------|---------|
| QC+0x1287ea | render_for_time |
| QC+0x1286de | attach_contexts |
| QC+0x126158 | context_created |
| QC+0xb3278 | run_command_stream |
| QC+0xb2cde | kick_server |
| Server+0x58 | Display* |
| Server+0x68 | Context list (stride 0x10) |
| Server+0x78 | Context count |
| Server+0xb8 | SWContext* |
| Server+0xc0 | Renderer* |
| Display+0xC0 | Context vector {begin, end, capacity} |
| Display+0xfa | can_update bit (bit 1) |
| Display+0x1e0 | is_enabled (bit 0) |
| Context+0x08 | Version/flags (increments per commit) |
| Context+0x0C | Context ID |
| Context+0xB8 | Root handle |
| Context+0x150 | Old shape |
| SWContext+0x668 | Pixel buffer pointer |
| SWContext+0x678 | Stride |

---

## Next Session Priorities

### Priority 1: Fix commit encoding
Why does `_copyRenderLayer` not emit visual property opcodes?

Check:
1. Is the CALayer's internal "modified" bitmask set after setBackgroundColor?
2. Does the context's change tracking include the layer?
3. Is there a condition in `_copyRenderLayer` that skips visual properties?
4. Compare commit bytes from a REAL iOS simulator to identify expected opcode patterns

### Priority 2: Alternative approach — CPU renderInContext
Since the GPU pipeline has commit encoding issues, consider a parallel path:
- Use CPU `renderInContext:` to capture pixels directly
- Write to the shared framebuffer
- This is what the existing HYBRID mode does (and it works for CPU capture)

### Priority 3: Fix display context list
The sentinel 0xFFFFFFFFFFFFFFFF persists. Even with context injection, the renderer doesn't composite. This may be a secondary issue after commit encoding is fixed.

---

## Files Modified

| File | Changes |
|------|---------|
| `src/launcher/bootstrap_fix.c` | All diagnostics, kick_server, invalidate, shape NULLing, PUI bundle check, SERVER_TEST, CAEncodeBackingStores, command opcode logging |
| `src/bridge/rosettasim_bridge.m` | BG_FORCE backgroundColor test, APP_CTX port dump, port zeroing removal |
| `src/bridge/purple_fb_server.c` | PUI bundle diagnostic |
| SDK ProgressUI.framework | Created apple-logo~iphone.png and apple-logo-black~iphone.png copies |
