# Session 25 State — Shmem Client Pointer Is The Root Cause

## Date: 2026-02-26

## Session 25 Achievements

| Finding | Status | Evidence |
|---------|--------|----------|
| Full encoding gate chain traced | Done | commit_transaction → commit_root → commit_if_needed → commit_layer → _copyRenderLayer |
| Layer+0xa4=0, allContexts=0 | Identified & Fixed | App had no CAContext because CARenderServer lookup failed |
| Bootstrap port broken (MACH_SEND_INVALID_DEST) | Identified | App got 0xffffffff bootstrap port, couldn't reach broker |
| Bootstrap fixed → full pipeline connects | Verified | task_set_special_port after spawn works (when it works) |
| _copyRenderLayer called with layerFlags=0x19 | Confirmed | 19+ calls, bit 3 set, visual encoding runs |
| Client Render::Layer has RED at +0x10 | Confirmed | [1.0, 0.0, 0.0, 1.0] in CRL return value |
| Colors arrive at server in commit data | Confirmed | RED_FOUND in 40002 inline commits |
| Context identity: commit = render contexts | Confirmed | Server+0xa0 port matches commit local_port |
| Shmem header+0x1c has CLIENT pointer | ROOT CAUSE | 0x300007f892a not in server OOL range |
| Cross-process vm_read fails under Rosetta 2 | Confirmed | kr=1 (KERN_INVALID_ADDRESS) for ALL addresses |
| Shmem inline fix implemented | UNTESTED | Client appends cmd data to OOL, server patches offset |
| bootstrap_subset() dead on macOS 26 | Confirmed | Returns KERN_NOT_SUPPORTED (0x11) |

## The Complete Data Flow (What We Proved)

1. App sets layer.backgroundColor = red ✅
2. CATransaction flush fires ✅
3. _copyRenderLayer encodes Render::Layer with RED at +0x10 ✅
4. encode_set_object serializes to commit stream ✅
5. Mach message sent (40002 inline / 40003 OOL Shmem) ✅
6. Server receives message, data contains RED floats ✅
7. run_command_stream reads Shmem header ✅
8. **Shmem header+0x1c = CLIENT-SIDE POINTER** ✗
9. **Decoder reads from invalid address → zeros** ✗
10. Render::Layer gets bg=0,0,0,0 ✗
11. render_for_time composites empty layers ✗
12. 0 RGB pixels ✗

## The Fix (Implemented, Untested)

### Client side (replacement_mach_msg in bootstrap_fix.c):
- Detects 40003 commits with Shmem header containing 0x9C43 magic
- Reads cmd_ptr at header+0x1c (valid in OUR address space)
- Copies 137KB command data into the OOL buffer
- Stores OFFSET in header+0x1c instead of absolute pointer

### Server side (COMMIT_RECV in bootstrap_fix.c):
- Detects offset at header+0x1c (small value < ool_size)
- Translates offset → absolute server address: ool_base + offset
- Patches header+0x1c with translated pointer

## Remaining Blockers

### 1. Bootstrap Port Reliability (PRIMARY)
- `posix_spawnattr_setspecialport_np` fails ~80-100% for the app under Rosetta 2
- `task_for_pid` returns KERN_FAILURE (macOS security)
- `fork+exec` gives valid bootstrap BUT CARenderServer port arrives DEAD (MACH_PORT_DEAD)
- The broker uses MACH_MSG_TYPE_COPY_SEND (correct) but COMPLEX message port transfer from arm64 broker → Rosetta 2 app may be broken

### 2. Shmem Inline Fix Verification
- Cannot test until bootstrap port works reliably
- The fix is implemented in both client and server paths

### 3. Shmem Header Offset Ambiguity
- Agent A says ptr at +0x1c (from run_command_stream disassembly at QC+0xb32d6)
- Agent B's hex dump shows ptr-like value at +0x20
- May be byte alignment difference — needs verification with exact uint64 read at +0x1c

## Key Offsets (iOS 10.3 QuartzCore)

### Commit Encoding Chain
| Function | Offset |
|----------|--------|
| CA::Transaction::commit_transaction | +0x0abac4 |
| CA::Context::commit_transaction | +0x07dd6c |
| CA::Context::commit_root | +0x07dd40 |
| CA::Context::commit_layer | +0x07d4e0 |
| CA::Layer::commit_if_needed | +0x0ee980 |
| CA::Layer::copy_render_layer | +0x0fda5e |
| [CALayer _copyRenderLayer:layerFlags:commitFlags:] | +0x0fc5f7 |
| CA::Layer::set_commit_needed | +0x0eeb16 |
| CA::Layer::mark_context_changed | +0x0eeb8e |
| CA::Render::encode_set_slot | +0x1030b4 |

### Render::Layer Layout (0x98 bytes)
| Offset | Field | Size |
|--------|-------|------|
| +0x00 | vtable* | 8 |
| +0x08 | flags (bit 0x20000 = from client) | 4 |
| +0x10 | backgroundColor r,g (Vec4 float) | 8 |
| +0x18 | backgroundColor b,a | 8 |
| +0x20 | opacity (byte, 0-255) | 1 |
| +0x24 | flags bitfield | 8 |
| +0x40 | bounds origin | 16 |
| +0x50 | bounds size | 16 |
| +0x60 | contents* (texture/image) | 8 |
| +0x70 | sublayers* (TypedArray) | 8 |
| +0x78 | mask* | 8 |

### Shmem Commit Buffer Header
| Offset | Field |
|--------|-------|
| +0x14 | magic (0x9C42=inline, 0x9C43=OOL) |
| +0x18 | segment_count |
| +0x1c | command data pointer (8 bytes) — CLIENT VA for 0x9C43! |
| +0x24 | version (top byte = 0x01) |
| +0x28 | command data length |
| +0x2c | first segment descriptor |

### Key Layer Flags
| Flag on CA::Layer+0x4 | Meaning |
|------------------------|---------|
| bit 25 (0x2000000) | needs full commit → sets thread_flags bit 0x8 |
| bit 17 (0x20000) | frozen/detached — gates set_commit_needed |
| bit 18 (0x40000) | frozen/removed — gates set_commit_needed |

### layerFlags in _copyRenderLayer
| Bit | Value | Effect |
|-----|-------|--------|
| bit 3 (0x8) | Visual encoding | If NOT set, skips all 5.2KB of visual property encoding |
| bit 4 (0x10) | Parent changed | |
| bit 0 (0x1) | Sublayer changed | |

## Next Session Priority

1. **Fix bootstrap port reliability** — make CARenderServer port transfer work for every run
2. **Test Shmem inline fix** — verify pixels appear when bootstrap works
3. **If pixels appear**: remove diagnostics, clean up, move to Phase 2 (SpringBoard)

## Agent Sessions
- Agent A: `cmm2kr8hg5x20nq32pt5ca76g` — disassembly, Render::Layer layout, Shmem header analysis
- Agent B: `cmm2kyo475x3anq32ul3awimd` — runtime testing, bootstrap fix, Shmem inline fix implementation

## Commits This Session: 20 (ebbc1d3 to 55732cd)
