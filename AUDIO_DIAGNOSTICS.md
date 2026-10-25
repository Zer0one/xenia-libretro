# Audio Supply And Frontend Pacing

Date: 23 October 2026. Apple M4, macOS 26.5.1, Daytona USA, upstream eb31a60.

## Result

The core had a frontend delivery defect: `update_audio()` sent only the samples
currently available from the mixer, skipping the callback entirely when empty.
It now supplies one complete frontend frame, filling a short tail with silence.
The fractional sample accumulator resets on content initialization/restart.
At 48 kHz and 60 Hz the callback receives 800 sample frames, regardless of a
temporary guest shortage. The mixer still consumes only the samples it has.

This corrects the callback contract but does not resolve audible continuity.
Matched tests retain approximately the same total device underruns. During the
slow part of the asynchronous intro, `retro_run` falls to roughly 34–38 calls/s
while the mixer supplies every requested sample. That delivers only about
27–30 thousand audio frames/s instead of 48 thousand. Video capture occupies
approximately 27–29 ms per call in those windows. There is enough queued guest
audio for each call, but too few calls per wall-clock second.

## Changes

- Pad only the missing output tail with zeroes; do not increase queue capacity,
  drain extra audio per call, change guest decoding or change frontend defaults.
- Reset fractional sample carry on initialization and load/reset.
- Add per-second `[Audio stats]` beside existing run/video statistics: calls,
  requested, supplied, submitted and accepted frames; short/empty calls and calls
  with no registered driver. `supplied` is measured before padding, so the log
  continues to expose guest shortages.

## Validation

Both builds use ARM64 Release/LTO. The diagnostic baseline changes logging only;
the corrected build additionally changes delivery and sample-carry reset.
Frontend fce35fc7, game, seed storage and output device are held constant.
Each run uses separate configuration/storage and exits 0 with complete emulator
teardown. The first three use the same local ownership-order MoltenVK candidate
with asynchronous submissions. The last uses the installed official 1.4.2 with
default submission settings. Device output is 44.1 kHz; frontend input is 48 kHz.

| Run | Frontend Frames | VSync | Wall Time | Intro Checkpoint | Device Underruns |
| --- | ---: | --- | ---: | ---: | ---: |
| Telemetry Baseline | 3,600 | On | 68.564 s | 19.179 s | 419 |
| Complete Audio Blocks | 3,600 | On | 67.598 s | 19.155 s | 416 |
| Complete Blocks, VSync Diagnostic | 3,600 | Off | 66.671 s | 19.216 s | 375 |
| Official Driver Compatibility | 1,200 | On | 24.320 s | Not Reached | 128 |

Underruns count device callbacks that lacked some or all samples, across the
whole session including startup and teardown. They are not a timestamped count
of audible interruptions. The shorter official-driver check is not comparable
to the 3,600-frame totals. Checkpoint sampling is approximately one second;
the baseline/corrected difference is not evidence of a speedup.

In the baseline's logged windows, the core is short by 1,920 sample frames
(40 ms), all in the first window. The corrected VSync-on run is short by 1,216
frames (25.3 ms), in the first and third windows; every requested frame is then
submitted and accepted, including the padded tail. The difference in guest
shortage between sessions is not credited to padding. Logged windows exclude
the incomplete final statistics interval.

Disabling VSync lowers median CPU video time in the last ten windows from
16.61 ms to 1.005 ms, but the intro still contains roughly 27–29 ms video waits
and the checkpoint is unchanged. It also produces more short source blocks:
16,192 missing sample frames across 39 logged windows, including the stable
tail. Faster/burstier delivery is therefore not a demonstrated audio solution.
No VSync setting is changed outside these isolated tests.

The corrected asynchronous runs' final screenshots visibly show the Daytona
title. The short official-driver run shows the ESRB intro. These are boot/render
checks; controlled racing, listening and physical controllers are unverified.

The isolated callback harness compiles the actual `update_audio()` body against
controlled mixer/frontend peers with ASan and UBSan. It reproduces the empty
callback failure in the baseline and passes the corrected implementation for
empty/partial/full stereo and 5.1 blocks, zero-filled tails, buffer boundaries,
telemetry, disabled audio and 50/60/120/165 Hz sample accounting. It does not
exercise the real mixer, guest decoder, concurrent ring or multichannel device.

## Frontend Source Interpretation

The exact frontend source confirms that the CoreAudio callback increments its
underrun counter for a short read and pads the missing part with silence. The
pipeline's wait count records waiting for core input after priming; a wait is
not itself a device underrun. Both totals are logged during teardown:
[CoreAudio fce35fc7](https://github.com/libretro/RetroArch/blob/fce35fc7/audio/drivers/coreaudio.c),
[Audio Pipeline fce35fc7](https://github.com/libretro/RetroArch/blob/fce35fc7/audio/audio_driver.c).

The inspected runs report no pulls larger than the device's declared maximum.
The one-second maximum pipeline wait is not localized by these aggregate logs;
it must not be presented as an observed one-second in-game dropout.

## Next Checks

Profile the 7–18-second intro interval and separate time spent submitting the
blit from waiting for its completion. Correlate that with guest video/decoder
activity. Preserve the CPU-completion compatibility path until the driver
lifetime issue is independently resolved. If shortages remain at a stable
frontend rate, examine producer deadlines and frontend callback burst cadence
before changing buffering or audio clocks.

The separate driver audit confirms that final presentation callbacks, explicit
image release/reacquisition and independent queue ordering still need validation;
see `.local/audio-investigation/ownership-audit.md`. No experimental driver is
installed by this audio activity.

## Evidence And Build

Evidence lives in `.local/audio-investigation/`: `summary.json`, source hashes,
build logs/manifests, the focused audio diff and callback-harness reports.
Full session logs and per-window tables are in `.local/comparison/audio-supply-*`.
All earlier tests retain their original artifacts and conclusions.

- Baseline core SHA256: `5ba1a93ddaa18fafd62e569643e4a9927dfc5a5365b6ca5898b85df761dafd33`.
- Corrected core SHA256: `fdf37a55dafa4eb33a8c2b7104440576f24e4aa0986c6adfc2c392c6cc1fdfc3`.
- Driver candidate SHA256: `ecde8fa6d483d9efb91bf5de30017375c4baa767efaf9330abb9e90e5680ae40`.

The current rolling core is deployed as `xenia_edge_libretro.dylib` with its
matching `.info`; installation hashes and preserved previous copies are recorded
under `.local/deployments/`. Earlier test manifests retain the original artifact
filenames. The naming migration preserves the tested binary hash. Commit and
push remain pending explicit authorization.
