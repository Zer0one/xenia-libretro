# Independent Queue Correction Candidate

Updated: 24 October 2026. Local Apple M4 / macOS 26.5.1 validation.
No public submission, commit or push. The initial extended 1.4.2 candidate passed
a 25.154-minute soak. A renderer-handoff follow-up and Vulkan synchronization
validation are recorded separately in `.local/mvk-followup`; the original
commands, hashes, results and rollback receipt remain in `.local/mvk-binary-token`.
The latest signed 1.4.2 follow-up includes the subsequent device-loss correction
described in [CPU Encoding Wait Validation](DEVICE_LOSS_VALIDATION.md). It is
installed in local RetroArch; deployment and the previous complete framework are
recorded under `.local/mvk-device-loss`.
See the dedicated [MoltenVK Roadmap](ROADMAP.md) for remaining driver work.

## Driver Changes

The complete candidate combines the existing drawable ownership patch with
three changes in MoltenVK. Xenia emulation code, the core's shared-queue CPU
completion guard and frontend configuration are unchanged.

1. **Reserve Binary Tokens Before Dispatch.** Independent wait and signal
   sequences allocate matching event values during submission construction,
   rather than reading a counter advanced by an asynchronous worker. Submission
   copies preserve the reservation. Both submission APIs are covered; legacy
   timeline pNext values update timeline semaphores only. Deferred acquisition
   signals reserve from the same signal sequence. Imported shared events retain
   the previous initial-value convention.
2. **Coordinate CPU Encoding And Drawable Publication.** Native-event binary
   signals carry a shared CPU-encoding completion state. Both rendering and
   presentation wait for the corresponding producer to finish encoding before
   accessing the drawable.
   This waits for CPU encoding, not GPU completion; native GPU event waits still
   enforce GPU dependencies. Wait registration and result checks use the existing
   device-loss semaphore mutex; it is not held while waiting. The state map
   relinquishes ownership when the matching wait is
   reserved; submissions/deferred signalers retain the shared state they need.
3. **Protect Drawable Lifetime.** One fetcher per image publishes its drawable;
   a condition variable coordinates competing lookups without holding the image
   mutex across blocking `nextDrawable`. Returns are retained/autoreleased under
   the mutex. Slot removal is atomic under that mutex and releases outside it.
   For 1.4.2, the completion callback also accesses/notifies the swapchain under
   the detachment mutex before its final image release. The older 1.3.0 callback
   has no corresponding post-release notification access.

Callback registration and acquisition-fence signaling placement are unchanged.
No forced fence signal, global asynchronous default or layer-size pulse is added.
This CPU coordination restricts parallel encoding at binary semaphore dependencies;
its performance impact is not established by the correctness tests.

## Reproducible Build

Start from a pristine pinned source tree, outside all output directories:

```sh
python3 tools/moltenvk/patch_binary_tokens.py /path/to/MoltenVK /stage/tokens
python3 tools/moltenvk/patch_queue_drawables.py /stage/tokens/source /stage/queues
```

