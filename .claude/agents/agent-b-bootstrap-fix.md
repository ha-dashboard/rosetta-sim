# Agent B — Bootstrap Subset Fix

**Session ID**: `cmm15q4dk568unq320bqntw0z`
**Role**: Execution agent implementing Option 2 — proper bootstrap subset in our broker
**Analyst**: The orchestrator session (not this agent) provides analysis, testing, and architectural direction.

## Mission

Fix the broker's bootstrap infrastructure so that cross-process Mach IPC works correctly — specifically, so that CARenderServer's `vm_read` of the app's commit buffer succeeds. The current broker creates an ad-hoc bootstrap environment that breaks COMPLEX message port/memory descriptor transfer.

## The Problem

CARenderServer (in backboardd) needs to read 72KB of serialized layer tree data from the app's memory at address 0x100000000. It does this via `vm_read(client_task_port, 0x100000000, length)`. The client's task port is sent during RegisterClient (MIG 40203) as a COMPLEX message port descriptor.

In our current setup, vm_read fails for ALL ports — the task port either doesn't transfer correctly or cross-process vm_read doesn't work through our broker's bootstrap infrastructure.

The real iOS simulator uses `launchd_sim` which creates a proper Mach bootstrap SUBSET. This ensures:
- Port rights transfer correctly in COMPLEX MIG messages
- Task ports are accessible across processes
- vm_read between processes in the subset works

## Key Files

- Broker: `/Users/ashhopkins/Projects/rosetta/src/bridge/rosettasim_broker.c`
- Bootstrap fix: `/Users/ashhopkins/Projects/rosetta/src/launcher/bootstrap_fix.c`
- PurpleFBServer: `/Users/ashhopkins/Projects/rosetta/src/bridge/purple_fb_server.c`
- Bridge: `/Users/ashhopkins/Projects/rosetta/src/bridge/rosettasim_bridge.m`
- Recovery plan: `/Users/ashhopkins/Projects/rosetta/.claude/plans/snug-purring-spark.md`

## What We Know

1. The broker already imports `bootstrap_subset()` but may not use it correctly
2. `launchd_sim` uses `launch_legacy_create_server` and `launch_legacy_subset` to create bootstrap hierarchies
3. Our broker creates ports on-demand (pfb_bootstrap_check_in/look_up interpositions) instead of pre-creating them
4. The backboardd LaunchDaemon plist lists ALL required MachServices (CARenderServer, PurpleSystemEventPort, etc.)
5. CA MIG messages DO flow between app and backboardd (20+ received)
6. The commit notification (msg_id 40206) contains client address + length but the server can't vm_read it
7. The app's task port IS sent in RegisterClient as descriptor[0] but arrives broken in the server

## Tasks

1. **Quick diagnostic: does vm_read work AT ALL between two Rosetta 2 processes?** Write a simple test — two processes, one does task_for_pid on the other, tries vm_read. This tells us if the issue is Rosetta 2 fundamental or our bootstrap setup.

2. **If vm_read works (bootstrap issue):** Add proper `bootstrap_subset()` creation to the broker. Create the subset before spawning backboardd. All child processes inherit the subset's bootstrap port. Pre-create service ports from the LaunchDaemon plists.

3. **If vm_read doesn't work under Rosetta 2 (fundamental):** Create a shared memory region (mach_make_memory_entry + vm_map) that replaces the task_port+vm_read model. Map the CA commit buffer at 0x100000000 in both processes using shared memory.

4. **Verify the fix**: After fixing, check that the server's Render::Context root_layer has sublayers and contents. Then trigger render_for_time and check for non-zero RGB pixels.

## Anti-Pivot Rules

- Only analyze the iOS 10.3 SDK binary (Xcode 8.3.3)
- Don't switch to CPU renderInContext
- Commit regularly
- Check in with the analyst session after each significant finding
- Escalate architectural concerns immediately

## Communication

- Sign off every message with: `[Agent B — cmm15q4dk568unq320bqntw0z]`
- Use agent teams for parallelizable sub-tasks
- The analyst cannot see your output directly — always send findings via happy mcp
