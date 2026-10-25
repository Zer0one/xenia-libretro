# Local MoltenVK Drawable Patch

This directory holds a driver source patch, its local capability marker and a
native Vulkan test. The driver is a separate artifact from the Libretro core.
RetroArch loads the installed framework and owns its swapchain.

## Current Status

25 October 2026: the separate acquisition follow-up builds against pinned upstream `5189f8d` (1.4.3 development) and is installed locally for user testing. Its final five focused cases pass 483 readbacks with Vulkan/Metal validation and zero reported warnings/errors; acquisition fence reuse has 0/3 stale signals. The core release does not bundle this driver. The version table and minimal ownership-only discussion below describe earlier candidates; see [Roadmap](ROADMAP.md) for the later combined correction and its limits. The public upstream PR remains unpublished.

## Scope

The patch moves the drawable release from logical image acquisition to the
queue-ordered presentation capture, after retaining the image and drawable for
the command-buffer completion. It leaves acquisition-fence signaling and the
existing presentation-completion mechanism unchanged.

Validated local sources:

| Version | Source Commit | Result |
| --- | --- | --- |
| 1.4.2 | `e9b7bd2e4d6f365b36d29f5f57b8d39ca92f157f` | Local ARM64 driver and RetroArch shared-queue tests pass. |
| 1.3.0 | `49b97f26ae013b9e5bfb3098ee5dea5e4f58e9e8` | Exact dependency pins, local ARM64 build, native reset/resize and GPU recording pass. |
| 1.4.3 development | `5189f8de86ec365860f63bf1da736815cfaea5cd` | Separate current-main PR candidate: focused graphics and internal protocol checks pass. Original same-revision async controls fail as recorded in [PR Preparation](PR_READINESS.md). This earlier PR build was not installed; the later acquisition follow-up is installed as described above. |

The minimal ownership-only candidate still fails asynchronous presentation on independent render/present queues
in the focused harness with original and patched drivers (timeouts, incorrect
readback, and an observed invalid-resource device loss). Synchronous
multi-queue tests pass. This candidate is validated for the shared submission
queue used by the local Xenia core; it is not a general multi-queue fix.

`patch_marker.cc` is local integration metadata, separate from the upstream fix.
Version 1 means the reviewed shared-queue drawable change is present. The core
checks the marker in the exact provider selected by the frontend, including the
library address that owns the symbol; it does not infer patch presence from the
MoltenVK version or from another library loaded into the process.

With Vulkan negotiation v2 and `VK_EXT_layer_settings`, the core selects
asynchronous host submission for this marker and synchronous compatibility
submission without it. The unpatched path logs and displays a notification.
The setting belongs to the new instance, leaving global configuration and
environment variables unchanged. The core's CPU-completed shared-queue blit
remains enabled in either mode. Older frontend negotiation interfaces retain
their existing driver defaults; they cannot perform this per-instance selection.

## Build

Use local source copies and the exact dependency commits listed in that
revision's `ExternalRevisions`. Pass a Vulkan include directory from the
matching Vulkan-Headers checkout or official package. No downloads are performed
by this build or by the core at runtime.

```sh
cmake -S tools/moltenvk -B /path/to/driver-build -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
  -DMVK_SOURCE_DIR=/path/to/MoltenVK \
  -DMVK_SOURCE_REVISION=49b97f26ae013b9e5bfb3098ee5dea5e4f58e9e8 \
  -DMVK_FRAMEWORK_VERSION=1.3.0 \
  -DMVK_VULKAN_HEADERS_DIR=/path/to/Vulkan-Headers/include \
  -DMVK_SPIRV_HEADERS_DIR=/path/to/SPIRV-Headers \
  -DMVK_SPIRV_TOOLS_DIR=/path/to/SPIRV-Tools \
  -DMVK_SPIRV_CROSS_DIR=/path/to/SPIRV-Cross \
  -DMVK_CEREAL_DIR=/path/to/cereal
cmake --build /path/to/driver-build --target MoltenVK -j 4
```

Generated sources and diffs live under `driver-build/prepared`; the upstream
checkout is not edited. For 1.3.0, a separate SDK compatibility diff avoids
redeclaring `MTLSamplerDescriptor.lodBias` when building with the Metal 26 SDK.
The CMake recipe builds successfully and its 1.3.0 driver passes the focused
single-queue asynchronous harness. Its generated patched sources match the
separate RetroArch-tested 1.3.0 build exactly. Full commands and dependency
inputs are recorded in `.local/mvk-deployment`.