Use the existing [CMake recipe](README.md#build), setting
`MVK_SOURCE_DIR=/stage/queues/source` and the matching source revision, version
and exact external dependencies. `prepare_build.py` adds the original ownership
change. Staging copies all translation units so every object sees the same
private class definitions. The upstream checkout is never edited. Generated
upstream-path combined diffs are retained locally for both source versions.

The build helper's SDK 26 guard applies only to older sources redeclaring
`lodBias`; newer private sampler declarations stay enabled. Prepared inputs are
registered as CMake configure dependencies.

## Evidence

- The ownership-only control rebuilt from the same 1.4.2 revision and dependency
  pins reproduces 31/32 stale semaphore copies and a multi-queue presentation
  readback failure with fresh semaphores. Its synchronous presentation passes.
- The token-only candidate removes stale copies, including 1,024 reused rounds,
  API 2, timeline and mixed binary/timeline-info controls. It still fails the
  separate drawable presentation case.
- The complete candidate passes shared/independent presentation, fresh/reused
  semaphores, explicit image release/reacquisition and acquisition semaphores.
- Both 1.4.2 and exact 1.3.0 sources build and pass the exercised native matrix.
  Imported Metal shared events start at 7 and reach the expected 39 after 32
  Vulkan signal/wait rounds, with correct copies. GPU-only image acquisition without an acquisition CPU
  fence also passes 960 presentations/readbacks. A binary export request can be
  created, but this base returns nil from its binary-event export query; that
  case does not prove exported-object interoperability or external signaling.
- A counter-only build checks presentation starts/ends, GPU completions, image
  destruction and destruction of the new CPU encoding states. The 100-swapchain
  test completes 6,000 presentations with all 300 images and 6,000 states retired.
- The final counter-only soak completes 90,000 presentations, 90,100 readbacks
  and 100 swapchain lifetimes in 1,509.216 s. All 300 images, 90,000 CPU states
  and presentation/GPU callbacks retire; all 100 checkpoints have balanced counts.
  Process RSS ranges from 48,300,032 to 56,754,176 bytes and ends at 50,495,488.
  Some other short correctness runs overlap; this is not a performance benchmark.
- The reviewed callback variant passes 100 short swapchain lifetimes using only
  maintenance1 presentation fences, without queue-idle, plus AddressSanitizer
  (300 presentations/400 readbacks). LeakSanitizer is disabled; explicit counters
  cover the instrumented driver-owned objects.
- Metal API Validation is confirmed active by `MTLDebugDevice` and the framework
  log, with no reported validation failure in the exercised final test.
- Isolated RetroArch sessions on both versions complete resets, content close
  and controlled quit. The signed final 1.4.2 framework also renders through
  full-screen entry/exit. UI observations and evidence limits are recorded.

All earlier source variants, driver identities and test outcomes remain
preserved. A preliminary v2 soak was deliberately stopped for the callback
review; it is not counted as a completed soak or a driver failure.

## Renderer Handoff Follow-Up

The earlier presentation-only gate is insufficient for a renderer-to-renderer
dependency. A new bounded reproducer clears an image on queue A, copies it on
queue B after a binary semaphore wait, then presents it on B. Extra valid memory
barriers delay A's CPU encoding. The previous 1.4.2 candidate passes without that
delay but produces incorrect readback with 20,000 producer barriers; synchronous
submission passes. The failure also reproduces with Vulkan synchronization
validation enabled, without a reported application API error before the mismatch.

The gate now also runs at the start of command-buffer submission encoding, before
any image texture lookup. It follows capture-scope entry so the existing failure
cleanup has a matching scope to end. Device-loss registration/checks and native
GPU semaphore waits are unchanged. Binary wait dependencies require an already
submitted signal and its dependent signals. This binary follow-up did not cover
timeline semaphores; the later [Timeline Image Handoff](TIMELINE_HANDOFF.md)
adds a separate protocol for their valid forward/host signaling.

Both source versions pass the new renderer chain and the normal release/
reacquisition checks with Vulkan synchronization validation. The 1.4.2 follow-up
also passes GPU-only acquisition, fresh semaphores, shared queues, Metal API
Validation and an AddressSanitizer driver/harness run (600 frames, 10 swapchains,
fence-only retirement; LeakSanitizer disabled). A longer renderer-chain run
completes 3,600 presentations/readbacks and 30 swapchains with zero Vulkan
validation errors or warnings. These are correctness tests, not performance
measurements, and do not inherit the older candidate's 25-minute soak result.

The validation harness now declares the surface-maintenance extension dependencies
and resolves functions through `vkGetInstanceProcAddr`, allowing the existing
Vulkan loader to insert validation layers. An initial validation run found the
missing extension declaration in the harness; corrected runs are recorded
separately. Local checksum-verified validation-layer/dependency bottles are
extracted below `.local/mvk-followup`; no global installation is changed.

## Remaining Limits

These are bounded local correctness results, not Vulkan conformance or proof on
other GPUs. Vulkan synchronization validation, Metal validation and AddressSanitizer
cover the follow-up cases listed above; they are complementary, not conformance.
Device-loss CPU gate wakeup/result propagation and worker abort now have internal
fault-injection coverage, including TSan and ASan. Real Metal fault delivery and
in-flight GPU resource retirement are not exercised by those synthetic states.
The binary CPU gate is not a formal proof of arbitrary image-generation ordering.
The later [Timeline Image Handoff](TIMELINE_HANDOFF.md) covers the exercised
Vulkan-managed native timeline chains. External Metal payloads skip that added
gate; general handoff patterns remain part of upstream design review. External Metal
producers, complete imported/exported payload interoperability, post-presentation
export semantics and performance tuning remain separate checks.
A pinned current upstream base and maintainer review are still required before
claiming an upstream-ready general fix.

Native Quit / Cmd+Q remains a separate core-lifecycle investigation in Main.
It is neither fixed nor used as an acceptance failure for these driver changes.

Primary references: [Vulkan submission requirements](https://docs.vulkan.org/refpages/latest/refpages/source/vkQueueSubmit.html),
[Presentation fences](https://docs.vulkan.org/refpages/latest/refpages/source/VkSwapchainPresentFenceInfoKHR.html),
[Related upstream lifetime report](https://github.com/KhronosGroup/MoltenVK/issues/2791).
