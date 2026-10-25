# Shared Queue Main Path Validation

Updated: 24 October 2026.

Historical shared-queue audit. The subsequent
[Independent Queue Correction](INDEPENDENT_QUEUE_FIX.md) resumes the broader
queue work and supersedes the deferred scope below; these earlier results remain valid.

## Scope And Budget

This follow-up covers the shared Vulkan queue used by the installed Xenia
Libretro core. Independent-queue drawable publication and event-token fixes
remain deferred. Earlier results are preserved. No driver or core behavior
changed in this activity.

Weekly account usage started at 28%; the agreed stop threshold is 38%, with
a new decision required before exceeding it. The post-test reading is 29%.
Readings include other chats and have percentage-point granularity.
Model/effort remains Sol / High.

## Native Visibility Probe

The maintained harness adds `--hide-restore` and `--frames-per-cycle=N`.
Each of four swapchains hides its window at frame 20 and restores it after
250 ms from the event pump, including during fence waits. Actual `isVisible`
state and presentations issued while hidden are checked. Restoration uses
wall time rather than waiting for rendering to advance.

| Driver | Submission | Frames / Readbacks | Result |
| --- | --- | --- | --- |
| Patched 1.4.2, counter-only | Asynchronous | 240 / 244 | Four restores, 69 hidden presentations; 240/240 callbacks and GPU completions, 12/12 images destroyed. |
| Patched 1.4.2, release | Asynchronous | 240 / 244 | Four restores, 68 hidden presentations; all readbacks and preservation checks pass. |
| Patched 1.3.0, release | Asynchronous | 240 / 244 | Four restores, 70 hidden presentations; all readbacks and preservation checks pass. |
| Original 1.4.2 | Synchronous | 240 / 244 | Four restores, 80 hidden presentations; all readbacks and preservation checks pass. |
| Patched 1.4.2, counter-only, longer | Asynchronous | 960 / 964 | Four restores, 73 hidden presentations; 960/960 callbacks and GPU completions, 12/12 images destroyed. |

All five processes exit 0 without timeout. The longer run takes 15.733 s;
its maximum restore delay beyond the requested 250 ms is 5.658 ms. Ordinary
per-image semaphore reuse and explicit retirement fences remain enabled.
No diagnostic CPU render wait or semaphore-style override is used.
This covers AppKit `orderOut`/`orderFront`, not minimization, occlusion,
display sleep or indefinite resource stability.

Logs, source snapshots, hashes and commands: `.local/mvk-main-path`.

```sh
/path/to/presentation-harness /path/to/counter-only/MoltenVK one async \
  --trace --hide-restore --frames-per-cycle=240
```

Bound the owning subprocess wall time separately for longer configurations.

## Installed RetroArch

RetroArch 1.22.2 `fce35fc7` loads the installed rolling core and bundled patched
1.4.2 without a driver override. Logs confirm the provider path, marker 1 and
per-instance asynchronous submission.

An isolated Daytona run uses its own config, options, storage, saves and logs.
Native Hide RetroArch followed by Raise restores a standard window with visible
Daytona title output. This is a UI observation, not an independent OS visibility
measurement; the native harness measures visibility separately. RetroArch
reaches its configured 5400-frame limit, exits 0 after 98.761 s and logs normal
game/core unloading. Evidence including the final image is retained in
`.local/comparison/mvk-main-path-hide-restore`.

This cold-cache run includes UI interaction and is excluded from performance
baselines. It does not establish controlled driving, physical input or audible
continuity. A first attempted native-Quit check happened after automatic exit
and is not counted as a native-Quit test.

## Separate Native Quit Failure

Two dedicated sessions, without recording, select **Quit RetroArch** from the
native application menu, the action used by Cmd+Q:

| Instance Driver | Confirmed Policy | Exit | Wall Time |
| --- | --- | --- | --- |
| Installed patched 1.4.2 | Marker 1, asynchronous | SIGABRT (-6) | 42.271 s |
| Official original 1.4.2, child-only override | Marker 0, synchronous compatibility | SIGABRT (-6) | 37.232 s |

The patched run's system crash report shows `NSApplication terminate:`, `exit`,
`__cxa_finalize_ranges` and `std::terminate` on the crashing thread. Both logs
stop after native draw-observer shutdown, without the normal game/core unload
sequence. Thus neither our drawable patch nor asynchronous submission is a
necessary condition. This does not exclude every driver issue.

The installed revision's official
[Cocoa frontend source](https://github.com/libretro/RetroArch/blob/fce35fc7/ui/drivers/ui_cocoa.m)
has `applicationShouldTerminate:` request `CMD_EVENT_QUIT`, stop the draw
observer and return `NSTerminateNow`. Its normal `rarch_main` loop instead
reaches `main_exit(NULL)` after its quit condition. This supports investigating
early native termination before core teardown. The core has a static joinable
pause-watchdog thread stopped through `xenia_stop_emulator`; its destructor is
a plausible source of `std::terminate`, not yet a proven cause.

Evidence: `.local/comparison/mvk-main-path-clean-native-quit`,
`.local/comparison/mvk-main-path-original-native-quit`, the copied crash report
and exact frontend source snapshot under `.local/mvk-main-path`.

No frontend/core workaround is added in this MoltenVK-scoped activity.
Debugger attribution and teardown-order changes belong to a lifecycle follow-up.

## Disposition

No additional shared-queue MoltenVK failure was reproduced. The existing scoped
candidate remains installed. These checks do not establish a general multi-queue
fix or upstream readiness. No new driver/core build or deployment is needed.
Installed core, matching `.info`, driver, executable and user-config hashes are
checked against their pre-test values; core/framework signatures pass. The
current validated rolling core remains `xenia_edge_libretro`.
