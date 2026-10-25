#!/usr/bin/env python3
"""Stage Vulkan-managed timeline CPU encoding coordination.

Input must include the binary/drawable and device-loss corrections. Imported or
exportable Metal event payloads retain their existing behavior and are not covered.
"""
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
        ("#include <unordered_map>", "#include <unordered_map>\n#include <map>"),
        ("class MVKTimelineSemaphoreMTLEvent : public MVKTimelineSemaphore {\n\npublic:",
         "class MVKTimelineSemaphoreMTLEvent : public MVKTimelineSemaphore {\n\npublic:\n"
         "\tstd::shared_ptr<MVKSemaphoreImpl> getSignalEncoding(uint64_t value, bool consume) override;"),
        ("\tstd::unordered_set<MVKFenceSitter*> _sitters;",
         "\tstd::unordered_set<MVKFenceSitter*> _sitters;\n"
         "\tvoid signalEncodingComplete(uint64_t value);\n"
         "\tstd::mutex _encodingLock;\n"
         "\tstd::map<uint64_t, std::shared_ptr<MVKSemaphoreImpl>> _encodingWaits;\n"
         "\tuint64_t _encodedValue = 0;\n"
         "\tbool _externalEncodingPayload = false;"),
    ])
    edit("MVKSync.mm", [
        ("void MVKTimelineSemaphoreMTLEvent::encodeWait(id<MTLCommandBuffer> mtlCmdBuff, uint64_t value) {",
         "std::shared_ptr<MVKSemaphoreImpl> MVKTimelineSemaphoreMTLEvent::getSignalEncoding(uint64_t value, bool consume) {\n"
         "\t// This protocol tracks Vulkan queue/host signals. External Metal\n"
         "\t// producers need a separate payload/lifetime design.\n"
         "\tif (!consume || _externalEncodingPayload) { return {}; }\n"
         "\tlock_guard<mutex> lock(_encodingLock);\n"
         "\tif (value <= _encodedValue || value <= _mtlEvent.signaledValue) { return {}; }\n"
         "\tauto& state = _encodingWaits[value];\n"
         "\tif (!state) { state = std::make_shared<MVKSemaphoreImpl>(false, 1); }\n"
         "\treturn state;\n}\n\n"
         "void MVKTimelineSemaphoreMTLEvent::signalEncodingComplete(uint64_t value) {\n"
         "\tlock_guard<mutex> lock(_encodingLock);\n"
         "\t_encodedValue = std::max(_encodedValue, value);\n"
         "\tauto end = _encodingWaits.upper_bound(_encodedValue);\n"
         "\tfor (auto it = _encodingWaits.begin(); it != end; ++it) { it->second->release(); }\n"
         "\t_encodingWaits.erase(_encodingWaits.begin(), end);\n}\n\n"
         "void MVKTimelineSemaphoreMTLEvent::encodeWait(id<MTLCommandBuffer> mtlCmdBuff, uint64_t value) {"),
        ("void MVKTimelineSemaphoreMTLEvent::encodeSignal(id<MTLCommandBuffer> mtlCmdBuff, uint64_t value) {\n"
         "\t[mtlCmdBuff encodeSignalEvent: _mtlEvent value: value];",
         "void MVKTimelineSemaphoreMTLEvent::encodeSignal(id<MTLCommandBuffer> mtlCmdBuff, uint64_t value) {\n"
         "\t[mtlCmdBuff encodeSignalEvent: _mtlEvent value: value];\n"
         "\tif (mtlCmdBuff) { signalEncodingComplete(value); }"),
        ("\t_mtlEvent.signaledValue = pSignalInfo->value;",
         "\t_mtlEvent.signaledValue = pSignalInfo->value;\n\tsignalEncodingComplete(pSignalInfo->value);"),
        ("\tif (pTypeCreateInfo) {\n\t\t_mtlEvent.signaledValue = pTypeCreateInfo->initialValue;",
         "\t_externalEncodingPayload = pImportInfo || pExportInfo;\n"
         "\tif (pTypeCreateInfo) {\n\t\t_mtlEvent.signaledValue = pTypeCreateInfo->initialValue;"),
    ])
    edit("MVKQueue.h", [
        ("\tstd::shared_ptr<MVKSemaphoreImpl> _signalEncoding;",
         "\tstd::shared_ptr<MVKSemaphoreImpl> _signalEncoding;\n\tbool _encodingWait = false;"),
        ("\tVkResult waitForSignalEncoding();",
         "\tVkResult waitForSignalEncoding(bool timelineCPUWait = true);"),
    ])
    edit("MVKQueue.mm", [
        ("void MVKSemaphoreSubmitInfo::reserveWaitToken() {",
         "void MVKSemaphoreSubmitInfo::reserveWaitToken() {\n\t_encodingWait = true;"),
        ("\tif (_semaphore && _semaphore->getSemaphoreType() == VK_SEMAPHORE_TYPE_TIMELINE) { value = timelineValue; }",
         "\tif (_semaphore && _semaphore->getSemaphoreType() == VK_SEMAPHORE_TYPE_TIMELINE) {\n"
         "\t\tvalue = timelineValue;\n"
         "\t\tif (_encodingWait) { _signalEncoding = _semaphore->getSignalEncoding(value, true); }\n\t}"),
        ("VkResult MVKSemaphoreSubmitInfo::waitForSignalEncoding() {\n\tif (!_semaphore) { return VK_SUCCESS; }",
         "VkResult MVKSemaphoreSubmitInfo::waitForSignalEncoding(bool timelineCPUWait) {\n"
         "\tif (!_semaphore) { return VK_SUCCESS; }\n"
         "\t// A synchronous public submit must return so its caller can submit\n"
         "\t// a future timeline signal. Such calls finish CPU encoding inline;\n"
         "\t// WSI binary waits require all producer signals submitted before present.\n"
         "\tif (!timelineCPUWait && _semaphore->getSemaphoreType() == VK_SEMAPHORE_TYPE_TIMELINE) {\n"
         "\t\treturn _semaphore->getDevice()->waitForEncodingSignal(nullptr);\n\t}"),
        ("\t_signalEncoding(other._signalEncoding),",
         "\t_signalEncoding(other._signalEncoding),\n\t_encodingWait(other._encodingWait),"),
        ("\t_signalEncoding = other._signalEncoding;",
         "\t_signalEncoding = other._signalEncoding;\n\t_encodingWait = other._encodingWait;"),
    ])
    # Both command-buffer and presentation execution paths use the instance's
    # actual queue submission mode. Keep the reviewed number of call sites.
    old, new = files["MVKQueue.mm"]
    anchor = "ws.waitForSignalEncoding();"
    if new.count(anchor) != 2:
        raise ValueError("Unexpected CPU encoding wait call sites")
    files["MVKQueue.mm"] = (old, new.replace(anchor,
        "ws.waitForSignalEncoding(!getMVKConfig().synchronousQueueSubmits);"))
    return files


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    if args.output.resolve().is_relative_to(args.source.resolve()):
        parser.error("Output must be outside the input source tree")
    files = patch_sources(args.source / "MoltenVK/MoltenVK/GPUObjects")
    args.output.mkdir(parents=True, exist_ok=False)
    staged = args.output / "source"
    shutil.copytree(args.source, staged, symlinks=True, ignore=shutil.ignore_patterns(".git"))
    diffs, hashes = [], {}
    for name, (old, new) in files.items():
        rel = "MoltenVK/MoltenVK/GPUObjects/" + name
        (staged / rel).write_text(new)
        diffs.extend(difflib.unified_diff(old.splitlines(True), new.splitlines(True),
            fromfile="a/"+rel, tofile="b/"+rel))
        hashes[rel] = {"original":hashlib.sha256(old.encode()).hexdigest(),
                       "candidate":hashlib.sha256(new.encode()).hexdigest()}
    (args.output/"timeline-encoding.patch").write_text("".join(diffs))
    (args.output/"source.json").write_text(json.dumps({"source":str(args.source.resolve()),
        "staged_source":str(staged.resolve()),"sha256":hashes,
        "experimental":True,"installed":False},indent=2)+"\n")
