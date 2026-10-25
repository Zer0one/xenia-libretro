# Independent Queue Ordering Findings

Date: 24 October 2026. Apple M4 / macOS 26.5.1. This investigation uses the
project's MoltenVK source `e9b7bd2e4d6f365b36d29f5f57b8d39ca92f157f`
(reporting 1.4.2), matched diagnostic original/candidate builds, and retained
official 1.4.2/1.3.0 frameworks. No core, frontend or installed driver changes.

Follow-up: [Independent Queue Correction](INDEPENDENT_QUEUE_FIX.md) documents
the broader local candidate and successful reproducer checks. The findings and
original-driver results below remain preserved as the diagnosis.

## Two Observed Mechanisms

### Drawable Identity Changes During Encoding

Two asynchronous queue workers can both observe an empty `_mtlDrawable` slot
and enter `CAMetalLayer.nextDrawable` for the same `MVKPresentableSwapchainImage`.
The first worker publishes drawable A; the other publishes drawable B. A single
render submission can then obtain texture A for its clear and texture B for its
copy/readback, while presentation captures B. A GPU semaphore does not prevent
these CPU-side lookups from executing concurrently.

The trace of the original source with a fresh semaphore for every presentation
shows this within its first rendering submission:

| Sequence | Worker | Observation |
| --- | --- | --- |
| 79 | Render scope 1 | Image `0xbfedd4a00`, drawable `0xbfecb7100`, texture `0xbfee99180` |
| 80–84 | Present scope 2 | The same image publishes/captures drawable `0xbfecb7020`, texture `0xbfee98280` |
| 88 | Render scope 1 | The same submission now obtains texture `0xbfee98280` |

Source operations are the retained assignment in `getCAMetalDrawable()` and the
unprotected slot reads/releases in `MVKImage.mm`. Overwriting a retained slot
can also lose the first drawable reference, leaving a drawable unavailable to
the layer; this provides a concrete starvation mechanism consistent with the
earlier sampled `nextDrawable` waits. The trace directly proves the double
lookup and identity change, not a complete retain census of every failure.

Both original and candidate exhibit identity changes with fresh semaphores,
where the analyzer finds no reused stale event target. The patched shared-queue
control completes 240 presentations with no texture identity change. CPU-render
wait and callback-semaphore controls also pass. The local ownership patch
addresses a different acquisition/presentation overlap on a shared queue; it
does not serialize these two CPU workers.

### Reused Binary Semaphores Can Wait For An Already Completed Signal

In `MVKSync.mm`, `MVKSemaphoreMTLEvent::encodeWait()` increments
`_mtlEventValue`; `encodeSignal()` subsequently reads that same atomic. Separate
CPU workers can encode the wait before encoding the corresponding signal:

1. First consumer encodes wait value 1 and advances the counter to 2.
2. First producer encodes signal value 2; both GPU command buffers complete.
3. Next consumer encodes wait value 2, which the previous producer has already
   reached. The next producer has not encoded its signal value 3 yet.

The detailed original trace records steps 1–3 at sequences 3, 5 and 11, with
the first producer's GPU completion at 7, before the second wait at 11. The
second consumer completes at 15, before its producer at 16. Metal event values
are monotonic, and a wait passes once the event reaches or exceeds its target;
the previous value therefore satisfies this later wait.

`semaphore_harness.mm` reproduces the data-order failure without a surface,
swapchain, drawable or presentation call. It submits a producer before its
consumer, fills disjoint scratch words to exercise asynchronous CPU encoding,
copies a counter, and waits both fences before checking or reusing resources.
The buffer uses concurrent sharing across the two queue families, with a
transfer-to-host readback barrier and coherent host memory.

| Driver / Control | Incorrect Copies Out Of 32 |
| --- | --- |
| Official 1.4.2, asynchronous, same semaphore reused | 31 |
| Official 1.3.0, asynchronous, same semaphore reused | 31 |
| Local drawable-patched 1.4.2, asynchronous | 31 |
| Official 1.4.2, asynchronous, fresh semaphore per round | 0 |
| Official 1.3.0, asynchronous, fresh semaphore per round | 0 |
| Patched 1.4.2, synchronous submission | 0 |
| Patched 1.4.2, CPU-callback semaphore control | 0 |

The matched detailed original and candidate each reproduce 31 stale copies.
Their analyzers find 31 reused, already completed event targets and 31 consumer
completions before the corresponding current producer. The fresh-semaphore
trace retains wait-before-signal encoding but removes stale reuse and copies
all 32 values correctly. This isolates an event-token reuse defect independently
of the drawable issue. Fresh semaphores are a diagnostic control, not an
installed workaround or a proposed general driver implementation.

## Consequences For A Fix

Two invariants need separate treatment:

- Reserve matching signal/wait tokens for each logical use of a binary semaphore
  independently of CPU worker execution order. Review deferred acquisition
  signals and imported/exported Metal events along with ordinary submissions.
- Give each image acquisition one stable drawable generation, including lazy
  publication, texture lookup, presentation capture and retirement. Synchronizing
  only GPU execution does not stabilize CPU-side resource identity. A lock held
  across blocking `nextDrawable` may prevent progress needed to return drawables;
  publication and lifetime must be designed together.

These are design requirements, not a completed general fix. Keep the validated
shared-queue core path and original-driver compatibility fallback while a
broader candidate is developed and reviewed. Existing performance observations
are unchanged; this work does not measure an additional speed improvement or
attribute every earlier timeout to one cause.

## Evidence And Reproduction

Native harness build/run commands are in [README.md](README.md). The optional
`--fresh-semaphores` control is available in both harnesses. The bounded trace
analyzer is `analyze_queue_trace.py`; its ordinal pairing assumptions apply to
these harnesses, not arbitrary application logs.

Local raw evidence is `.local/mvk-queue-order`: exact diagnostic source copies,
build/link commands, driver hashes, 24 native test results, JSONL traces and
analysis JSON files. Diagnostic logging adds synchronization and perturbs timing;
the uninstrumented official-framework semaphore test reproduces independently.
The initial LLDB launch attempt timed out and provides no access-order evidence.
No Vulkan validation layer or other hardware was used.

The related [upstream issue #2791](https://github.com/KhronosGroup/MoltenVK/issues/2791)
concerns drawable lifetime. It is not evidence that the distinct semaphore
problem is already reported or fixed. No external comment or PR is submitted.

## Primary References

- Local source: `MoltenVK/MoltenVK/GPUObjects/MVKImage.mm`, `MVKQueue.mm`,
  `MVKSync.mm` and `MVKSync.h` at the revision above.
- [Apple: About Synchronization Events](https://developer.apple.com/documentation/metal/about-synchronization-events)
  describes monotonic event values and GPU wait/signal execution.
- [Khronos: Rendering And Presentation](https://docs.vulkan.org/tutorial/latest/03_Drawing_a_triangle/03_Drawing/02_Rendering_and_presentation.html)
  distinguishes GPU semaphore ordering from CPU fence waits.
