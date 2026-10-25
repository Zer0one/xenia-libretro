# MoltenVK Drawable Ownership Review Draft

Status: Local review material, 24 October 2026. No issue comment, PR, commit,
push or public driver release has been submitted.

Follow-up: the broader [Independent Queue Correction](INDEPENDENT_QUEUE_FIX.md)
now addresses the observed semaphore and CPU drawable-ordering reproducers.
This draft describes the earlier minimal ownership-only proposal; it is not a
submission-ready description of the broader candidate.

## Proposed Title

Preserve Swapchain Drawable Ownership Until Queue-Ordered Presentation Capture

## Problem And Candidate

On Apple M4 / macOS 26.5.1, asynchronous host submission can overlap logical
swapchain-image acquisition with earlier queued rendering/presentation. The
existing `acquireAndSignalWhenAvailable()` releases the slot's Metal drawable
before the earlier work necessarily captures it. Earlier paired diagnostic
traces show the drawable released between texture lookup and presentation
capture, followed by reuse of the pointer with a different drawable ID.

The candidate removes this release from acquisition. The presentation path
captures and retains the image and drawable, clears the slot, then uses the
existing scheduled/completed handlers. Acquisition signaling, callback placement
and the public Vulkan API remain unchanged. This is a proposed scoped fix for
shared submission queues, not a complete independent-queue ordering solution.

The reviewable patch changes `MVKImage.mm` only. The local capability marker,
Xenia's automatic compatibility policy, and the 1.3.0 Metal SDK declaration guard
are separate integration changes and do not belong in the driver bug-fix diff.

## Reproduction

Build `presentation_harness.mm` using the command in [README.md](README.md).
Supply original and candidate drivers built from the same source revision:

```sh
./presentation-harness /path/to/original/MoltenVK one async --trace
./presentation-harness /path/to/candidate/MoltenVK one async --trace
./presentation-harness /path/to/original/MoltenVK multi async --trace
./presentation-harness /path/to/candidate/MoltenVK multi async --trace
./presentation-harness /path/to/candidate/MoltenVK multi sync
```

The default workload clears and reads back pixels, checks explicit image
release/reacquisition, presents 240 frames and retires four swapchains. It uses
one binary present semaphore per image, waited acquisition fences, concurrent
sharing for distinct queue families, and a separate fence per presentation
waited at retirement. Portability subset is enabled when advertised.

Diagnostic isolation:

```sh
./presentation-harness /path/to/candidate/MoltenVK multi async --present-only
./presentation-harness /path/to/candidate/MoltenVK multi async --wait-render
MVK_CONFIG_VK_SEMAPHORE_SUPPORT_STYLE=3 \
  ./presentation-harness /path/to/candidate/MoltenVK multi async
```

The last two commands add CPU ordering and must not be presented as equivalent
to the normal asynchronous multi-queue workload or as a performance solution.
The process runner should enforce a wall-clock timeout as well: queue-idle and
driver teardown are not guaranteed bounded by the harness's fence timeouts.

## Verified Scope

- Project source `e9b7bd2e4d6f365b36d29f5f57b8d39ca92f157f`, reporting 1.4.2:
  corrected shared-queue candidate passes 240 frames / 244 readbacks / four
  swapchains. A counter-only candidate records 240 presentation starts, 240
  ends, 240 GPU completions and 12 images constructed/destroyed. Its same-source
  original control crashes with SIGSEGV. The crash is timing-sensitive: another
  official 1.4.2 shared-queue run completes, and a preliminary control variant
  completed rendering while leaving diagnostic retirement counts unmatched.
- Exact 1.3.0 source `49b97f26ae013b9e5bfb3098ee5dea5e4f58e9e8`: corrected
  shared-queue candidate passes the same workload; original packaged 1.3.0
  crashes in its asynchronous shared-queue run.
- Independent asynchronous queues fail with original and candidate drivers.
  Readback mismatches also occur with release subtests disabled. Original
  1.3.0's corrected multi-queue run reports incorrect readback. Synchronous
  1.4.2 controls pass.
- Candidate independent queues pass with the diagnostic render-fence wait in
  1.4.2 and 1.3.0; the 1.4.2 callback-semaphore control also passes.
- Existing isolated RetroArch tests cover native reset, resize, GPU screenshots,
  recording, content close/quit and original-driver compatibility notification.
  These runtime artifacts were not rebuilt or replaced during this audit.

The project 1.4.2 revision is not asserted to equal the official release tag.
All outcomes are bounded Apple M4 tests, not Vulkan conformance or cross-device
validation. Validation layers were not available in the local environment.
Local commands, hashes, logs, matrices and sampled stacks are retained in
`.local/mvk-queue-audit`; earlier evidence is preserved under its original paths.

## Independent-Queue Investigation

The follow-up [Queue Ordering Findings](QUEUE_ORDER_FINDINGS.md) supersedes the
hypothesis-only status below with two observed mechanisms: a texture identity
change within one render submission and a distinct native binary-semaphore
token reuse defect. Fresh-semaphore presentation controls preserve the first
failure; a surface-free buffer-copy test isolates the second on official 1.3.0
and 1.4.2. The minimal drawable candidate is unchanged and is not a fix for
either general independent-queue case.

Samples of the original 1.4.2 and candidate show both queue workers inside
`getCAMetalDrawable()` / `CAMetalLayer.nextDrawable`. The source lazily reads,
publishes and clears the slot drawable; GPU event waits are encoded before
presentation but do not themselves serialize that CPU-side access with another
queue worker. Readback errors and successful CPU-ordering controls support this
as the next investigation area. They do not identify which drawable generation
was used by each command, prove that every timeout has the same cause, or show
that the candidate introduces no independent-queue regression.

The intended invariants for a broader fix are one drawable generation per
acquisition, stable texture identity throughout encoding, and retained ownership
until each queued consumer captures its reference. A mutex held across blocking
`nextDrawable` is not a justified fix: it can block code needed to return a
drawable. Moving callbacks or forcing acquisition fences is also outside the
minimal candidate.

## Related Upstream Report

[MoltenVK issue #2791](https://github.com/KhronosGroup/MoltenVK/issues/2791)
reports a drawable lifetime race on an Intel/AMD Mac, and proposes locking the
drawable slot and atomically retaining the captured reference. Its author also
reports remaining stale-reuse warnings. This is relevant external evidence, not
proof of an identical cause or a reviewed/merged fix for this workload. The
suggested callback relocation in a comment is not included in our candidate.

## Before Submission

Review the slot ownership semantics, post-presentation readback/export behavior
and release/destruction paths; validate a pinned current upstream base before
advertising current-head applicability. Run Vulkan validation when available.
Present the independent-queue reproducer and limits alongside the shared-queue
fix. Maintainers can assess a focused PR without requiring it to solve every
pre-existing driver issue; the current evidence does not justify advertising a
general presentation fix or declaring the patch ready to merge.

## Primary References

- [Swapchain Semaphore Reuse](https://docs.vulkan.org/guide/latest/swapchain_semaphore_reuse.html)
  distinguishes per-image semaphore reuse from safe presentation-resource
  destruction and explains the role of maintenance1 presentation fences.
- [Presentation Fences](https://docs.vulkan.org/refpages/latest/refpages/source/VkSwapchainPresentFenceInfoKHR.html)
  defines when present wait semaphores and the swapchain may be destroyed.
- Source paths reviewed at the local 1.4.2 revision: `MVKQueue.mm`,
  `MVKImage.mm`, `MVKSync.mm` and `MVKSync.h` under `MoltenVK/MoltenVK/GPUObjects`.
