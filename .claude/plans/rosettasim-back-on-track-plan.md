# Problem statement
RosettaSim currently has the core architecture in place (ARM64 broker + x86_64 daemons/app via Rosetta), but we’re not reliably reaching a stable, correct UIKit runtime. The highest-impact blocker is that the app process can start with a dead bootstrap port (`MACH_PORT_DEAD` / `0xffffffff`), which breaks bootstrap lookups and cascades into hangs, incorrect UIScreen configuration, and fragile workarounds.
# Current state (assumptions to verify at start of work)
The system can spawn broker/backboardd/assertiond/SpringBoard/app and route many bootstrap/XPC flows through the broker. A broker-hosted watchdog responder exists (for `com.apple.backboard.watchdog`, MIG 0x1513 → reply 0x5b95b4 alive=1). There are still three product issues:
- App bootstrap port can be dead (`0xffffffff`), causing `MACH_SEND_INVALID_DEST` and early app failure.
- `UIScreen.scale` is not reliably set natively (workarounds exist but are not the end state).
- Scroll causes a SIGSEGV (likely missing service/state in CA/backboard/CARenderServer paths).
GPU rendering is not yet end-to-end.
# Guiding principles (enforced)
Protocol correctness over hacks.
- Prefer implementing the missing service/protocol contract over timeouts/guards/swizzles.
- Every change must have a measurable acceptance test and remove a specific failure signature.
- Avoid “papering over” (e.g., sync XPC timeouts, longjmp crash guards) except as a short-lived diagnostic tool with a removal plan.
# Definition of done (incremental)
We will treat “done” as milestones, not one giant finish line.
Milestone A: App bootstrap port is valid.
- App-side `task_get_special_port(TASK_BOOTSTRAP_PORT)` returns a live send right (not `0xffffffff`).
- No `MACH_SEND_INVALID_DEST` from bootstrap/XPC paths.
- Bridge constructor logs appear and the app reaches `didFinishLaunching` without deadlock.
Milestone B: Real display services path works.
- `BKSDisplayServicesStart` completes without assertion/exception.
- `UIScreen.scale` and `nativeScale` are correct without ObjC ivar forcing.
Milestone C: Basic interaction stability.
- Repeated scroll gestures do not crash for a sustained run.
Milestone D: GPU rendering progresses.
- CARenderServer commits produce advancing frames in the framebuffer path.
# Phase 0: Establish a repeatable baseline
Goal: make every run comparable and every failure attributable.
- Start from a known commit and clean working tree.
- Always run via the same entrypoint (e.g., `scripts/run_full.sh`) and capture logs to stable locations.
- For each iteration, record:
  - What changed (file + intent)
  - The removed failure signature (exact log line or crash)
  - The remaining failure signature (what still blocks the next milestone)
# Phase 1: Fix app bootstrap port propagation (highest priority)
Goal: eliminate `bootstrap_port = 0xffffffff` in the app.
What to do
1. Make `spawn_app()` fail-fast and observable.
- Check and log the return value from `posix_spawnattr_setspecialport_np(... TASK_BOOTSTRAP_PORT ...)` in `spawn_app()`.
- Treat failure as fatal for the run (log + exit) rather than continuing with a broken bootstrap.
2. Verify the right being passed.
- Confirm the broker has a send right for `g_broker_port` (it should) and that we are not accidentally handing the child a dead name.
- Ensure no code path deallocates/destroys the broker port or moves the receive right away.
3. Make app env match daemons (reduce variability).
- Populate `SIMULATOR_RUNTIME_VERSION` and `SIMULATOR_RUNTIME_BUILD_VERSION` for the app the same way we do for daemons.
4. Add a narrow diagnostic at the source.
- In `bootstrap_fix.dylib`, log `task_get_special_port` return code and the raw port value for the app process only.
Acceptance check
- In a clean run, the app-side bootstrap_fix logs show a live bootstrap port (not `0xffffffff`).
- No `MACH_SEND_INVALID_DEST` appears for bootstrap/XPC sends.
- Bridge constructor runs and emits its first log line.
Pivot inside Phase 1
If Phase 1 does not converge quickly:
- Build a tiny, isolated spawn test harness (outside the simulator stack) that uses `posix_spawnattr_setspecialport_np` to launch a trivial child and prints the child’s `TASK_BOOTSTRAP_PORT`. If this fails, the issue is API/usage-level, not RosettaSim-specific.
- Only if the spawn API is confirmed unreliable in this context do we consider deeper pivots (see Pivot section).
# Phase 2: Remove UIScreen/Display workarounds by making the real BKS path succeed
Goal: stop forcing screen scale and let BackBoardServices configure UIKit correctly.
What to do
- Once bootstrap is healthy, stop stubbing `BKSDisplayServicesStart` and let it run.
- Ensure `com.apple.backboard.display.services` is correctly registered/lookup-able and routable.
- Keep the watchdog responder in place if backboardd still doesn’t provide `com.apple.backboard.watchdog`.
- If backboardd does not implement the needed display.services MIG calls (or they don’t reach it), implement the minimal broker-hosted subset required for:
  - “main screen info” queries that ultimately set UIScreen’s internal scale
Acceptance check
- No “backboardd isn’t running” assertion/exception.
- `UIScreen.scale == 2.0` (and `nativeScale` aligns) without runtime ivar patches.
# Phase 3: Fix the scroll crash (SIGSEGV)
Goal: make basic UIKit interaction stable.
What to do
- Reproduce deterministically, capture crash signature and stack.
- Identify the missing service/state CA is touching during gesture-driven commits.
- Implement that missing contract (or route it correctly through broker) rather than adding guards.
Acceptance check
- Multiple scroll interactions over a sustained interval without crash.
# Phase 4: GPU rendering path (after stability prerequisites)
Goal: make CARenderServer commits land in the framebuffer path.
What to do
- Re-validate CARenderServer control/data/callback channels and ensure the compositor output is wired to the shared framebuffer.
- Address the known commit/context attachment gating issues only after the lifecycle and display services are correct.
Acceptance check
- GPU-mode frame counter advances and visible output matches app UI.
# Pivot criteria (when to consider changing strategy)
We should not pivot just because something is hard; we pivot when progress stops for a well-defined reason.
Pivot triggers
- If we cannot make the app’s bootstrap port live after a focused, time-boxed Phase 1 plus an isolated spawn harness proving our approach is correct.
- If the display.services contract expands beyond a small, well-scoped subset and starts turning into “reimplement backboardd” work.
Pivot options
- Integrate more of Apple’s simulator host stack (use existing CoreSimulator services where possible) and concentrate RosettaSim on protocol translation rather than replacement.
- As a last resort, constrain scope to a stable “CPU capture mode” only if it is actually stable and interactive (no crashes on common gestures), but this is not an acceptable end state unless it meets the project’s reliability goals.
# Running this via a Happy session (execution loop)
When you create the new Happy session and task an agent:
- Require the agent to work milestone-by-milestone with evidence.
- Cadence for check-ins: after every meaningful run and at least every 30–60 minutes.
- My monitoring loop: use `happy_get_messages` to pull new messages, verify they include (1) change made, (2) evidence, (3) next blocking signature, and respond with course corrections until Milestone A–C are complete.
