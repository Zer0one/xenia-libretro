# Vulkan Presentation

Latest local integration: 24 October 2026. The core now negotiates a MoltenVK
submission policy per instance and provides an unpatched-driver fallback. The
local RetroArch framework has been updated to the validated drawable candidate;
its executable and user configuration are unchanged. The evidence sections
below preserve earlier experiments and their original artifact identities.
See the final integration section and `tools/moltenvk/README.md` for current
behavior and the remaining independent-queue limitation.

## Ownership And Synchronization

The standalone owns its window and swapchain. Its persistent presentation
completion timeline permits several submissions in flight, waiting when a
resource needs to be reused. It also waits for swapchain availability; it is
not a wait-free path.

The core consumes the same guest-output mailbox, blits the selected image into
a frontend texture and gives that texture to RetroArch. This is a GPU-to-GPU
format conversion on the shared Vulkan device, not a final-image CPU readback.
RetroArch owns window composition, the swapchain and display pacing. Guest
vblank remains driven by `retro_run`; the declared audio rate and frontend VSync settings are retained.

The core now keeps command pools, command buffers, completion indices and
source-image references per frontend sync slot. It waits for the frontend's
previous use of a slot before reusing its texture, and for its own previous
submission before resetting that slot's commands. Successful submissions signal
a binary semaphore, passed to `set_image` for RetroArch to wait on the GPU.
Source images remain alive until their blit completes. Missing output uses a
duplicate-frame callback without resubmitting a consumed semaphore.

Completion semaphores belong to frontend frame resources, rather than to one
emulator instance, so a reset does not destroy a semaphore still being consumed
by RetroArch. Presenter shutdown drains immediately submitted core blits through
upstream's completion timeline before freeing their commands and source images.
It adds no wait on a signal that a future frontend frame must submit.

## Shared-Queue MoltenVK Compatibility

On the tested Apple M4, Xenia and RetroArch share a graphics queue. RetroArch
9be7ec92 holds its queue lock around `vkQueuePresentKHR`. MoltenVK defaults to
processing queue calls on their calling thread. Display pacing inside that call
can therefore hold the lock needed by Xenia's guest GPU submissions.

Removing CPU completion of the core blit alone regressed the test severely.
The core consequently retains CPU completion on a macOS shared queue. An
earlier guard queried the loaded driver's host-submission mode and enabled
asynchronous image handoff when that mode was asynchronous. Later testing with
the installed official MoltenVK 1.4.2 framework exposed access to a freed Metal
drawable during presentation. The current compatibility guard therefore keeps
CPU completion in both modes. The current core separately selects host
submission policy through `VK_EXT_layer_settings` during Vulkan negotiation v2.
It selects asynchronous submission only when a version-1 drawable-fix marker
belongs to the same loaded library as the frontend's MoltenVK provider;
otherwise it selects synchronous compatibility submission and displays a
notification. Neither global driver configuration nor environment variables
are changed. Other platforms and independent frontend queues use asynchronous
image handoff but still require native runtime validation.

This compatibility wait and the GPU semaphore solve different problems: the
wait preserves progress in the blocking-present configuration, while the
semaphore makes image dependencies explicit for the frontend.

## Diagnostic Procedure

Use an isolated RetroArch configuration and writable system/save/cache paths.
Keep VSync enabled. The current core's per-instance layer setting takes
precedence over `MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS`; a process environment
override no longer bypasses its unpatched-driver fallback. Historical raw
submission-mode comparisons require their preserved core artifacts or the
focused Vulkan harness under `tools/moltenvk`. Do not export diagnostic driver
parameters into a shell profile. The core retains CPU completion of shared-queue
blits in either submission mode. The framework deployment is a separate local
installation; updating the core alone does not replace the frontend's driver.

The existing `[run stats]` line remains comparable with earlier results. The
additional `[Vulkan stats]` line separates frontend slot waiting, the complete
blit operation (including CPU completion in compatibility mode), and frontend
handoff. The earlier label "frame capture" includes the frontend video callback;
it must not be interpreted as the cost of copying the image alone.

