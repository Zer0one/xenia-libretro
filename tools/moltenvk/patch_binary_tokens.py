#!/usr/bin/env python3
"""Stage an experimental binary-event token fix in a separate source tree."""

import argparse
import difflib
import hashlib
import json
import shutil
from pathlib import Path


def patch_sources(source):
    files = {}

    def edit(name, changes):
        original = (source / name).read_text()
        candidate = original
        for old, new in changes:
            if candidate.count(old) != 1:
                raise ValueError(f"Unexpected source in {name}: {old[:100]}")
            candidate = candidate.replace(old, new)
        files[name] = (original, candidate)

    edit("MVKSync.h", [
        ("\tvirtual void encodeWait(id<MTLCommandBuffer> mtlCmdBuff, uint64_t value) = 0;",
         "\tvirtual void encodeWait(id<MTLCommandBuffer> mtlCmdBuff, uint64_t value) = 0;\n\n"
         "\t// Reserve binary-event tokens on the submitting thread, before queue workers\n"
         "\t// can encode the corresponding operations in a different CPU order. Timeline\n"
         "\t// semaphores keep the application's explicit values. Copies keep the token.\n"
         "\tvirtual uint64_t reserveWaitToken(uint64_t value) { return value; }\n"
         "\tvirtual uint64_t reserveSignalToken(uint64_t value) { return value; }"),
        ("\t * 'value' only applies if this semaphore is a timeline semaphore. It is the value to wait for the\n"
         "\t * semaphore to have.",
         "\t * 'value' is the application's timeline value or a reserved binary-event token."),
        ("\t * 'value' only applies if this semaphore is a timeline semaphore. It is the value to assign the semaphore\n"
         "\t * upon completion.",
         "\t * 'value' is the application's timeline value or a reserved binary-event token."),
        ("class MVKSemaphoreMTLEvent : public MVKSemaphore {\n\npublic:",
         "class MVKSemaphoreMTLEvent : public MVKSemaphore {\n\npublic:\n"
         "\tuint64_t reserveWaitToken(uint64_t) override { return _mtlEventValue.fetch_add(1); }\n"
         "\tuint64_t reserveSignalToken(uint64_t) override { return _mtlSignalValue.fetch_add(1); }"),
        ("\tstd::atomic<uint64_t> _mtlEventValue;",
         "\tstd::atomic<uint64_t> _mtlEventValue; // Next binary wait token.\n"
         "\tstd::atomic<uint64_t> _mtlSignalValue; // Next signal, including deferred acquisition."),
    ])
    edit("MVKSync.mm", [
        ("void MVKSemaphoreMTLEvent::encodeWait(id<MTLCommandBuffer> mtlCmdBuff, uint64_t) {\n"
         "\tif (mtlCmdBuff) { [mtlCmdBuff encodeWaitForEvent: _mtlEvent value: _mtlEventValue++]; }",
         "void MVKSemaphoreMTLEvent::encodeWait(id<MTLCommandBuffer> mtlCmdBuff, uint64_t value) {\n"
         "\tif (mtlCmdBuff) { [mtlCmdBuff encodeWaitForEvent: _mtlEvent value: value]; }"),
        ("void MVKSemaphoreMTLEvent::encodeSignal(id<MTLCommandBuffer> mtlCmdBuff, uint64_t) {\n"
         "\tif (mtlCmdBuff) { [mtlCmdBuff encodeSignalEvent: _mtlEvent value: _mtlEventValue]; }",
         "void MVKSemaphoreMTLEvent::encodeSignal(id<MTLCommandBuffer> mtlCmdBuff, uint64_t value) {\n"
         "\tif (mtlCmdBuff) { [mtlCmdBuff encodeSignalEvent: _mtlEvent value: value]; }"),
        ("uint64_t MVKSemaphoreMTLEvent::deferSignal() {\n\treturn _mtlEventValue;\n}",
         "uint64_t MVKSemaphoreMTLEvent::deferSignal() {\n\treturn reserveSignalToken(0);\n}"),
        ("\t\t_mtlEventValue = 1;\n\t}\n}",
         "\t\t_mtlEventValue = 1;\n\t}\n\t_mtlSignalValue = _mtlEventValue.load();\n}"),
    ])
    edit("MVKQueue.h", [
        ("\tvoid encodeWait(id<MTLCommandBuffer> mtlCmdBuff);\n\tvoid encodeSignal(id<MTLCommandBuffer> mtlCmdBuff);",
         "\tvoid reserveWaitToken();\n\tvoid reserveSignalToken();\n\tvoid setTimelineValue(uint64_t timelineValue);\n"
         "\tvoid encodeWait(id<MTLCommandBuffer> mtlCmdBuff);\n\tvoid encodeSignal(id<MTLCommandBuffer> mtlCmdBuff);"),
    ])
    edit("MVKQueue.mm", [
        ("void MVKSemaphoreSubmitInfo::encodeWait(id<MTLCommandBuffer> mtlCmdBuff) {",
         "void MVKSemaphoreSubmitInfo::reserveWaitToken() {\n"
         "\tif (_semaphore) { value = _semaphore->reserveWaitToken(value); }\n}\n\n"
         "void MVKSemaphoreSubmitInfo::reserveSignalToken() {\n"
         "\tif (_semaphore) { value = _semaphore->reserveSignalToken(value); }\n}\n\n"
         "void MVKSemaphoreSubmitInfo::setTimelineValue(uint64_t timelineValue) {\n"
         "\tif (_semaphore && _semaphore->getSemaphoreType() == VK_SEMAPHORE_TYPE_TIMELINE) { value = timelineValue; }\n}\n\n"
         "void MVKSemaphoreSubmitInfo::encodeWait(id<MTLCommandBuffer> mtlCmdBuff) {"),
        ("\t\t_waitSemaphores.emplace_back(pWaitSemaphoreSubmitInfos[i]);",
         "\t\t_waitSemaphores.emplace_back(pWaitSemaphoreSubmitInfos[i]);\n"
         "\t\t_waitSemaphores.back().reserveWaitToken();"),
        ("\t\t_waitSemaphores.emplace_back(pWaitSemaphores[i], pWaitDstStageMask ? pWaitDstStageMask[i] : 0);",
         "\t\t_waitSemaphores.emplace_back(pWaitSemaphores[i], pWaitDstStageMask ? pWaitDstStageMask[i] : 0);\n"
         "\t\t_waitSemaphores.back().reserveWaitToken();"),
        ("\t\t\t_signalSemaphores.emplace_back(pSubmit->pSignalSemaphoreInfos[i]);",
         "\t\t\t_signalSemaphores.emplace_back(pSubmit->pSignalSemaphoreInfos[i]);\n"
         "\t\t\t_signalSemaphores.back().reserveSignalToken();"),
        ("\t\t\t_signalSemaphores.emplace_back(pSubmit->pSignalSemaphores[i], 0);",
         "\t\t\t_signalSemaphores.emplace_back(pSubmit->pSignalSemaphores[i], 0);\n"
         "\t\t\t_signalSemaphores.back().reserveSignalToken();"),
        ("_waitSemaphores[i].value = pTimelineSubmit->pWaitSemaphoreValues[i];",
         "_waitSemaphores[i].setTimelineValue(pTimelineSubmit->pWaitSemaphoreValues[i]);"),
        ("_signalSemaphores[i].value = pTimelineSubmit->pSignalSemaphoreValues[i];",
         "_signalSemaphores[i].setTimelineValue(pTimelineSubmit->pSignalSemaphoreValues[i]);"),
    ])
    return files


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="Pristine MoltenVK source root")
    parser.add_argument("output", type=Path, help="New output folder; source is never modified")
    args = parser.parse_args()
    if args.output.resolve().is_relative_to(args.source.resolve()):
        parser.error("Output must be outside the input source tree")
    files = patch_sources(args.source / "MoltenVK/MoltenVK/GPUObjects")
    args.output.mkdir(parents=True, exist_ok=False)
    # Compile every translation unit against the same class definitions. A few
    # overlaid headers alongside original .mm paths would violate that rule.
    staged = args.output / "source"
    shutil.copytree(args.source, staged, symlinks=True,
                    ignore=shutil.ignore_patterns(".git"))
    diffs, hashes = [], {}
    for name, (original, candidate) in files.items():
        relative = "MoltenVK/MoltenVK/GPUObjects/" + name
        (staged / relative).write_text(candidate)
        diffs.extend(difflib.unified_diff(original.splitlines(True), candidate.splitlines(True),
                                        fromfile="a/" + relative, tofile="b/" + relative))
        hashes[relative] = {"original": hashlib.sha256(original.encode()).hexdigest(),
                            "candidate": hashlib.sha256(candidate.encode()).hexdigest()}
    (args.output / "binary-event-tokens.patch").write_text("".join(diffs))
    (args.output / "source.json").write_text(json.dumps({"source": str(args.source.resolve()),
        "staged_source": str(staged.resolve()), "sha256": hashes,
        "experimental": True, "installed": False}, indent=2) + "\n")
