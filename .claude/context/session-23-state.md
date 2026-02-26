# Session 23 State — GPU Pipeline Investigation

## Date: 2026-02-25/26

## Summary
Session 22-23 investigated the GPU rendering pipeline end-to-end. Every component works individually but the compositor produces 0 RGB pixels (only alpha=255 clear color).

## What Works (confirmed)
- **Render pipeline**: render_for_time at qc_base+0x1287ea fires 200+ times on `com.apple.coreanimation.render-server` thread
- **Commit encoding**: App sends 23 commits (296-4080 bytes for 40002, 9-34KB OOL for 40003) with correct magic 0x9C42/0x9C43
- **Commit routing**: All commits go to per-context ports (ON_CONTEXT), not service port
- **Pixel transport**: Test gradient displayed in host app at 30fps via shared framebuffer
- **PurpleFB protocol**: msg_id 3/4 reply matches iOS 10.3 PurpleDisplay::map_surface exactly
- **Post-commit render trigger**: Fires render_for_time after each commit on the correct thread (bootstrap_fix.c)
- **Server context list**: 6 contexts in Server+0x68, 3 with 375x667 root layers + sublayers
- **Display surface**: MemorySurface at Display+0x138, data ptr shared with SWContext (same buffer 0x1196bc000)

## What's Broken
- **render_for_time produces only clear color** (alpha=255, 0 RGB) despite 6 contexts with root layers
- **Display's context list (display+0x68) is always NULL** — but Agent A proved render_display reads from Server+0x68 (same list as add_context)
- **render_display is an OBSERVER callback** (notification 0xd), NOT called directly by render_for_time
- **render_for_time dispatches through Display vtable** — the exact vtable calls and their context filtering logic is the remaining unknown

## Key Fixes Applied (in code)
1. **Display+0x98 = 60.0** (refresh rate, in purple_fb_server.c GPU_INJECT)
2. **Per-client port preserved** (removed Session 21 override in rosettasim_bridge.m)
3. **Post-commit render trigger** (in bootstrap_fix.c replacement_mach_msg)
4. **Re-entrancy guard** for render trigger (prevents recursive mach_msg)

## Key Discoveries
- **MIG subsystem mapping**: 40000-40199 = render protocol, 40200-40399 = CARenderServices, 40400-40407 = CARenderClient (silently dropped server-side)
- **CA::Context ownership**: Layer+0xa4 = owning context local_id; commit_transaction checks match
- **Display name**: Server+0x60 = 'LCD', Display ID at Display+0x10 = 1
- **context_created gates**: bit 17 (attached), bit 22 (displayable), displayId match, displayName match, default display flag (display+0xF9 bit 6)
- **context_created DEADLOCKS** when called from server thread (sends MIG 40400 to self)
- **launchd_sim**: Fully mapped boot sequence; crashes with kernel VM allocation failure (not fixable from userspace)
- **vm_read**: WORKS between Rosetta 2 processes (confirmed with diagnostic test)
- **Backing store transfer**: CA uses task_port remap (flag 0x40) or memory entry port for Shmem data

## Remaining Investigation for Next Session
1. **Trace render_for_time's Display vtable dispatch** — what do vtable[17] (0x88/8) and vtable[9] (0x48/8) actually do? Do they filter/skip contexts?
2. **Does the display "needs update" check block rendering?** — Display vtable[17] at 0x128b5e might return false
3. **Try calling render_display directly** with correct parameters (Server ptr, render_info with name='LCD') from a non-server thread
4. **Check if contexts need display=1 flag** at Context+0x170 (set by set_display_info) for render_for_time to include them

## Agent Sessions
- **Agent A**: `cmm2kr8hg5x20nq32pt5ca76g` — disassembly specialist, traced MIG subsystem, commit flow, context ownership, display binding
- **Agent B**: `cmm2kyo475x3anq32ul3awimd` — runtime testing, built post-commit trigger, verified commit flow, tested display binding approaches

## Commits This Session
- f63ac05: session 22 GPU investigation — render pipeline works, commit path broken
- e79c42b: launchd_sim launcher with bootstrap proxy
- d892b4c: post-commit render trigger in replacement_mach_msg
- c78e0af: re-entrancy guard for post-commit render
- e209171: server port vs context port diagnostic
- 519ed63: session 23 GPU pipeline investigation
- 8d9f0bc: commit flow confirmed, display binding WIP
- 4f9afda: CA_CFDictionaryGetInt returns 1 but display+0x68 stays NULL
- 4abc03a: Server+0x60 name is 'LCD', all context_created gates pass
- 3b88b3c: render path and display binding disassembly
- 6359018: clean baseline — strip binding code, verify commit flow

## Binary Paths (ALWAYS use iOS 10.3)
- QuartzCore: `/Applications/Xcode-8.3.3.app/.../iPhoneSimulator.sdk/System/Library/Frameworks/QuartzCore.framework/QuartzCore`
- backboardd: `/Applications/Xcode-8.3.3.app/.../iPhoneSimulator.sdk/usr/libexec/backboardd`
