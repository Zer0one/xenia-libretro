# MoltenVK Integration Roadmap

Updated: 25 October 2026. This track concerns MoltenVK only. Core lifecycle,
audio, standalone builds and alternative graphics providers belong to their
respective project tracks.

## Scope And Completion Criteria

The final objective is a reviewable PR to MoltenVK correcting the synchronization
and drawable-lifetime defects affecting Xenia presentation in RetroArch. Local
validation is a milestone toward that PR, not completion of the overall goal.
Prefer a reusable driver correction over a Xenia-specific workaround, while
keeping validation bounded.
General Vulkan conformance is not an acceptance requirement for this activity.

Remaining local work has three parts:

1. Complete focused `vkQueueSubmit2` image-handoff coverage for the same binary
   and timeline dependency mechanisms. This is deliberate generalization of
   the existing reproducer, not a new application or API-wide test campaign.
2. Review the imported/exportable Metal payload boundary for regressions caused
   by this patch. Add a focused check if that review identifies a concrete risk;
   implementing unrelated external interoperability is outside this activity.
3. Run one final 20-minute presentation soak on the final installed candidate
   with the existing Xenia/RetroArch content and isolated writable files.
   Retain the existing defect reproducers as regression evidence; repeat only
   checks affected by a subsequent change or unresolved failure.

Local completion requires the known presentation reproducers to pass, no
unresolved regression in the exercised Xenia path, the final soak to complete,
and remaining coverage limits to be documented. Other hardware, actual GPU
fault injection and unrelated MoltenVK defects do not block that conclusion.
Passing tests do not establish universal stability or a performance gain.

After local completion, prepare the minimal patch/reproducer set against a
recorded current upstream revision, with focused validation of any adaptation,
source attribution, test commands and explicit limits. This PR preparation is
part of the agreed objective. Public submission remains subject to authorization.
Maintainer feedback does not retroactively erase local validation.

Keep the agreed scope fixed. If PR preparation, review or a newly found defect
requires broader changes or testing, propose the specific extension, its reason,
acceptance criteria and expected cost to the user before performing that extra
work. Do not expand the scope automatically. The user explicitly authorized continuation beyond the previous usage cap.
Continue reporting shared usage; no replacement numeric cap has been assigned.

| Status | Step | Evidence And Remaining Work |
| --- | --- | --- |
| Local Checks Complete | Synchronization And Lifetime Review | Binary tokens, drawable publication and callback lifetime corrected in the exercised cases. Renderer handoff extends CPU coordination beyond presentation. Fault injection then exposed a configuration-result data race, corrected with a mutex-protected wait/result protocol; TSan, Release 1.4.2/1.3.0 and ASan pass 1,000 races plus both worker aborts. The timeline follow-up now coordinates Vulkan-managed native signals, including future queue and same-host-thread host signals. Threshold retirement and device-loss checks pass under Release, ASan and TSan. External Metal timeline boundary review found no concrete patch-introduced regression; full interoperability remains outside the fixed local acceptance scope. |
| Local Observation Complete | Broader Validation | Both pinned 1.4.2/1.3.0 follow-ups pass local renderer-chain and normal presentation checks with Vulkan synchronization validation. Metal validation, ASan and a 3,600-frame renderer-chain run pass on Apple M4. Timeline image handoff passes on both pinned source versions in synchronous/asynchronous modes with zero Vulkan validation errors/warnings. The signed 1.4.2 timeline framework is installed locally and its default RetroArch loading/visible startup passes. The final installed-driver title-screen observation completes 20 minutes with three checkpoints and completed game teardown. Frontend QUIT did not terminate; the runner used SIGTERM at its deadline. Clean frontend exit is not claimed; its cause remains outside this driver activity. Other hardware remains untested. Earlier long runs belong to their preserved exact candidates. |
| Prepared Locally | Upstream Preparation And Review | Patch applies to main at `5189f8d` (1.4.3 development), builds with exact dependency pins and passes focused graphics/protocol checks. Same-revision original async controls reproduce black readback; the synchronous control passes. Eight-file driver patch, tested standalone reproducers, draft description and limits are prepared under `.local/mvk-pr-readiness/pr`. Contributor review, authorization and upstream submission/review remain pending. See [PR Preparation](PR_READINESS.md). |