To generate only the reviewable drawable diff:

```sh
python3 tools/moltenvk/patch_driver.py \
  /path/to/MoltenVK/MoltenVK/MoltenVK/GPUObjects/MVKImage.mm \
  /path/to/new-output-directory
```

## Focused Test

```sh
xcrun clang++ -std=c++17 -O2 -arch arm64 \
  -Ithird_party/Vulkan-Headers/include \
  tools/moltenvk/presentation_harness.mm \
  -framework AppKit -framework Metal -framework QuartzCore \
  -o /path/to/presentation-harness
/path/to/presentation-harness /path/to/MoltenVK one async
```

The harness owns its window, device and queues. It checks GPU clear/readback,
explicit image release/reacquisition and four swapchain lifetimes. `multi`
uses distinct graphics queue families with concurrent image sharing; `sync`
selects synchronous host submission. It enables `VK_KHR_portability_subset`
when advertised and queries/enables swapchain maintenance1. A separate fence
for each presentation is waited before destroying that swapchain and its
semaphores. These fences add no steady-state CPU wait; image reacquisition and
its fence establish normal per-image semaphore reuse. Fence waits pump the
application event loop and fail after five seconds. Readback checks cover the
exercised patterns, not every swapchain content-preservation scenario.

Optional diagnostics:

- `--trace`: record acquisition, submit, present and fence checkpoints.
- `--present-only`: omit the release/reacquisition preservation subtest.
- `--wait-render`: wait for rendering on the CPU before queuing presentation.
  This deliberately changes ordering and is diagnostic, not a performance fix.
- `--fresh-semaphores`: allocate a separate semaphore for every presentation,
  retaining all until presentation-fence retirement. This isolates drawable
  access from binary semaphore reuse without adding a CPU render wait.
- `--hide-restore`: hide the native window at frame 20 of each swapchain,
  then restore after 250 ms using wall time in the event pump. Check actual
  visibility, submissions while hidden and four restores. This covers
  `orderOut`/`orderFront`, not minimization or display sleep.
- `--frames-per-cycle=N`: select 1–3600 frames per swapchain (default 60).
  Hide/restore requires at least 21. Bound the subprocess wall time separately.
- `--cycles=N`: select 1–1000 swapchain lifetimes (default 4).
- `--acquire-semaphore`: use a ring of acquisition semaphores, waiting their
  previous render fence before reuse; requires `--present-only`.
- `--retire-without-idle`: destroy after render/presentation fences without an
  extra queue-idle wait, exercising retirement while handlers can be returning.
- `--gpu-acquire-only`: with acquisition semaphores, omit the CPU acquisition
  fence; rendering relies on the semaphore dependency.
- `--progress`: report per-cycle retirement counters and process RSS. RSS includes
  system/allocator caches and is not itself a count of leaked driver objects.

The minimal ownership-only candidate fails independent asynchronous queues even with `--present-only`. The patched
1.4.2 and 1.3.0 drivers pass the bounded multi-queue case with `--wait-render`;
1.4.2 also passes with child-only `MVK_CONFIG_VK_SEMAPHORE_SUPPORT_STYLE=3`,
which uses completion callbacks for CPU semaphore waits. These controls support
investigating CPU encoding/drawable ordering; they do not establish one proven
root cause for every failure. The shared-queue default still passes without
either diagnostic override.

Diagnostic-only builds additionally count begin/end presentation, constructed/
destroyed images and GPU completions. The bounded patched 1.4.2 test completes
240/240 presentations, destroys 12/12 images and completes 240 GPU callbacks.
These counters are not in the installed driver. Longer or different workloads
can still encounter the upstream presentation-completion limitations. The
harness reports failure if an instrumented driver has unmatched presentation/
image counts or missing GPU completions after its bounded drain.

