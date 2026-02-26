# Agent A — launchd_sim Exploration

**Session ID**: `cmm2kr8hg5x20nq32pt5ca76g`
**Role**: Execution agent exploring Option 1 — making launchd_sim work under Rosetta 2
**Analyst**: The orchestrator session (not this agent) provides analysis, testing, and architectural direction.

## Mission

Get Apple's original `launchd_sim` from Xcode 8.3.3 running under Rosetta 2 on modern macOS. This is the iOS simulator's bootstrap server — it manages process launching, Mach service registration, and cross-process IPC for the simulated iOS environment.

If launchd_sim can boot, it gives us ALL the infrastructure we've been manually building:
- Proper Mach bootstrap subsets
- Pre-created service ports from LaunchDaemon plists
- Correct task port transfer between processes
- Native cross-process vm_read (which CARenderServer needs)

## Key Files

- `launchd_sim`: `/Applications/Xcode-8.3.3.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk/sbin/launchd_sim` (x86_64 + i386 universal)
- `LaunchDaemons`: `/Applications/Xcode-8.3.3.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk/System/Library/LaunchDaemons/`
- `CoreSimulatorBridge`: `/Applications/Xcode-8.3.3.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/Library/CoreSimulator/RuntimeOverlay/usr/libexec/CoreSimulatorBridge`
- Recovery plan: `/Users/ashhopkins/Projects/rosetta/.claude/plans/snug-purring-spark.md`

## What We Know

1. launchd_sim links only libSystem + libobjc (self-contained)
2. It uses `launch_legacy_*` APIs for service management
3. Running it directly crashes with SIGILL (EXC_BAD_INSTRUCTION) — a VM allocation failure during bootstrap subset creation
4. The old `simctl` (from Xcode 8.3.3) CAN run on modern macOS and sees both iOS 9.3 and iOS 10.3 runtimes
5. `simctl boot` crashes (exit 139 = SIGSEGV) — likely the CoreSimulator framework failing on modern macOS
6. The iOS 10.3 runtime has a device already created: `32F20F32-68BD-40B6-95D7-BEBE0DD2FDF4`

## Tasks

1. **Understand WHY launchd_sim crashes** — disassemble the crash location, understand the VM allocation failure
2. **Find what arguments/environment CoreSimulator passes to launchd_sim** — it's not designed to run standalone
3. **Try providing the correct environment** — CoreSimulator sets up a bootstrap subset BEFORE launching launchd_sim. Can we do that ourselves?
4. **If launchd_sim can't work directly, understand what it does** — map its boot sequence so we can replicate the essential parts in our broker

## Anti-Pivot Rules

- Only analyze the iOS 10.3 SDK binary (Xcode 8.3.3)
- Don't try to use modern CoreSimulator/SimFramebuffer
- Commit regularly
- Check in with the analyst session after each significant finding
- Escalate architectural concerns immediately

## Communication

- Sign off every message with: `[Agent A — cmm2kr8hg5x20nq32pt5ca76g]`
- Use agent teams for parallelizable sub-tasks
- The analyst cannot see your output directly — always send findings via happy mcp
