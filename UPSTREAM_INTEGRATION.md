# Upstream Integration Policy

Updated: 26 October 2026. This records the user's integration policy without
changing a published release. The completed [Libretro Baseline Review](UPSTREAM_BASELINE_REVIEW.md)
records the exact revisions, local adaptations and remaining validation work.

## Reference Sources

| Source | Role | Existing Reference |
| --- | --- | --- |
| `WizzardSK/xenia-libretro`, branch `libretro` | Reference base for the Libretro port, including frontend contracts, options, APIs, structures and formats. | Remote `libretro`; preserved local `libretro` branch. |
| `has207/xenia-edge`, branch `edge` | Standalone emulator's shared engine source. Its updates are assessed against the Libretro base and the fork's adaptations. | Remote `upstream`; separate local `upstream` branch. |
| `Zer0one/xenia-libretro`, branch `main` | This fork's improvements and customizations, adapted to the Libretro reference base. | Remote `origin`; development on `main` as requested by the user. |

An engine merge is not a Libretro-upstream synchronization. Identify both source
revisions separately when planning, reviewing and reporting an integration.

## Integration Direction

Start from upstream Libretro's current design and adapt the fork's improvements
to it. When the Libretro upstream changes an API, structure, option contract or
format, normally follow that change. Do not preserve an older fork format or add
a compatibility layer solely because the fork previously used it.

Retain exceptions only for concrete problems or documented requirements. Record
the affected upstream revision, the problem, the local adaptation, supporting
evidence and the condition for removing the exception. Make local changes easy
to identify and explain, and keep their divergence small enough to support a
future integration PR to the Libretro upstream.

Preserve established fixes by adapting them to the new base, rather than keeping
the old base unchanged around them. Keep earlier test results attributed to their
actual source revisions and artifacts.

## Standalone Engine Updates

Follow the repository's full-merge and `.upstream-excluded` rules for Xenia Edge
engine integration. Keep the core free of excluded standalone UI, packaging,
native Metal and development tools. A newer standalone revision does not by
itself replace the Libretro port as the integration reference base.

Keep core adaptations and separate MoltenVK changes distinguishable, with their
own evidence and upstream destinations.

## Review And Protected Files

Proceed with mechanical conflict resolution and normal upstream API migrations
within authorized work. Present substantial behavioral choices, compatibility
tradeoffs and documented exceptions to Andrea for review, with a concrete
proposal and its consequences.

Only the developer may write or delete `AGENTS.md` and `CLAUDE.md`. Do not edit
those files to record this policy; propose any required instruction-file change
to the developer. Preserve the existing branch/history protections.
