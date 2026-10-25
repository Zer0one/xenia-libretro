# Timeline Image Handoff

24 October 2026. MoltenVK-only follow-up on Apple M4 / macOS 26.5.1.

## Reproduction

The prior binary/device-loss candidate can read back a black swapchain image
when rendering queue A signals a timeline semaphore, queue B waits on it, copies
the image and signals a binary semaphore for presentation. The corrected test
includes a transfer-write barrier before reusing its readback buffer. Both pinned
1.4.2 and 1.3.0 asynchronous drivers fail that test with zero Vulkan validation
errors or warnings; synchronous controls pass. Earlier test attempts with a
missing buffer barrier remain recorded as invalid controls.

A diagnostic-only trace shows queue B returning one drawable for an image,
presentation detaching it, then queue A returning a different drawable for the
same image before encoding its timeline signal. GPU semaphore ordering cannot
order these CPU-side drawable lookups. The trace driver is not installed.

## Candidate Design

`patch_timeline_encoding.py` extends the existing binary encoding protocol to
Vulkan-managed native timeline semaphores. Each distinct pending wait threshold
shares a CPU state. Encoding a queue signal releases every threshold at or below
its value; a host signal does the same after updating the Metal shared event.
Completed states are erased. A GPU-completed value already satisfies a new wait.
The existing device-loss registration/result lock also covers these waits.

Asynchronous workers may wait for CPU encoding while the public submit returns
to its caller. Synchronous public submits skip this extra timeline CPU wait so
the same host thread can submit or signal a future value. The test submits all
producer dependencies before binary WSI presentation. Native GPU waits remain
in place in both modes. No GPU completion wait is added by this correction.

Legacy `VkTimelineSemaphoreSubmitInfo` values rebind the CPU state after pNext
parsing; API 2 metadata reserves its actual value directly. Copy and assignment
preserve the shared state. The private test checks both metadata paths. The original
graphics tests used `vkQueueSubmit`; the later [PR Preparation](PR_READINESS.md)
adds the agreed focused `vkQueueSubmit2` image-path coverage on both source
versions and the fixed current-upstream target.

Imported or exportable Metal event payloads retain their previous behavior and
skip this Vulkan-only protocol. External producers, emulated timeline backends,
other GPUs and general Vulkan conformance remain unverified. No new event
listener or callback lifetime is introduced.

## Reproduction Commands

Prepare the binary, drawable and device-loss fixes first, then apply this
separate overlay outside the input tree:

```sh
python3 tools/moltenvk/patch_timeline_encoding.py \
  /path/to/device-loss-candidate/source /path/to/timeline-candidate
```

Build using the existing local driver recipe with `MVK_SOURCE_DIR` pointing to
the resulting `source`. `MVK_BUILD_TIMELINE_HARNESS=ON` enables an optional
private-ABI test linked against exactly that driver and its headers; it is not
a conformance test or part of the installed framework.

The maintained presentation harness adds `--timeline-chain`, `--timeline-forward`
and `--timeline-host-gate` to `--render-chain`. The forward case submits the
consumer before its producer on separate queues. The host gate is signaled on
the same host thread only after both public submits return, detecting an
accidental public-submit block. Final WSI presentation still waits on a binary
semaphore.

The private harness checks duplicate/multiple thresholds, CPU completion before
GPU execution, host signaling, state retirement, device-loss wakeup and skipping
exportable Metal payloads. An initial fixture retained uncommitted autoreleased
Metal command buffers across all rounds and exhausted the command queue limit;
per-round autorelease pools correct that fixture without changing the driver.

Source pins, commands, checksums, failed controls and the diagnostic trace are
preserved under `.local/mvk-timeline`. Previous performance comparisons and
soak results remain evidence for their exact previous builds. This activity
makes no new performance claim and changes no core source.

## Completed Focused Checks

| Variant | Checks | Result |
| --- | --- | --- |
| Release 1.4.2 | Future queue signals, then same-host-thread future signaling; synchronous and asynchronous modes | Four cases of 240 frames/readbacks each, zero Vulkan validation errors/warnings |
| Release 1.3.0 | Future queue signal plus same-host-thread signal, both modes | Two cases of 240 frames/readbacks each, zero Vulkan validation errors/warnings |
| Release 1.4.2 and 1.3.0 | Internal timeline protocol | 100 rounds each; 800 waits and 400 retired states per run |
| ASan 1.4.2 | Internal protocol and timeline image handoff | 100 rounds and 240 frames/readbacks, no ASan error; zero Vulkan validation errors/warnings |
| Release and ASan 1.4.2 | Existing device-loss regression | 500 registration/loss races each, 16 confirmed blocked waits and both worker aborts pass |
| Release 1.4.2 | Binary renderer-chain regression | 240 frames/readbacks, zero Vulkan validation errors/warnings |
| Release 1.4.2 | Shared queue, GPU-only acquisition with Metal API Validation | 240 frames/readbacks; debug Metal device confirmed, no reported Metal validation error |

ASan leak detection is disabled; state-retirement checks cover the specific CPU
encoding states only. These are correctness checks, not timing benchmarks.

ThreadSanitizer also passes 100 internal timeline rounds (800 waits, 400 retired
states) and the 500-race device-loss regression, without a reported data race.

## Local Installation

The signed 1.4.2 framework is installed in the user's existing RetroArch app.
The complete prior framework is retained under
`.local/mvk-timeline/installation-backup/MoltenVK-before-timeline-fix.framework`.
The global synchronous default remains enabled; the existing core selects
asynchronous submission per recognized patched instance. No marker or core
policy changed. Core, matching `.info`, frontend executable and user config
checksums remain unchanged.

The staged session shows Daytona's initial warning screen; the default
installed-driver session reaches its title screen. Both complete controlled
frame-limited exit (28.373 s and 27.246 s).
Logs identify each exact provider path and asynchronous per-instance policy.
The media file was renamed to `.xcp` externally; its SHA-256 matches the previous
test content. The old hardcoded path failure is retained separately.
These short sessions establish visible startup, not interactive gameplay or a
new performance result. The existing guest indirect-ringbuffer diagnostic is
recorded; native Quit remains a separate core-lifecycle issue.

Installed driver SHA-256:
`6c511b765b68df9043b05fe6cdaacb78ce256115aab887a2b9d9c582143aa22b`.
Unsigned release SHA-256:
`72b256a9be0cdcde2808c87922f7d44469039e88b883a62f127eec2bce7d493f`.
The 1.3.0 validation build remains available locally and was not installed.
