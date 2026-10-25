# Core Lifecycle

24 October 2026. This follow-up concerns Xenia core ownership during frontend
termination. MoltenVK, RetroArch's executable, the rendering handoff and audio
settings are unchanged.

## Two Distinct Exit Paths

The earlier 20-minute MoltenVK observation completed Xenia teardown after
`CLOSE_CONTENT`, but a single UDP `QUIT` did not terminate the frontend. The
isolated configuration omitted `confirm_quit`, whose default requires another
press. This differs from the user's active configuration, which explicitly sets
`confirm_quit = "false"`.

A follow-up with the old installed core confirms that the frontend remains
responsive: `VERSION` replies before and after content close and after the first
`QUIT`. Two additional adjacent quit requests terminate it with exit 0. A
separate controlled run with `confirm_quit = "false"` terminates on one `QUIT`,
exit 0 in 35.743 seconds. The earlier raw result remains unchanged; it does not
establish a teardown deadlock.

Native application Quit is different. Selecting **RetroArch > Quit RetroArch**
invokes the same `terminate:` action as Cmd+Q. The old core aborts with SIGABRT
(exit -6), including with quit confirmation disabled. The retained crash stack
runs from `-[NSApplication terminate:]` through `exit` and
`__cxa_finalize_ranges` to `std::terminate`, without the normal core unload
callbacks. Another thread remains in `pause_watchdog_start`.

The core owns a global `std::thread` for that watchdog. Its default destructor
cannot destroy a joinable thread. It is declared after the global emulator
owner, so ordinary reverse global destruction does not stop the emulator and
watchdog first. Explicit Libretro unload had already handled this correctly;
the missing path is native process termination that bypasses those callbacks.

## Core Change

`libretro/libretro.cpp` registers a function-local `EmulatorLifetime` object
after successful emulator setup and before starting the pause watchdog. Its
destructor calls the existing `xenia_stop_emulator` path before the core's older
global objects are destroyed:

1. Notify, stop and join the pause watchdog.
2. Resume a paused guest for orderly shutdown.
3. Call `StopTitleThreads` and `Shutdown` in the existing Xenia order.
4. Release the emulator and clear the core's borrowed subsystem pointers.

Normal reset and content unload retain that same existing stop path. When an
unload has already stopped the emulator, the lifetime destructor has nothing
left to stop. It does not call frontend environment callbacks, destroy the
frontend context, add GPU waits, or replace RetroArch's own shutdown routine.
No process-exit API is added to the core.

## Validation

All runs use Daytona USA's existing read-only `.xcp` package on Apple M4,
RetroArch 1.22.2 `fce35fc7`, and the already installed corrected MoltenVK 1.4.2
framework. Candidate tests use an ARM64 Release/LTO core, ad hoc signed and
verified with `codesign --verify --strict`. Test configuration, game support
files, saves, logs and cache are isolated from the user's active setup.

- Baseline core SHA-256: `f558c7ade336f05cdf25744af6cfd7ef8b6626c8cf21ad1d28a09f80142460b8`.
- Corrected core SHA-256: `b9d85483a2b24968e8908dcb5b23b4c276dce2a390081edd451eed765be69300`.
- Unchanged driver SHA-256: `6c511b765b68df9043b05fe6cdaacb78ce256115aab887a2b9d9c582143aa22b`.

| Run | Result |
| --- | --- |
| Baseline native Quit, default confirmation | SIGABRT (-6), 31.244 s. No orderly Xenia teardown. |
| Baseline native Quit, confirmation disabled | SIGABRT (-6), 30.854 s. Diagnostic destructor probe did not capture useful callbacks; no destructor attribution is based on it. |
| Baseline close then one QUIT, confirmation disabled | Exit 0, 35.743 s; Xenia teardown complete and frontend responsive after close. |
| Corrected native Quit, confirmation disabled | Exit 0, 34.340 s; `StopTitleThreads: done` and `Emulator::Shutdown: teardown complete`. |
| Corrected two resets, content close and QUIT | Exit 0, 65.728 s; two `reset: relaunching` messages, three completed title stops and return to the dummy menu. |
| Installed corrected core, Cmd+Q | Exit 0, 23.732 s; completed guest teardown; no forced termination. |

The initial candidate reset attempt left `confirm_reset` at its default and
therefore did not invoke `retro_reset`: its exit-0 result establishes content
close/quit only. The actual reset regression disables `confirm_reset` in the
isolated configuration and requires both relaunch messages in RetroArch's log.
The user's `confirm_reset = "true"` remains unchanged.

Evidence: `.local/quit-investigation/` contains the baseline and candidate
results, console/RetroArch/Xenia logs, build log, exact source delta, original
rolling artifact and installation verification. Native menu actions were
performed through CUA; owning runner exit codes corroborate application exit.
The older crash is retained at
`.local/mvk-main-path/RetroArch-2026-10-24-082708.ips`.

This is a targeted lifecycle regression, not a new performance measurement or
interactive gameplay test. Previous performance and MoltenVK evidence retains
its original revisions and scope. Other operating systems and arbitrary hosts
that violate the frontend lifecycle contract are not runtime-validated here.