## Local Evidence

Tests use Daytona USA, upstream eb31a60, ARM64 Release/LTO, RetroArch 1.22.2
9be7ec92, MoltenVK 1.3.0 and frontend VSync enabled unless explicitly stated.
Guest rendering remains 1280x720; the frontend drawable remains 2560x1440.
The measured checkpoint is creation of guest tid 0000001B at entry 82195C50,
observed in one-second log sampling. It is not a gameplay FPS measurement.

Earlier results remain valid, including the revision-matched 8dc77b0
core/standalone comparison and the eb31a60 core's 76.5-second checkpoint.
No earlier binary, test log or media file is replaced by this investigation.

The first unguarded asynchronous build did not reach the checkpoint in 120
seconds. Its 5–55-second timing windows show median slot wait 0.000 ms, blit
submission 0.042 ms and frontend handoff 16.597 ms. These measurements move
the investigation to the frontend callback and shared queue; they do not
identify every internal driver wait individually.

With asynchronous MoltenVK host submissions, that experimental build reached
the checkpoint in 18.138 seconds. A control using the preserved prior core with
the same driver parameter reached it in 18.123 seconds too. Both show temporary
roughly 30–38/s frontend/vblank windows during the intro, then return to about
60/s. Thus the checkpoint improvement belongs primarily to the driver mode;
the patch separately reduces CPU time spent in the video handoff.

| Build And Driver Mode | Checkpoint | Median Video Path, Windows 5–55 | Exit |
| --- | --- | --- | --- |
| Preserved eb31a60 core, default driver | 76.480 s | 16.63 ms | 0 |
| Unguarded asynchronous experiment, default driver | Not reached in 120 s | 16.64 ms | 0 |
| Preserved eb31a60 core, asynchronous host submissions | 18.123 s | 16.63 ms | 0 |
| Final guarded build, default driver | 77.604 s | 16.64 ms | 0 |
| Final guarded build, asynchronous host submissions | 18.137 s | 0.01 ms | 0 |

The final asynchronous run has median slot wait 0.000 ms, blit operation
0.003 ms and frontend callback 0.005 ms in those windows. This measures CPU
time inside `retro_run`, not GPU render time, total display latency or race FPS.
Its median frontend, guest-swap and guest-vblank rates are about 59.8/s over
the selected windows and the last ten windows. Startup counters include a
one-second guest-vblank peak of 100/s; earlier normal-core tests also had startup
spikes. Steady-state rates do not establish strict timing correctness throughout
startup. These are single observations, not a statistical performance campaign.

Detailed final-build results, artifact hashes, commands, isolated configurations,
screenshots and lifecycle observations are in `.local/async-presentation/` and
the individually named runs under `.local/comparison/`. These local evidence
directories are not release packages. Controlled racing, physical controllers,
audible output and other-platform validation are separate requirements.

## Lifecycle Results And Release Limits

The final build with default MoltenVK 1.3.0 passes native **Command > Reset**,
resumes rendering the game's intro, then passes **Quick Menu > Close Content**
and frontend menu exit. Both emulator instances complete teardown and the
process exits 0. The run is `guarded-default-ui`, excluded from performance
statistics. UI screenshots were observed through CUA; separate PNG files of
those menu observations were not saved.

The faster driver mode is not release-validated:

- A separate interactive run with MoltenVK 1.3.0 terminates with SIGTRAP in
  `MVKPresentableSwapchainImage::addPresentedHandler` during native-window
  inspection. The crash stack identifies the loaded driver; it does not alone
  establish the root cause or prove that the handoff patch introduced it.
- The existing process-only MoltenVK 1.4.2 override avoids that immediate
  failure, but native reset later stalls in
  `cocoa_vk_gfx_ctx_swap_buffers -> MVKSemaphoreImpl::wait`.
  The preserved eb31a60 core without this patch reproduces the same reset
  stall with the same driver override and stack. Both stalled test processes
  were stopped explicitly with SIGTERM, rather than counted as clean exits.
  This override loads an existing core artifact as the driver provider and
  is diagnostic only; it is not an independently packaged driver deployment.