The current gate covers native binary dependencies and the exercised Vulkan-managed
native timeline image handoffs. Imported/exportable Metal timeline payloads skip
the additional timeline CPU coordination. The agreed focused API 2 graphics-path coverage is complete. Boundary review
found no concrete regression introduced for external Metal timeline payloads;
full external interoperability and other hardware remain declared limits.
Upstream maintainer review remains pending.
No additional performance gain is claimed.

Implementation, source pins and limits: [Independent Queue Correction](INDEPENDENT_QUEUE_FIX.md).
Evidence: `.local/mvk-binary-token` and `.local/mvk-followup`.

Device-loss correction and limits: [CPU Encoding Wait Validation](DEVICE_LOSS_VALIDATION.md).
Timeline follow-up and latest deployment: [Timeline Image Handoff](TIMELINE_HANDOFF.md),
`.local/mvk-timeline`. Device-loss results remain in `.local/mvk-device-loss`.

Final observation and upstream package: [PR Preparation](PR_READINESS.md),
`.local/mvk-pr-readiness`. The fixed local presentation checks are concluded;
contributor review, publication authorization and upstream maintainer review
remain. This is not a claim that the patch is already accepted or merge-ready.


## Acquisition-Fence Follow-Up

The separately authorized acquisition-fence investigation also covers Xemu
and RPCS3. It does not replace the preserved main-path validation above.

| Status | Bounded Step | Evidence And Remaining Work |
| --- | --- | --- |
| Complete | Discriminating Public Vulkan Reproducer | Wait/reset of an acquisition fence followed by one presentation reproduces stale re-signaling in the pinned upstream-behavior control (2/3) and original Xemu prototype (3/3). The revision-2 candidate passes (0/3), with zero API/sync validation errors/warnings. |
| Complete | One Native Vulkan Control | Batocera 43.1, Radeon Vega 11, RADV Mesa 25.3.6: separate render/present queue families, 0/3 stale signals, 3/3 pixel readbacks, zero API/sync validation errors/warnings, exit 0. This is a fence-correctness control, not a cross-hardware performance comparison. No further native test campaign is required by this step. |
| Partially Complete | Bounded Application Compatibility | Xemu's single retained session completes at approximately 60 updated images/s. RPCS3 closes normally but does not confirm the planned 3D scene or pause/resume; visual acceptance remains unresolved. Preserve that result rather than automatically expanding the campaign. |
| Ready For Review; Installed For User Tests | Incorporate Follow-Up Into Upstream Review | The combined patch and three-part series apply to pinned upstream 5189f8d (1.4.3 development). A fresh complete build passes 483 readbacks with Vulkan API/sync and Metal API Validation, zero reported errors/warnings and 0/3 stale fence signals. Immediate acquisition correctness and deferred completion timing are separated for review. The signed final framework is installed in local RetroArch, with actual loading and normal menu exit verified; core/configuration unchanged. No additional backup was retained at the user’s request. Public submission and maintainer review remain pending. |

Evidence and exact candidate hashes: `.local/mvk-acquire-review/REPORT.md`,
`.local/mvk-acquire-review/reuse-proof/summary.json`, and
`.local/mvk-acquire-review/native/result.json`.


Final build, validation, installation receipt and project notifications:
`.local/mvk-acquire-final/REPORT.md`. Signed installed driver SHA-256:
`f23771e0ae32a0a5d2e3652f471cdbbed3f85d8edad92cbc098defbd27ee82c1`.
The previous Xemu environment switch is no longer required; global synchronous
submission remains unchanged. Xemu and RPCS3 chats were explicitly informed;
no additional application campaign was requested. Their previously recorded
application limits remain in force.
