# CPU Encoding Waits During Device Loss

24 October 2026. Local Apple M4 / macOS 26.5.1. Driver changes only.
The signed 1.4.2 correction is installed in the local RetroArch; the previous
complete framework is retained. No commit, push or public submission.

## Finding And Correction

The binary CPU encoding gate initially registered its waiter under the device's
`_sem4Lock`, then read the non-atomic configuration result after releasing that
lock. `markLost()` writes that result under the lock. ThreadSanitizer identifies
the conflicting read in `MVKSemaphoreSubmitInfo::waitForSignalEncoding()` and
write in `MVKDevice::markLost()`. A normal run did not strand its waiters, but
that does not make the concurrent access valid.

The driver now centralizes this protocol in
`MVKDevice::waitForEncodingSignal()`:

1. Lock the same mutex used by `markLost()`; check the result and register a
   pending waiter only while the device is healthy.
2. Unlock before blocking on producer CPU encoding.
3. Re-lock to remove the registration and return the device result.

A null waiter queries the result under that mutex. Rendering and presentation
workers use the synchronized result and exit through their existing `finish()`
path on error. The rendering capture scope is entered before that cleanup.
Native GPU semaphore waits, token reservation, drawable ownership and the core
are unchanged. Other upstream configuration-result reads are outside this fix;
this is not a claim that all driver data races are corrected.

## Fault Injection

The optional `device_loss_harness.mm` links against an exact prepared driver and
its matching private headers. It creates real logical devices/semaphores,
reserves an internal pending CPU encoding state, then calls the real `markLost()`
path. It covers loss before registration, 16 confirmed registered waiters,
1,000 registration/loss races, error-result propagation and registration removal.
Separate checks run the real asynchronous rendering and presentation submission
workers and require their pending job counts to reach zero after loss.

These are internal driver tests. The pending encoding state is synthesized;
no application Vulkan signal is submitted for it and no artificial pending GPU
operation is created. The presentation abort check has no swapchain to access.
No physical GPU fault is induced. This does not cover Metal error delivery or
resource retirement after a real fault during an in-flight GPU workload.

The [Vulkan lost-device requirements](https://docs.vulkan.org/spec/latest/chapters/devsandqueues.html#devsandqueues-lost-device)
require blocking API operations to terminate in finite time on a lost device.
These tests establish bounded CPU-gate wakeup and worker abort, not broad
lost-device conformance of those APIs.

## Results

| Variant | Result |
| --- | --- |
| Previous Release 1.4.2 | 202 dependency cases, 200 races; wakeup passes. |
| Previous TSan 1.4.2 | Reports the configuration-result data race; retained as the expected failing control. |
| Corrected TSan 1.4.2 | 1,002 dependency cases, 1,000 races, 16 blocked waiters and both worker aborts pass; no reported TSan failure. Maximum observed wakeup 0.266 ms. |
| Corrected Release 1.4.2 | Same checks pass; maximum observed wakeup 0.121 ms. |
| Corrected Release 1.3.0 | Same checks pass; maximum observed wakeup 0.112 ms. |
| Corrected ASan 1.4.2 | Driver and harness instrumented; same checks pass. LeakSanitizer disabled. |
| 1.4.2 Renderer Chain | 480 presentations/readbacks, four swapchains, fence-only retirement; zero Vulkan synchronization validation errors/warnings. |
| 1.4.2 Release/Reacquisition | 240 presentations / 244 readbacks, four preservation checks; zero validation errors/warnings. |
| 1.3.0 GPU-Only Acquire And Chain | 480 presentations/readbacks; zero validation errors/warnings. |
| Shared Queue With Metal/Vulkan Validation | Confirmed `MTLDebugDevice` and synchronization validation; 240 presentations / 244 readbacks, zero Vulkan errors/warnings. |
| Timeline / Imported Event Buffer Regressions | 32 correct rounds each; imported event advances from 7 to 39. |

Waking promptly is a correctness observation, not a performance benchmark. Each
corrected fault harness also creates two devices for the separate worker checks;
the JSON `devices` counter counts the dependency cases only.

Source pins remain `e9b7bd2e4d6f365b36d29f5f57b8d39ca92f157f` (reports 1.4.2) and
`49b97f26ae013b9e5bfb3098ee5dea5e4f58e9e8` (1.3.0). Exact commands, source snapshots,
the expected TSan report, complete combined diffs and driver identities are under
`.local/mvk-device-loss`. Previous validation evidence remains unchanged.

## Reproduce

Use the full source staging pipeline in [Independent Queue Correction](INDEPENDENT_QUEUE_FIX.md),
then configure its local CMake build with `-DMVK_BUILD_DEVICE_LOSS_HARNESS=ON`.
Build target `mvk-device-loss-harness`; run it with a race count from 1 to 1,000
under an external timeout. The option defaults to off and adds no hooks to the
driver. For TSan or ASan, instrument both driver and harness using the same
compiler sanitizer flags. Do not mix private headers from another prepared source.

## Remaining Scope

The later [Timeline Image Handoff](TIMELINE_HANDOFF.md) adds focused swapchain
image coverage beyond these earlier binary/device-loss checks. External Metal
payload semantics, other hardware and upstream design review remain open. The new mutex protocol has not
been performance-tuned. Native Quit remains in the main core lifecycle track.
