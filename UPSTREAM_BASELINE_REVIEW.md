# Libretro Baseline Review

Date: 26 October 2026. Comparison performed after fetching the upstream Libretro
branch without recursive submodule downloads.

## Result

The remote Libretro upstream is still `f23c14c717ef274516f29c9b5e97d6a9db28643d`.
It is the fork's original port base and a complete ancestor of current `main`.
There are no incoming Libretro commits to merge and no new donor API, structure
or format migration to perform. No code reconciliation, history rewrite or
duplicate build is necessary for this comparison.

The comparison identifies ten changed files under `libretro/`. Shared emulator
updates are recorded separately from those port adaptations; the fork's ahead
commit count includes full engine merges and is not a count of custom features.

## Pinned Sources

| Reference | Revision | Engine Revision |
| --- | --- | --- |
| `WizzardSK/xenia-libretro:libretro` | `f23c14c717ef274516f29c9b5e97d6a9db28643d` | `8dc77b0` |
| Fork `main` at comparison | `1b119ddffbae7ecdc3ae4e0d5b7818c08f2dd10f` | `d881a29` |
| Released core `v0.1.0.2` | `8c1259856f1584c0c219b7977df0a271954bd6c8` | `d881a29` |
| Separate standalone reference | `d881a29125978b4eea6bf44f6ed8c33f8aea8c33` | Xenia Edge |

The previously authorized engine update is retained as a local integration
relative to the Libretro donor. Starting from the Libretro reference base does
not require discarding that approved improvement. A proposal to change the
engine revision or remove established fixes would need its own justification
and review.

## Unchanged Frontend Contracts

These files are byte-for-byte identical between the donor and fork:

- `libretro/libretro.h`
- `libretro/libretro_core_options.h`
- `libretro/libretro_core_options_intl.h`
- `libretro/xenia_edge_libretro.info`
- `libretro/libretro_disc.cc`
- `libretro/libretro_disc.h`

No new Core Options schema, translation format, general Libretro header, core
information format or disc-control contract needs reconciling at this revision.

## Local Adaptation Register

| Area | Files | Reason And Disposition | Evidence And Limits |
| --- | --- | --- | --- |
| Audio Delivery | `libretro/libretro.cpp`, `libretro/libretro_audio_driver.cc`, `libretro/libretro_audio_driver.h` | Supply one complete frontend audio block, pad only temporary shortages, reset fractional sample carry and report source supply separately. Keep the demonstrated correction; adapt it if the donor changes the audio API. | `AUDIO_DIAGNOSTICS.md`. Callback delivery was verified; audible continuity during slow presentation remains unresolved. |
| Native Quit Lifetime | `libretro/libretro.cpp` | Register the emulator lifetime before the pause watchdog starts, so native process termination reaches the existing stop/join path before global destruction. Keep the demonstrated fix rather than restoring the known SIGABRT path. | `CORE_LIFECYCLE.md`. Earlier macOS Quit/Cmd+Q/reset/content-close evidence retains its exact binary attribution; cross-platform gameplay teardown is separate. |
| Vulkan Image Handoff | `libretro/libretro.cpp`, `libretro/libretro_vk_presenter.cc`, `libretro/libretro_vk_presenter.h` | Retain resources per frontend sync slot and hand images over with semaphores. Keep the macOS shared-queue CPU completion guard while its removal has no validated replacement. | `VULKAN_PRESENTATION.md`. Driver reproducers and earlier macOS tests do not establish equivalent Windows/Linux runtime behavior or an FPS improvement. |
| Vulkan Negotiation And MoltenVK Policy | `libretro/libretro_vulkan.h`, `libretro/libretro_vk_presenter.cc`, `libretro/libretro_vk_presenter.h`, `libretro/libretro.cpp` | Add the standard frontend Vulkan v2 declarations and select them only when advertised. This enables the authorized per-instance driver policy and original-driver fallback. Replace the local declarations with the donor's equivalent header when available. | Existing negotiated-v2/fallback evidence in `VULKAN_PRESENTATION.md`; this is an extension beyond the donor's v1 header, not a private replacement format. MoltenVK driver changes remain separate. |
| Newer Engine API Adaptation | `libretro/CMakeLists.txt`, `libretro/libretro_audio_driver.cc`, `libretro/libretro_audio_driver.h`, `libretro/libretro_hid.cc`, `libretro/libretro_hid.h`, `libretro/libretro_gamedb.cc` | Follow the integrated engine's mbedTLS dependency, shared audio-driver destruction, title-launch keystroke reset and PII-safe UTF-8 logging. These follow the newer engine APIs rather than preserving the donor engine's old interfaces. | Release `v0.1.0.2` CI/native ABI checks. Do not apply these hunks blindly to the donor's older `8dc77b0` engine. Remove duplicates when the donor adopts equivalent changes. |
| Fork Distribution | `.ci/`, `.github/workflows/`, release documentation | Keep fork-specific rolling publication, provenance, symbols, licenses and desktop-only future release policy separate from an emulator/core behavior PR. | Verified release reports and publication-gate tests. Android exclusion remains in force for subsequent releases. |
| Separate Driver Work | `tools/moltenvk/` and its linked evidence | Keep driver fixes and validation distinct from Libretro port changes and their upstream destination. | Driver-specific roadmap and readiness documents; no new driver build or deployment was performed for this comparison. |

The newer engine's shared-source adaptations and extra `.upstream-excluded`
entries remain part of the existing core-only integration. The baseline port's
own frontend-driven vblank, input mapping, save/content paths and other inherited
features are not presented as new fork improvements.

## Networking

No `SET_NETPACKET_INTERFACE` or `retro_netpacket_callback` registration was found
in either the donor or fork Libretro implementation, excluding definitions in
the general API header. Following the donor therefore does not currently
require adding Netpacket. Native System Link transport validation and a proposed
frontend-managed Netpacket adapter are separate activities.

## Follow-Up For An Upstream PR

Prepare selected improvements as separate, motivated changes against the actual
Libretro donor revision. Keep engine-version adapters, core behavior changes,
fork release tooling and driver work distinguishable. The whole `main` diff is
not a ready-to-submit port patch: the donor still uses an older engine.

The documented audio and lifetime fixes are identifiable review groups. Vulkan
presentation and driver-dependent policy need their documented platform and
runtime limits carried into any proposal. This classification does not declare
a PR ready or authorize creating one.

No new substantive behavior or compatibility choice is required to complete the
baseline comparison. Future proposals to remove fixes, migrate persistent data,
change engine versions or add a different networking model must identify their
consequences for user review. Normal donor API changes remain the default path.

## Verification And Artifacts

Git ancestry, the absence of incoming commits, the ten-file port delta and the
six unchanged contracts were checked against the pinned revisions. Protected
instruction files remain unchanged. No source code, build configuration or
release tag was changed, and no new build or game test was run.

Machine-readable evidence and the port diff are retained under
`.local/libretro-baseline-20261026/`. Existing CI/build/runtime evidence retains
its original attribution; the installed validated `v0.1.0.2` core and matching
information file remain the manual-test artifacts.
