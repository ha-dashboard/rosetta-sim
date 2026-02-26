# Session 24 State — Commit Encoding Is The Last Missing Piece

## Date: 2026-02-26

## What Works (proven end-to-end)

| Component | Status | Evidence |
|-----------|--------|----------|
| Render trigger | ✅ 200+ render_for_time/sec | Post-commit trigger on render-server thread |
| Commit routing | ✅ Per-context ports | COMMIT_PORT_FINAL: all ON_CONTEXT |
| Context lookup | ✅ context_by_server_port finds context | Confirmed via dispatch log |
| Commit decode | ✅ decode_commands runs with valid context | Confirmed via version increments |
| Display surface | ✅ Readable, same buffer as SWContext | MemorySurface+0x40 = SWContext dest |
| Pixel transport | ✅ Test gradient at 30fps | Confirmed in host app |
| SW Renderer | ✅ Clears buffer (alpha=255) | Lazy-creates at Server+0xc0 |
| PurpleFB protocol | ✅ Correct for iOS 10.3 | map_surface reply verified |
| All APP ports | ✅ Non-zero, valid send rights | 0x8103, 0x6603, 0x1603 |
| Port override | ✅ Removed (Session 23) | Line 7231 confirmed |

## What's Broken

**Commit encoding produces ONLY metadata opcodes (0x08/0x09/0x0a). NO visual property updates (0x02/0x03).**

- `_copyRenderLayer:layerFlags:commitFlags:` never encodes backgroundColor, contents, or other visual properties
- Setting `layer.backgroundColor = red` on client OR server side doesn't produce an update_layer (0x03) opcode in commits
- Result: server's Render::Layer objects have correct structure (bounds, sublayers) but no visual content (no Pattern, no backing store)

## Why 0 Pixels (Complete Chain)

1. Client sets visual properties on CALayer ✓
2. CATransaction flush fires ✓
3. Commit encoded — but ONLY metadata opcodes (0x08=set_colorspace, 0x09/0x0a=order_relative) ✗
4. Server receives commit and decodes ✓
5. decode_commands processes metadata but no visual updates ✗
6. Render::Layer has bounds but no backgroundColor, no contents ✗
7. render_for_time composites layer tree — nothing to draw ✗
8. finish_update sees empty dirty rect → skips flush_shmem ✗
9. Pixel buffer stays at clear color (alpha=255, 0 RGB) ✗

## Gates Identified and Cleared

| Gate | Status | Fix |
|------|--------|-----|
| Display+0x98 refresh rate = 0 | Fixed | Set to 60.0 |
| Session 21 port override | Fixed | Removed |
| Context+0x98 = 0 | Not the issue | All ports valid |
| can_update returns false | Not the issue | Returns true |
| is_enabled/is_ready | Not the issue | Both true |
| Display context list empty | Red herring | render_display uses Server+0x68 |
| MIG 40400 display binding | Red herring | Silently dropped, not used for binding |
| Dirty flags (bit 0x200000) | Red herring | Not a gate, all contexts always added to Update |
| Shape invalidation (+0x150) | Downstream symptom | NULLing helps but no content to draw anyway |
| CAEncodeBackingStores | No effect | Layers have nil contents locally too |

## Key Disassembly Offsets (iOS 10.3 QuartzCore, QC base)

| Function | Offset |
|----------|--------|
| render_for_time | +0x1287ea |
| render_display (observer) | +0x12672e |
| render_update | +0x12993a |
| commit_transaction | +0x7dd6c |
| context_created | +0x126158 |
| attach_contexts | +0x1286de |
| add_observers | +0x12a11e |
| context_changed | +0x12a518 |
| invalidate_context | +0x12a17a |
| set_next_update | +0x129764 |
| kick_server | +0xb2cde |
| Shmem::decode | +0x1efc0 |
| SWContext::set_destination | +0xa5b86 |
| PurpleDisplay::map_surface | +0xc9418 |
| PurpleDisplay::flush_shmem | +0xc9bb6 |
| PurpleDisplay::can_update | +0xc9d9a |
| PurpleDisplay::finish_update | +0xc9c38 |
| run_command_stream | +0xb3278 |
| decode_commands | +0x103797 |
| _server_port (static) | +0x1bfb78 |
| _server_port_set | +0x1bfb7c |
| DisplayLink::_list | +0x1bf9a0 |
| DisplayLink::_lock | +0x1bf998 |

## Decode Opcode Table

| Byte | Opcode | Effect |
|------|--------|--------|
| 0x01 | delete_object | Removes object |
| 0x02 | set_object | Creates/replaces layer/object ← VISUAL |
| 0x03 | update_layer | Modifies layer properties ← VISUAL |
| 0x04 | add_animation | |
| 0x05 | remove_all_animations | |
| 0x06 | set_cfobject | |
| 0x07 | set_layer_id | Sets root layer |
| 0x08 | set_colorspace | Metadata |
| 0x09 | order_relative(false) | Metadata |
| 0x0a | order_relative(true) | Metadata |
| 0x0b | order_level | Metadata |

## Next Session Priority

**WHY doesn't _copyRenderLayer encode visual properties?**

1. Is the CALayer's "modified" property tracking working?
2. Does `commit_transaction` call `_copyRenderLayer` at all for our contexts?
3. Is there a flag that gates visual property encoding?
4. Does the context need to be in a specific state for visual encoding?

The PUI image fix (ProgressUI) is also pending — images exist at SDK path but NSBundle resolves to host path.

## Agent Sessions
- Agent A: `cmm2kr8hg5x20nq32pt5ca76g` — disassembly, full opcode table, complete dispatch chain
- Agent B: `cmm2kyo475x3anq32ul3awimd` — runtime testing, commit verification, gate checks

## Key Files Modified
- `src/bridge/purple_fb_server.c` — render trigger, diagnostics
- `src/bridge/rosettasim_bridge.m` — port override removed, display pipeline
- `src/launcher/bootstrap_fix.c` — post-commit render trigger, commit logging