The shared-queue hide/restore checks pass with patched 1.4.2 and 1.3.0, and
original 1.4.2 in synchronous mode. The longer counter-only run completes
960/960 presentations and 964 readbacks, with 12/12 images destroyed.
Installed RetroArch also restores visible Daytona output and exits normally
at its frame limit. Separate native Quit tests reproduce SIGABRT without
recording with both patched/asynchronous and original/synchronous drivers.
They do not establish a MoltenVK fault. See
[Main Path Validation](MAIN_PATH_VALIDATION.md) for scope and evidence.

See [Upstream Review Draft](UPSTREAM_REVIEW.md) for the review scope, related
upstream report, reproducer commands and remaining acceptance criteria. Local
raw evidence from the corrected harness is in `.local/mvk-queue-audit`.

## Independent Queue Correction

The first extended 1.4.2 framework passed a 25.154-minute soak (90,000
presentations, 100 swapchains), Metal validation, AddressSanitizer and frontend
checks. A subsequent renderer-handoff correction also orders binary-dependent
rendering workers before drawable lookup. Its Vulkan synchronization validation,
ASan and 3,600-frame chain results are recorded in `.local/mvk-followup`, separately
from the preserved original evidence. The signed follow-up 1.4.2 framework is installed locally, with the previous
complete framework retained for rollback. The core itself is unchanged. See the
dedicated [MoltenVK Roadmap](ROADMAP.md) for remaining driver work.

A subsequent [device-loss correction](DEVICE_LOSS_VALIDATION.md) removes a
TSan-confirmed race in the CPU gate's error-state read. Registration, loss checks
and removal use the same device mutex; the mutex is released while waiting.
The latest signed 1.4.2 framework is installed locally, with exact deployment
receipts and rollback framework under `.local/mvk-device-loss`.

A broader local candidate now reserves matching binary-event tokens before
worker dispatch, coordinates rendering/presentation with producer CPU encoding, and
serializes drawable publication/lifetime. Both pinned 1.4.2 and 1.3.0 candidates
pass the exercised independent-queue matrix. See
[Independent Queue Correction](INDEPENDENT_QUEUE_FIX.md) for build staging,
validation evidence and remaining limits. The failures below describe the
original and minimal ownership-only candidates, not this extended candidate.

## Binary Semaphore Isolation

The independent-queue investigation now identifies two mechanisms: concurrent
drawable publication can change a texture within one submission, and native
binary-semaphore event tokens can reuse an already completed value. See
[Queue Ordering Findings](QUEUE_ORDER_FINDINGS.md) for exact traces, controls,
scope and remaining fix requirements. The installed driver/core are unchanged.

The surface-free reproducer requires two transfer-capable queue families:

```sh
xcrun clang++ -std=c++17 -O2 -arch arm64 \
  -Ithird_party/Vulkan-Headers/include tools/moltenvk/semaphore_harness.mm \
  -framework Foundation -framework Metal -o /path/to/semaphore-harness
/path/to/semaphore-harness /path/to/MoltenVK async
/path/to/semaphore-harness /path/to/MoltenVK async --fresh-semaphores
/path/to/semaphore-harness /path/to/MoltenVK sync
```

With native Metal events and asynchronous host submissions, original 1.3.0 and
1.4.2 copy the previous counter in 31/32 rounds when reusing the semaphore. Fresh
semaphores, synchronous submissions and the 1.4.2 child-only callback-semaphore
control copy all 32 values correctly. Both queue fences are waited before each
reuse and before resource destruction. This is not a conformance suite.

Diagnostic trace analysis:

```sh
python3 tools/moltenvk/analyze_queue_trace.py /path/to/events.jsonl \
  --output /path/to/analysis.json
```

## Deployment

Install a signed, validated framework into the local RetroArch app after
preserving the previous complete framework. Keep the default global submission
setting synchronous so other cores retain their defaults. Only this core's
recognized instance selects asynchronous submission. Merely rebuilding or
updating the core does not replace RetroArch's framework.

An upstream PR should contain the driver fix and a focused reproduction, with
the independent-queue limitation resolved or explicitly discussed. No upstream
submission or public driver release is made by this local workflow.

## Timeline Follow-Up

[Timeline Image Handoff](TIMELINE_HANDOFF.md) describes the additional native
timeline encoding protocol, its forward/host-signal tests, sanitizer results,
local installation and external payload limits. It layers onto the binary,
drawable and device-loss corrections. The optional private timeline harness
defaults to off and is never installed in RetroArch.
