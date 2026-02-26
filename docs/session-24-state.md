# Session 24 State Document

## Agent B — cmm2kyo475x3anq32ul3awimd

## Summary

Session 24 conducted comprehensive investigation of why render_for_time produces 0 RGB pixels despite commits flowing correctly from app to server.

## Key Findings

### What WORKS
- Commits (40002/40003) flow from app to server with correct magic (0x9C42/0x9C43)
- OOL commit data (13-34KB) arrives correctly via Mach message passing
- Context version counter at ctx+0x08 increments (commits ARE processed)
- Renderer at Server+0xc0 is valid at render time
- can_update gate is OPEN (Display+0xfa = 0x00)
- SWContext and pixel buffer exist (stride=3000, alpha=255)
- attach_contexts succeeds from background thread (no deadlock)
- kick_server, set_next_update, invalidate all callable without crash

### What DOESN'T work
- **0/2000 non-zero RGB pixels** on every check (renders 1-200+)
- **Root layer raw data never changes** between renders despite commits
- **Display context list** contains sentinel 0xFFFFFFFFFFFFFFFF (no valid contexts)
- **flush_shmem only fires 4 times** (all during init), never after commits
- **Sublayer objects** are code-pointer tables, not visual Render::Layer objects
- **CAEncodeBackingStores=1** had no effect on commit sizes
- **backgroundColor set via BG_FORCE** produced larger commit (728 bytes) but still 0 pixels

### Experiments Tried
1. **kick_server (msg_id 40001)**: Goes to render-server thread, not PurpleMain
2. **set_next_update via vtable[3]**: Succeeds, no pixel output
3. **Server::invalidate via dlsym**: Symbol not exported
4. **Display early exit flags (+0x28/+0x30)**: Not blocking
5. **Context injection into display list**: 0 pixels even with real context pointers
6. **Bit 0x20000 clearing + attach_contexts**: Succeeds, no new display contexts
7. **CAEncodeBackingStores=1**: No effect on commit sizes or pixels
8. **Port zeroing removal at impl+0x98**: No effect (save/restore was fast enough)
9. **BG_FORCE backgroundColor**: Set window=RED rootVC.view=BLUE, flushed — no pixels

### PUI Image Loading
- ProgressUI.framework loads images via `[NSBundle bundleForClass:].resourcePath`
- Pattern: `resourcePath/apple-logo.png` or `apple-logo~iphone.png`
- "No image found for apple-logo" = missing boot screen assets
- Framework has no bundled images (SDK structure is virtual on modern macOS)

## Root Cause Analysis

The commit data arrives at the server but does NOT modify the server-side Render::Layer properties. The context version counter increments (proving commits are processed), but the layer tree structure and properties remain static.

Possible explanations:
1. **run_command_stream decodes but doesn't execute**: The OOL commit data may be decoded into command objects but those commands are never applied to layers
2. **Commands target wrong layers**: The decoded commands may reference layer IDs that don't match the server's layer objects
3. **Missing Shmem mapping**: Commands may reference shared memory regions (for backing stores) that aren't mapped in the server process
4. **Commit data is metadata-only**: The 13-34KB OOL data may be just property/structure updates that don't include visual content (backgroundColor, contents, etc.)

## Commits Made
- f748622: kick_server, can_update, dirty flag experiments
- 07e43cd: Shmem not mapped (corrected later — OOL IS accessible)
- fc1d53d: CAEncodeBackingStores=1, attach_contexts bg thread
- 9db6030: Remove port zeroing, BG_FORCE test, pixel check extensions

## Next Steps (Recommendations)
1. **Verify commit decoding**: Hook run_command_stream to confirm commands are decoded AND applied
2. **Check if backgroundColor reaches server layer**: Scan ALL layer offsets (not just potential_colors) after BG_FORCE commit
3. **Fix PUI images**: Create apple-logo.png in the correct resource path
4. **Consider CPU renderInContext diagnostic**: Temporarily render to a local CGContext to verify the app's layer tree HAS content