- A UDP-command attempt sent reset/close/quit but produced no observable
  lifecycle events. Its eventual frame-limited exit 0 validates automatic
  shutdown only, not those unobserved commands.

Therefore the performance result identifies a useful driver/presentation lead,
not a generally safe recommendation to change the driver mode. Driver packaging,
interactive stability and startup timing need further work before enabling that
mode by default. The patch never enables it or selects a different driver.

## Installed MoltenVK 1.4.2 Validation

On 23 October 2026, the installed RetroArch was fce35fc7 (1.22.2), with the
official universal MoltenVK 1.4.2 dynamic framework bundled in the app. These
tests use the same preserved guarded ARM64 core and Daytona USA as above,
separate writable storage copied from the existing warm cache, VSync enabled,
1280x720 guest rendering and a 2560x1440 frontend drawable. No loader override
was used. Earlier results and artifacts remain unchanged.

The default driver run exits 0 and retains the slowdown: median CPU video
path 16.64 ms in windows 5–55, split into 1.525 ms blit and 15.110 ms frontend
handoff. The checkpoint is observed at 81.513 seconds from sampling start,
approximately 82.545 seconds from process launch after accounting for the
runner's initial mapping inspection. The earlier guarded result was 77.604
seconds with the old frontend/driver. Single runs with both frontend and driver
changed establish no performance improvement; they do not isolate a regression
to either component or measure race FPS.

A separate default-driver UI run passes native Command > Reset, resumed intro
rendering, Quick Menu > Close Content with confirmation, and native application
quit (exit 0). Both emulator lifetimes finish teardown. UI images were observed
through CUA; separate PNG files were not saved.

With child-only `MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS=0`, the guarded candidate
instead crashes twice before reset, after approximately 2 and 14 seconds from
launch. Both reports show SIGSEGV in `objc_msgSend`, called by the scheduled
handler in `MVKPresentableSwapchainImage::presentCAMetalDrawable`, in the
installed 1.4.2 framework. Neither run supplies a valid performance result or
an asynchronous reset result.

The preserved prior eb31a60 core, which completes its blit on the CPU, passes
the same 60-second asynchronous-driver control and exits 0. Its checkpoint is
about 17.146 seconds from launch; its median CPU video path remains 16.63 ms.
This narrows suspicion to an interaction involving asynchronous frame handoff
and presentation lifetime. It does not prove a specific core defect or a
standalone upstream defect. The next implementation investigation should trace
image/semaphore lifetime and frontend swapchain callbacks against this control
before enabling asynchronous mode. No asynchronous driver setting is installed.

Detailed logs, loaded-library maps, hashes, crash reports and timing-origin
notes are in `.local/mvk142-validation/REPORT.md` and the named
`.local/comparison/mvk142-*` runs. Controlled racing, physical input and audible
output were not revalidated. No standalone build was made.

## Confirmed Drawable Lifetime Failure And Mitigation

Further isolation on the same installed frontend/framework reproduced the
failure after replacing the separate blit submission and binary semaphore with
Libretro `set_command_buffers`. That experimental variant is rejected and its
source is restored; it did not fix presentation and is not the current core.

A diagnostic run of the preserved guarded core with child-only
`NSZombieEnabled=YES` reports a message to a deallocated `CAMetalDrawable` when
calling `addPresentedHandler:`. Disassembly of the installed framework places
the earlier crash return address immediately after that same Objective-C call.
This confirms a drawable use-after-free in the driver's presentation callback,
rather than proving corruption of the core's output texture or semaphore.

