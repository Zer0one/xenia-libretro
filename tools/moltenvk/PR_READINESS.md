# MoltenVK PR Preparation

24 October 2026. Scope fixed in [MoltenVK Roadmap](ROADMAP.md).

## Later Follow-Ups

This document records the 24 October preparation and exact driver/session results. The later acquisition follow-up is now installed as 1.4.3 development; see [Roadmap](ROADMAP.md). The historical 20-minute QUIT result below remains unchanged, while [Core Lifecycle](../../CORE_LIFECYCLE.md) records its confirmation-setting explanation and the separate corrected native Quit path. Publishing this fork's core release does not submit a MoltenVK PR or accept contribution requirements on the user's behalf.

## Completed Checks

The presentation harness now routes the same image commands through either
`vkQueueSubmit` or `vkQueueSubmit2` using `--submit2`. The API 2 route enables
`synchronization2`, uses explicit semaphore values and signal/wait stages, and
returns its selection in the result. The queue/host signaling scenarios,
readback barriers, presentation binary semaphore and validation remain the same.

Both previously tested source versions (1.4.2/1.3.0) pass binary and timeline
image chains in synchronous/asynchronous modes: eight cases, 1,920 frames and
matching readbacks, zero Vulkan validation errors or warnings. This completes
the agreed focused API 2 coverage; it is not API-wide conformance.

Review of the external Metal timeline boundary found no concrete regression
introduced by the timeline overlay. Imported/exportable payloads allocate no
extra CPU threshold state and retain native Metal event operations. The added
state-retirement helper sees an empty map for these payloads. Device-loss checks
and GPU waits remain. Existing private tests cover exportable exclusion; no
complete external interoperability claim or additional implementation is made.

## Current Upstream Target

The PR target is main at `5189f8de86ec365860f63bf1da736815cfaea5cd`,
which reports 1.4.3 development. It is 118 commits ahead of the earlier 1.4.2
source. Source transforms apply unchanged; the four native semaphore/queue files
and the rewritten drawable getter/release bodies are identical across the two
original revisions. Other upstream changes are retained. Dependencies match
this revision's own pins and remain local.

The corrected current-main driver builds and passes five focused graphics cases
(four API 2 combinations and one legacy timeline case): 1,200 frames/readbacks
with zero Vulkan validation errors/warnings. Its internal timeline protocol
passes 100 rounds/800 waits/400 state retirements; its device-loss protocol
passes 500 races, 16 confirmed waiters and both worker aborts. Sanitizers were
previously exercised on the pinned 1.4.2 candidate; those results are not
relabeled as sanitizer tests of the current-main build.

At the same current-main revision, original driver logic fails both asynchronous
API 2 image chains with black readback and zero Vulkan validation errors or
warnings. Its synchronous timeline control passes 240 frames/readbacks. The
control and candidate share pinned dependency archives and compiler settings.
Only the candidate applies the driver corrections.

The local PR package is `.local/mvk-pr-readiness/pr`: a patch touching eight
driver files, exact hashes, a draft description, standalone tested reproducers
and validation/limitation notes. The patch passes `git apply --check` against
the fixed target. Local marker, SDK compatibility preparation, Xenia, RetroArch
and frontend settings are excluded. No branch, commit, push or public PR has
been created.

The local RetroArch installation remains the signed corrected 1.4.2 driver.
The current-main PR build is a separate validation artifact. The single final
20-minute frontend session is recorded under
`.local/comparison/mvk-pr-final-soak`; its completed observation and frontend-exit limitation are detailed below. It is a stability observation rather
than interactive gameplay or a new performance baseline.

## Sources And Contribution Review

The test follows the Khronos definitions of
[VkSubmitInfo2](https://docs.vulkan.org/refpages/latest/refpages/source/VkSubmitInfo2.html),
[VkSemaphoreSubmitInfo](https://docs.vulkan.org/refpages/latest/refpages/source/VkSemaphoreSubmitInfo.html)
and [Metal shared-event import](https://docs.vulkan.org/refpages/latest/refpages/source/VkImportMetalSharedEventInfoEXT.html).
The upstream [contribution requirements](https://github.com/KhronosGroup/MoltenVK/blob/5189f8de86ec365860f63bf1da736815cfaea5cd/CONTRIBUTING.md)
require a contributor CLA and human review/ownership representations for
AI-assisted work. The package discloses AI assistance; no acceptance or
representation is made on the user's behalf. Public submission still requires
authorization and contributor review.

## Final Installed-Driver Session

The single planned 20-minute observation completed: final screenshot at
1200.611 s, last logged guest frame 71,748, three checkpoints at approximately
2/10/20 minutes. Captures show the title screen at different animation phases;
diagnostic frame/swap counts continue to advance. No presentation fault was
identified during the observation. This is no-input title-screen stability,
not interactive gameplay or a performance baseline. It exercises the signed
installed 1.4.2 driver, not the separate current-main PR build.

CLOSE_CONTENT was sent at 1202.621 s; Xenia logs completed teardown. The frontend
also reports a context-destroy/restart warning during content closing. QUIT at
1206.679 s did not terminate RetroArch; the runner used SIGTERM at 1240.285 s
(exit -15). An extra exit request was logged near the deadline; its delivery
before termination is unconfirmed. Clean frontend exit is not claimed. The
exit behavior is retained as a separate lifecycle limitation, without attributing
it to MoltenVK or assuming it has the same cause as native Cmd+Q SIGABRT.
No new lifecycle investigation or repeat soak is included in this activity.

Core, matching .info, user config and frontend executable checksums remain
unchanged. RetroArch refreshed its shared core-info cache when returning to
the menu. All checkpoints, logs, per-case identities and cleanup receipts are
retained in `.local/mvk-pr-readiness` and `.local/comparison/mvk-pr-final-soak`.