MoltenVK [issue #2791](https://github.com/KhronosGroup/MoltenVK/issues/2791)
reports a compatible callback failure and drawable lifetime race in 1.4.2.
That report uses different hardware and present mode; the precise local
release interleaving is not established by matching symptoms alone. No driver
patch from the issue is installed or built here.

The current core consequently keeps CPU completion of the blit on macOS shared
queues in both host-submission modes. It no longer treats an asynchronous
driver configuration as proof that asynchronous image handoff is safe, and no
longer needs the private MoltenVK configuration query. Per-slot resources,
retained sources, completion timelines and GPU handoff semaphores remain.
Other platforms and independent frontend queues retain their existing behavior.

The mitigation artifact, SHA256
`70beb8436e1c7318eef285010249447608507f5b8ee06ec368cd28a73da613fe`,
passes a 60-second frame-limited asynchronous-driver run and exits 0. The intro
checkpoint is observed at 18.163 seconds from process launch, with about 59.8/s
median frontend/swaps/vblanks in windows 5–55. The median CPU video path is
16.63 ms: the wait is deliberately retained. This preserves the earlier driver
mode's intro-speed benefit; it is not a new patch-only speedup or race FPS.
A default-driver 20-second startup/shutdown regression also exits 0; it is too
short for the slow checkpoint and does not repeat lifecycle validation.

The separate native reset test still fails with asynchronous host submissions.
The old emulator completes teardown and the new one launches, but the frontend
then stalls in `vulkan_acquire_next_image -> vkWaitForFences ->
MVKSemaphoreImpl::wait`. Its stack is captured and the owning test is explicitly
stopped with SIGTERM. Reset, close content and clean interactive exit therefore
remain unvalidated in that mode. The default-driver lifecycle results recorded
above remain valid for their original binary.

This is a compatibility mitigation for the initial crash, not a fix of the
underlying driver or the reset stall. Asynchronous host submissions remain
process-only diagnostics. Before deployment of that mode, investigate drawable
lifetime in the driver and frontend swapchain-fence progress across reset.
The installed framework and user configuration are unchanged.

See `.local/frontend-blit/REPORT.md` for artifact identities, rejected source,
diagnostic logs, the zombie result, stack sample and validation limits.

## Source References

- Core handoff: `libretro/libretro.cpp`, `libretro/libretro_vk_presenter.cc`.
- Guest-output blit and persistent completion: `src/xenia/ui/vulkan/vulkan_presenter.{h,cc}`.
- RetroArch revision used by the tests: [Vulkan driver](https://github.com/libretro/RetroArch/blob/9be7ec92/gfx/drivers/vulkan.c) and [presentation helper](https://github.com/libretro/RetroArch/blob/9be7ec92/gfx/common/vulkan_common.c).
- Driver parameter contract: `third_party/MoltenVK/Docs/MoltenVK_Configuration_Parameters.md`, `MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS`.


## Reset Acquisition Fence Confirmation

The follow-up on 23 October maps the installed frontend's sampled
`vulkan_acquire_next_image +580` to its temporary WSI acquisition fence,
not its frame-rendering fence. In a targeted child-only asynchronous-driver
run with the current CPU-completed core, native pause/resume recovered
approximately 60 frames/swaps/vblanks per second. Native reset then reproduced
the same acquisition wait after relaunch; the process was sampled and
explicitly terminated (exit -15). This is not a lifecycle pass or benchmark.

RetroArch fce35fc7 already retires its own submissions and invalidates cached
core GPU references before reset. The next diagnostic must correlate acquired
swapchain images and fences with present submissions and Metal callback
completion. The stack identifies the waiting fence, but does not establish
whether the cause is frontend bookkeeping or driver signaling, nor whether
it shares the confirmed drawable lifetime failure's cause. No core change
or new public frontend interface is justified by this evidence alone.
See `.local/reset-fence/REPORT.md`, source hashes and disassembly.


## WSI And Drawable Callback Trace

Two subsequent isolated runs reproduce the reset stall with Vulkan API tracing.
RetroArch submits presentations for swapchain images 0, 1 and 2 with successful
return codes, then waits on the acquisition fence for image 0. A second trace
observes Metal callback registration and execution: one post-reset drawable
callback never arrives during approximately 55 seconds before task-owned
termination, while later drawable callbacks do arrive. These are failed reset
tests (exit -15), excluded from benchmarks.

The exact MoltenVK 1.4.2 source signals queued acquisition fences from the
drawable callback, whereas its presentation-extension fence already has a
command-buffer-completion path. The missing callback is therefore a concrete
candidate mechanism. The trace does not expose its internal signaler/fence
association, and earlier missing callbacks did not immediately stall the run;
root cause and a safe fix are not yet proven. Next, instrument that internal
association and command-buffer completion in an isolated driver. Keep exactly-once
signaling and delayed-callback resource lifetime intact.

No new core/frontend interface or production change is introduced. The diagnostic
shim is child-process-only; installed app, driver and user configuration are
unchanged. Full evidence and limitations: `.local/wsi-trace/REPORT.md`.


## Direct Fence Correlation And Experimental Driver Fix

The next diagnostic on the checksum-verified official 1.4.2 binary directly
reads the captured acquisition fence from the driver's drawable callback.
It exactly matches RetroArch's pending fence; the associated presentation
command buffer completes without error, but that drawable callback never
executes before cleanup. This establishes the blocking dependency for the
observed reset, without explaining why the callback is omitted. Evidence:
`.local/wsi-signaler/REPORT.md`.

A local driver candidate moves acquisition-fence signaling and its tracked
reference to command-buffer completion, clearing the drawable callback's
fence to prevent a delayed second signal/release. One asynchronous-mode
reset, visible intro restart, content close and native quit pass (exit 0).
The paired unmodified local driver crashes during startup in the previously
problematic presentation callback, so a complete matched reset comparison
and stability validation remain outstanding.

This pair uses the existing project MoltenVK revision e9b7bd2 and its archived
dependencies, not the official packaged build. Only a copied source/object
and local driver artifacts are changed. Installed driver, core and user
configuration remain unchanged. The separate drawable lifetime problem is
not claimed fixed. Full build, patch and evidence: `.local/mvk-acquire-fix/REPORT.md`.

## Missing Callback Research And Fix Constraints

Upstream history provides a specific precedent for the observed hang:
[9f64faad](https://github.com/KhronosGroup/MoltenVK/commit/9f64faadbcf490e73e69db8bc3e10154e61f17e5)
documents a Metal regression that withholds the final one to three drawable
callbacks. [f0cb31a1](https://github.com/KhronosGroup/MoltenVK/commit/f0cb31a12b59f05177f07ab5a46bc9084ba5fbc9)
replaces an extra-drawable workaround with a layer-size change on swapchain
replacement/destruction. The inspected source still includes that workaround,
but leaves acquisition-fence signaling dependent on the drawable callback.

Read-only reanalysis of `wsi-signaler-reset` finds all three final drawable
callbacks absent while their command buffers complete without errors. This
supports a presentation-tail callback stall as the leading explanation, without
proving the same internal Apple defect. This particular run's final acquisition
returns index 2; the earlier index-0 observations belong to different runs.
Three earlier callbacks are also absent without immediately blocking execution.

The next discriminating test should exercise the existing frontend-owned
resize/recreation drain while tracing the exact pending callback and fence,
including drawable IDs and registration/present order. Separately validate
drawable ownership and early callback registration; issue 2791's proposed
call chain does not exactly match the inspected 1.4.2 source.

The fence-only candidate's lifecycle pass remains valid, but does not prove
Vulkan image-reuse safety: command completion and display/presentation completion
are distinct. Adoption requires proving safe backing-drawable reuse and resolving
references/bookkeeping retained by absent or late callbacks. No new runtime test,
build or installed change is part of this research. Full source references,
evidence and experiment design: `.local/mvk-callback-research/REPORT.md`.

## Controlled Layer Drain Results

Two isolated official-driver runs reproduce the native-reset wait with the
current core. A diagnostic main-thread layer-size pulse (2560x1440 to 1x1 and
back) does not deliver the pending drawable callbacks or release the fence.
The second run separates the mutations into flushed transactions 500 ms apart;
it also remains blocked. Both processes are intentionally stopped (exit -15).
Native resize is unverified because the stalled app does not answer UI queries.
This is not full swapchain retirement/recreation, so it does not falsify the
upstream lifecycle workaround in that context.

Public drawable IDs reveal an acquired generation with no registered present
handler immediately before the three stalled generations in both runs. A pointer
is reused across successive generations. The next driver experiment should map
ownership and rendering-texture use across that replacement, then isolate
synchronized retention and early handler registration. A premature release or
incorrect texture/present pairing is a hypothesis, not yet a proven cause.

At the diagnostic pulse, the native window reports at least partial visibility.
Installed files, user configuration, core artifact and driver source remain
unchanged. No performance result or production fix is claimed. Full methodology,
negative results and trace identities: `.local/wsi-drain/REPORT.md`.

## Drawable Ownership And Queue Ordering

A matched pair of locally built, source-instrumented MoltenVK drivers now
isolates a concrete ordering defect. In the control, main-thread image
acquisition releases drawable ID 2103 between texture lookup and presentation
capture on the submission queue. The pointer is recycled as ID 2104 before
presentation; its GPU command buffer completes, but the final three drawable
callbacks do not arrive and native reset stalls. Four earlier generations are
also captured for presentation twice. The texture pointer is unchanged across
the final recycle, so this proves generation/ownership replacement, not a
different render target or visible pixel corruption.

The separate ownership candidate retains the captured drawable and image,
then detaches the image's drawable slot in the queue-ordered presentation path.
Acquisition no longer releases that slot. Original acquisition-fence signaling
and scheduled-handler callback registration are retained. This is independent
of the earlier fence-completion experiment.

Three native resets pass across two candidate sessions. One session also closes
content to the visible No Core menu and exits through native Quit with code 0.
The other ends at its watchdog with the close confirmation still open, so it
counts only as a two-reset pass. Across 21,817 captured presentations, neither
candidate trace contains a pre-capture release or repeated presentation of a
drawable generation. Every logged presentation GPU completion succeeds.

The final three callbacks remain pending in each trace at process termination;
these short tails do not establish another prolonged stall or prove leak-free
retirement. Instrumentation affects timing, and the local driver differs from
the official package. Next, validate an uninstrumented candidate and audit
readback/screenshots, explicit image release, swapchain recreation and other
queue/lifetime paths. RetroArch fce35fc7 records its readback before presentation,
which is favorable, but that observation alone is not runtime compatibility
evidence. No production change is deployed and no new performance claim is made.
Full builds, interleaving, results and limitations:
`.local/mvk-ownership/REPORT.md`.

## Validation Without Ownership Tracing

The same ownership-order patch, rebuilt without instrumentation, passes native
reset, window resize/swapchain recreation, two GPU screenshots, content close
and native Quit in both default and asynchronous submission modes. Both runs
exit 0. The four saved screenshots were visually inspected; dimensions change
from 2560x1440 to 2940x1654 after resize, with intact title/intro content.

A separate 3,600-frontend-frame asynchronous run exits 0 with complete teardown
and a valid title screenshot. Its intro checkpoint is 17.137 s, versus the
earlier official-driver asynchronous reference's 18.163 s. Both have roughly
59.8/s median frontend/guest swaps/vblanks and 16.63 ms median CPU video time.
The one-second checkpoint difference is at the polling granularity; the result
establishes retention of the faster mode, not an additional speedup. Earlier
performance evidence remains valid. Audio underruns remain in both logs and
audible continuity is not established.

These bounded lifecycle/readback checks now pass without trace timing effects.
Final-callback retirement, explicit image release, multiple queues, recording
and general driver compatibility remain open. The clean patch and binary stay
local; the installed framework and global mode are unchanged. Full build,
screenshots, results and preservation evidence:
`.local/mvk-ownership-clean/REPORT.md`.
## Follow-Up Audit And Audio Interaction

The 23 October source audit confirms that the ownership-order candidate still
depends on a separate presentation callback to release each presentation's image
retain and acquisition signaler. GPU completion and clean process exit alone do
not prove final-callback retirement. Explicit image release/reacquisition and
independent CPU submission queues remain outside the exercised RetroArch path;
the review is in `.local/audio-investigation/ownership-audit.md`, including the
relevant Vulkan specification boundaries.

Audio telemetry now distinguishes source shortage from insufficient frontend
cadence. The asynchronous intro's slow windows retain ~27–29 ms video time even
with frontend VSync disabled. Complete audio blocks fix the delivery contract
but leave whole-session device underruns largely unchanged. The next focused
profile should cover that intro interval and distinguish blit submission from
completion waiting. See `AUDIO_DIAGNOSTICS.md`; the prior presentation and
performance evidence remains valid.

## Installed Driver And Automatic Compatibility Fallback

The 24 October integration changes three distinct components:

- **Core:** Vulkan negotiation v2 creates the frontend-owned instance through
  RetroArch's wrapper. The core recognizes version 1 of the local drawable-fix
  marker only in the provider selected by the frontend. It uses instance-local
  layer settings to select asynchronous host submission with the recognized
  patch, or synchronous compatibility submission without it. The fallback
  sends one on-screen notice and logs the provider and policy. Shared-queue CPU
  completion stays enabled. Global configuration and environment are unchanged.
- **MoltenVK:** The minimal drawable ownership change is built separately. Both
  the project revision reporting 1.4.2 (`e9b7bd2`) and exact 1.3.0 (`49b97f26`)
  pass the exercised shared-queue checks. Version 1.3.0 additionally needs an
  SDK-only declaration guard when built with Metal 26. The capability marker
  is separate from the reviewable bug-fix diff.
- **RetroArch:** The local app receives the signed ARM64 1.4.2 candidate
  framework, with the complete official framework preserved. The frontend
  executable and user configuration remain byte-identical. The installed
  driver's global synchronous default remains enabled.

The installed rolling core is SHA-256
`f558c7ade336f05cdf25744af6cfd7ef8b6626c8cf21ad1d28a09f80142460b8`.
The installed signed driver is SHA-256
`7ca4b0c2d64359945155262a2a36028061654b1547ba3025f523605c9589bdf0`.
An ordinary isolated launch without driver or submission overrides loads this
framework from RetroArch's app, reaches the Daytona title and exits 0 after
3,600 frontend frames in 67.574 wall seconds. Median frontend/swaps/vblanks rate
is 59.804/s, median CPU video time 16.63 ms, and the sampled intro checkpoint is
19.175 s from process launch. Earlier timing results remain valid; differences
between these observations are not a newly claimed patch-only speedup.

The exact 1.3.0 candidate passes two native menu resets, native window resize,
GPU screenshots, content close and quit. A separate final-core recording run
produces 1,796 H.264 video frames without frontend recording drops and a stereo
48 kHz FLAC stream. The final installed core also passes original 1.3.0 and
1.4.2 fallback tests with the notice, including child-only asynchronous
environment overrides. The per-instance synchronous selection takes precedence.

The focused Vulkan harness exercises explicit image release/reacquisition,
readback and four swapchain lifetimes. A counter-only 1.4.2 candidate completes
240/240 presentation pairs, 240 GPU callbacks and 12/12 image destructions.
Those counters are absent from the installed driver. This establishes retirement
for that bounded scenario, rather than for every workload.

Asynchronous rendering and presentation on independent queues still time out.
Original drivers and a same-source original control also fail asynchronous
focused cases; patched synchronous multi-queue cases pass. The shared submission
queue used by the local core is the supported tested path. Resolve or discuss
the broader ordering issue before a general upstream driver submission.
The installed performance run still reports 417 whole-session audio shortages;
this work does not claim to repair the previously identified audio starvation.

Full artifact identities, test matrix, original-framework backup, deployment
and verification records are in `.local/mvk-deployment/REPORT.md`. Maintained
source preparation, the local driver build recipe and the native test are in
`tools/moltenvk`. No public driver release or upstream PR is created here.

## Independent-Queue Harness Audit

The 24 October follow-up adds explicit fences for every presentation, waited
only when retiring a swapchain, enables the advertised portability subset, and
checks maintenance1 feature support. The normal frame loop adds no CPU render
wait. Per-image semaphore reuse remains gated by acquisition-fence completion.
Preservation failures and unmatched diagnostic lifetime counters now fail the
test instead of merely appearing in its result.

With this corrected harness, patched 1.4.2 and 1.3.0 shared-queue workloads pass
240 frames, 244 readbacks and four swapchains. The counter-only 1.4.2 candidate
also retires 240/240 presentations and 12/12 images. The same-source original
1.4.2 control crashes; the official 1.3.0 asynchronous shared-queue case also
crashes. An official 1.4.2 shared-queue run passes, illustrating the scheduling
sensitivity of the original failure rather than a deterministic crash in every
original-driver run.

Independent asynchronous queues fail with original and candidate drivers. New
observations include incorrect readbacks and, in one preliminary variant,
invalid-resource device loss, as well as fence timeouts. Removing explicit
image-release subtests does not remove the failures. Sampled stacks show both
queue workers inside `CAMetalLayer.nextDrawable`. Candidate multi-queue tests
pass when CPU rendering completes before presentation; the 1.4.2 CPU-callback
semaphore control also passes. These controls support investigating CPU-side
drawable/encoding ordering; they do not establish identical root causes or
prove independent-queue non-regression.

The related [upstream report #2791](https://github.com/KhronosGroup/MoltenVK/issues/2791)
discusses concurrent drawable access on different hardware. The local
`tools/moltenvk/UPSTREAM_REVIEW.md` separates this external report, our observed
results and remaining hypotheses. Validation layers were unavailable locally.
The driver source change remains byte-identical to the installed/tested
candidate, and no core or frontend binary changes in this audit. Existing
performance and RetroArch lifecycle evidence retains its original provenance.
Raw commands, hashes, logs and sampled stacks are in `.local/mvk-queue-audit`.

## Observed Independent-Queue Mechanisms

The subsequent 24 October source/trace investigation separates two failures.
Concurrent `getCAMetalDrawable()` calls publish different drawables into one
logical image slot; the same render submission then reads two texture identities.
This occurs in matched original and candidate traces even with a fresh binary
semaphore for every presentation, with no stale event target reuse in those
controls. The shared-queue control retains stable texture identity.

Separately, `MVKSemaphoreMTLEvent` increments its event counter during wait
encoding and reads it during signal encoding. If separate CPU workers encode
the wait first, the producer signals the next value; that value can satisfy the
following round's wait before its producer executes. A surface-free two-queue
buffer-copy test reads stale counters in 31/32 rounds on official 1.4.2 and
1.3.0. Fresh semaphores, synchronous submissions and the 1.4.2 callback-semaphore
control pass. Detailed traces corroborate completed previous signals reused as
later waits and consumers completing before their current producers.

The native tests and trace analyzer are maintained in `tools/moltenvk`. Detailed
scope, source references and design invariants are in
`tools/moltenvk/QUEUE_ORDER_FINDINGS.md`; raw evidence is in
`.local/mvk-queue-order`. This is localization, not a new general driver fix.
No experimental driver is installed, and the validated core/driver and earlier
performance artifacts remain unchanged.


## Independent Queue Correction Candidate — 24 October 2026

A separate MoltenVK candidate now reserves matching binary-event tokens before
CPU worker dispatch, coordinates presentation with producer encoding and
protects drawable publication/lifetime. The local independent-queue reproducer
passes on the pinned 1.4.2 and 1.3.0 sources. Source-matched controls preserve
the previous failures. The core and its shared-queue CPU completion guard are
unchanged; no new performance improvement is inferred. See
[Independent Queue Correction](tools/moltenvk/INDEPENDENT_QUEUE_FIX.md) and
`.local/mvk-binary-token` for exact revisions, validation and remaining limits.
