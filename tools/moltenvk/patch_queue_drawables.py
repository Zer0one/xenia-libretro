#!/usr/bin/env python3
"""Stage CPU dependency ordering and serialized drawable publication.

Input is a source tree prepared by patch_binary_tokens.py. This experimental
overlay still needs the separate ownership patch applied by prepare_build.py.
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
        ("#include <unordered_set>", "#include <unordered_set>\n#include <unordered_map>\n#include <memory>"),
        ("\tvirtual uint64_t reserveSignalToken(uint64_t value) { return value; }",
         "\tvirtual uint64_t reserveSignalToken(uint64_t value) { return value; }\n"
         "\tvirtual std::shared_ptr<MVKSemaphoreImpl> getSignalEncoding(uint64_t, bool) { return {}; }"),
        ("\tuint64_t reserveSignalToken(uint64_t) override { return _mtlSignalValue.fetch_add(1); }",
         "\tuint64_t reserveSignalToken(uint64_t) override;\n"
         "\tstd::shared_ptr<MVKSemaphoreImpl> getSignalEncoding(uint64_t token, bool consume) override;"),
        ("\tstd::atomic<uint64_t> _mtlSignalValue; // Next signal, including deferred acquisition.",
         "\tstd::atomic<uint64_t> _mtlSignalValue; // Next signal, including deferred acquisition.\n"
         "\tstd::mutex _encodingLock;\n"
         "\tstd::unordered_map<uint64_t, std::shared_ptr<MVKSemaphoreImpl>> _encodingSignals;"),
    ])
    edit("MVKSync.mm", [
        ("void MVKSemaphoreMTLEvent::encodeWait(id<MTLCommandBuffer> mtlCmdBuff, uint64_t value) {",
         "uint64_t MVKSemaphoreMTLEvent::reserveSignalToken(uint64_t) {\n"
         "\tlock_guard<mutex> lock(_encodingLock);\n"
         "\tauto token = _mtlSignalValue.fetch_add(1);\n"
         "\t_encodingSignals.emplace(token, std::make_shared<MVKSemaphoreImpl>(false, 1));\n"
         "\treturn token;\n}\n\n"
         "std::shared_ptr<MVKSemaphoreImpl> MVKSemaphoreMTLEvent::getSignalEncoding(uint64_t token, bool consume) {\n"
         "\tlock_guard<mutex> lock(_encodingLock);\n"
         "\tauto found = _encodingSignals.find(token);\n"
         "\tif (found == _encodingSignals.end()) { return {}; }\n"
         "\tauto state = found->second;\n"
         "\tif (consume) { _encodingSignals.erase(found); }\n"
         "\treturn state;\n}\n\n"
         "void MVKSemaphoreMTLEvent::encodeWait(id<MTLCommandBuffer> mtlCmdBuff, uint64_t value) {"),
    ])
    edit("MVKQueue.h", [
        ("\tMVKSemaphore* _semaphore;", "\tMVKSemaphore* _semaphore;\n\tstd::shared_ptr<MVKSemaphoreImpl> _signalEncoding;"),
        ("\tvoid reserveWaitToken();", "\tVkResult waitForSignalEncoding();\n\tvoid reserveWaitToken();"),
    ])
    edit("MVKDevice.h", [
        ("\t/** Adds the specified host semaphore to be woken upon device loss. */\n\tvoid addSemaphore(MVKSemaphoreImpl* sem4);",
         "\t// Register/check and retire CPU encoding waits under the device-loss\n"
         "\t// mutex. A null semaphore only queries the synchronized loss result.\n"
         "\tVkResult waitForEncodingSignal(MVKSemaphoreImpl* sem4);\n\n"
         "\t/** Adds the specified host semaphore to be woken upon device loss. */\n\tvoid addSemaphore(MVKSemaphoreImpl* sem4);"),
    ])
    edit("MVKDevice.mm", [
        ("void MVKDevice::addSemaphore(MVKSemaphoreImpl* sem4) {",
         "VkResult MVKDevice::waitForEncodingSignal(MVKSemaphoreImpl* sem4) {\n"
         "\tunique_lock<mutex> lock(_sem4Lock);\n"
         "\tauto result = getConfigurationResult();\n"
         "\tif (!sem4 || result != VK_SUCCESS) { return result; }\n"
         "\t_awaitingSemaphores.push_back(sem4);\n"
         "\tlock.unlock();\n"
         "\tsem4->wait(UINT64_MAX, false);\n"
         "\tlock.lock();\n"
         "\tmvkRemoveFirstOccurance(_awaitingSemaphores, sem4);\n"
         "\treturn getConfigurationResult();\n"
         "}\n\n"
         "void MVKDevice::addSemaphore(MVKSemaphoreImpl* sem4) {"),
    ])
    edit("MVKQueue.mm", [
        ("\tif (_semaphore) { value = _semaphore->reserveWaitToken(value); }",
         "\tif (_semaphore) {\n\t\tvalue = _semaphore->reserveWaitToken(value);\n"
         "\t\t_signalEncoding = _semaphore->getSignalEncoding(value, true);\n\t}"),
        ("\tif (_semaphore) { value = _semaphore->reserveSignalToken(value); }",
         "\tif (_semaphore) {\n\t\tvalue = _semaphore->reserveSignalToken(value);\n"
         "\t\t_signalEncoding = _semaphore->getSignalEncoding(value, false);\n\t}"),
        ("void MVKSemaphoreSubmitInfo::encodeWait(id<MTLCommandBuffer> mtlCmdBuff) {",
         "VkResult MVKSemaphoreSubmitInfo::waitForSignalEncoding() {\n"
         "\tif (!_semaphore) { return VK_SUCCESS; }\n"
         "\t// Check loss and register/remove the waiter under markLost()'s mutex.\n"
         "\treturn _semaphore->getDevice()->waitForEncodingSignal(_signalEncoding.get());\n}\n\n"
         "void MVKSemaphoreSubmitInfo::encodeWait(id<MTLCommandBuffer> mtlCmdBuff) {"),
        ("\tif (_semaphore) { _semaphore->encodeSignal(mtlCmdBuff, value); }",
         "\tif (_semaphore) { _semaphore->encodeSignal(mtlCmdBuff, value); }\n"
         "\tif (_signalEncoding) { _signalEncoding->release(); }"),
        ("\t_semaphore(other._semaphore),\n\tvalue(other.value),",
         "\t_semaphore(other._semaphore),\n\t_signalEncoding(other._signalEncoding),\n\tvalue(other.value),"),
        ("\t_semaphore = other._semaphore;", "\t_semaphore = other._semaphore;\n\t_signalEncoding = other._signalEncoding;"),
        ("\t_queue->_submissionCaptureScope->beginScope();",
         "\t_queue->_submissionCaptureScope->beginScope();\n"
         "\t// Binary GPU dependencies also identify the drawable generation to\n"
         "\t// encode against. Wait before resolving any command-buffer textures.\n"
         "\t// The producer only needs to finish CPU encoding, not GPU execution.\n"
         "\tauto deviceResult = getDevice()->waitForEncodingSignal(nullptr);\n"
         "\tif (deviceResult != VK_SUCCESS) { finish(); return deviceResult; }\n"
         "\tfor (auto& ws : _waitSemaphores) {\n"
         "\t\tauto result = ws.waitForSignalEncoding();\n"
         "\t\tif (result != VK_SUCCESS) { finish(); return result; }\n\t}"),
        ("VkResult MVKQueuePresentSurfaceSubmission::execute() {",
         "VkResult MVKQueuePresentSurfaceSubmission::execute() {\n"
         "\t// GPU event waits order execution, not CPU image/texture lookups.\n"
         "\t// Wait only for producer encoding, before taking the drawable slot.\n"
         "\tauto deviceResult = getDevice()->waitForEncodingSignal(nullptr);\n"
         "\tif (deviceResult != VK_SUCCESS) { finish(); return deviceResult; }\n"
         "\tfor (auto& ws : _waitSemaphores) {\n"
         "\t\tauto result = ws.waitForSignalEncoding();\n"
         "\t\tif (result != VK_SUCCESS) { finish(); return result; }\n\t}"),
    ])
    edit("MVKImage.h", [
        ("\tuint64_t semaphoreSignalToken;", "\tuint64_t semaphoreSignalToken;\n\tstd::shared_ptr<MVKSemaphoreImpl> signalEncoding;"),
        ("\tid<CAMetalDrawable> _mtlDrawable = nil;",
         "\tstd::mutex _drawableLock;\n\tstd::condition_variable _drawableReady;\n"
         "\tbool _drawableAcquiring = false;\n\tid<CAMetalDrawable> _mtlDrawable = nil;"),
    ])
    original = (source / "MVKImage.mm").read_text()
    start = original.index("id<CAMetalDrawable> MVKPresentableSwapchainImage::getCAMetalDrawable() {")
    end = original.index("\n// If not headless, retrieve", start)
    getter = '''id<CAMetalDrawable> MVKPresentableSwapchainImage::getCAMetalDrawable() {
    if (_mtlTextureHeadless) { return nil; }
    unique_lock<mutex> lock(_drawableLock);
    _drawableReady.wait(lock, [this]{ return !_drawableAcquiring; });
    if (!_mtlDrawable) {
        _drawableAcquiring = true;
        lock.unlock();
        id<CAMetalDrawable> acquired = nil;
        bool invalidFormat = false;
        // One fetcher per image. No image mutex is held across nextDrawable or
        // Objective-C release; callbacks returning drawables can still progress.
        uint32_t attempts = _swapchain->getImageCount();
        for (uint32_t attempt = 0; !acquired && attempt < attempts; ++attempt) {
            uint64_t startTime = getPerformanceTimestamp();
            acquired = [_swapchain->getCAMetalLayer().nextDrawable retain];
            addPerformanceInterval(getPerformanceStats().queue.retrieveCAMetalDrawable, startTime);
            invalidFormat = acquired && !acquired.texture.pixelFormat;
            if (invalidFormat) { [acquired release]; acquired = nil; }
        }
        if (!acquired) {
            setConfigurationResult(reportError(invalidFormat ? VK_ERROR_OUT_OF_DATE_KHR : VK_ERROR_OUT_OF_POOL_MEMORY,
                "CAMetalDrawable could not be acquired after %d attempts.", attempts));
        }
        lock.lock();
        _mtlDrawable = acquired;
        _drawableAcquiring = false;
        _drawableReady.notify_all();
    }
    // Protect the borrowed return value through this worker's autorelease pool.
    return [[_mtlDrawable retain] autorelease];
}
'''
    release_start = original.index("void MVKPresentableSwapchainImage::releaseMetalDrawable() {")
    release_end = original.index("\n}", release_start) + 2
    release = '''void MVKPresentableSwapchainImage::releaseMetalDrawable() {
    id<CAMetalDrawable> old;
    {
        unique_lock<mutex> lock(_drawableLock);
        _drawableReady.wait(lock, [this]{ return !_drawableAcquiring; });
        old = _mtlDrawable;
        _mtlDrawable = nil;
    }
    [old release];
}'''
    edit("MVKImage.mm", [
        (original[start:end], getter),
        (original[release_start:release_end], release),
        ("static void signal(MVKSemaphore* semaphore, uint64_t semaphoreSignalToken, id<MTLCommandBuffer> mtlCmdBuff) {\n"
         "\tif (semaphore) { semaphore->encodeDeferredSignal(mtlCmdBuff, semaphoreSignalToken); }\n}",
         "static void signal(const MVKSwapchainSignaler& signaler, id<MTLCommandBuffer> mtlCmdBuff) {\n"
         "\tif (signaler.semaphore) { signaler.semaphore->encodeDeferredSignal(mtlCmdBuff, signaler.semaphoreSignalToken); }\n"
         "\tif (mtlCmdBuff && signaler.signalEncoding) { signaler.signalEncoding->release(); }\n}"),
        ("signal(signaler.semaphore, signaler.semaphoreSignalToken, nil);", "signal(signaler, nil);"),
        ("\n\t\t\tsignal(signaler.semaphore, signaler.semaphoreSignalToken, mtlCmdBuff);", "\n\t\t\tsignal(signaler, mtlCmdBuff);"),
        ("\n\tsignal(signaler.semaphore, signaler.semaphoreSignalToken, mtlCmdBuff);", "\n\tsignal(signaler, mtlCmdBuff);"),
        ("auto signaler = MVKSwapchainSignaler{fence, semaphore, semaphore ? semaphore->deferSignal() : 0};",
         "auto signaler = MVKSwapchainSignaler{fence, semaphore, semaphore ? semaphore->deferSignal() : 0};\n"
         "\tif (semaphore) { signaler.signalEncoding = semaphore->getSignalEncoding(signaler.semaphoreSignalToken, false); }"),
        *([("\t\trelease();\n\t\tif (_swapchain) { _swapchain->notifyPresentComplete(presentInfo); }",
         "\t\t// Keep this image alive through its final access and serialize the\n"
         "\t\t// swapchain lookup with detachSwapchain(), as endPresentation does.\n"
         "\t\t{\n\t\t\tlock_guard<mutex> lock(_detachmentLock);\n"
         "\t\t\tif (_swapchain) { _swapchain->notifyPresentComplete(presentInfo); }\n\t\t}\n"
         "\t\trelease();")] if "notifyPresentComplete(presentInfo)" in original else []),
    ])
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
    for name, (original, candidate) in files.items():
        relative = "MoltenVK/MoltenVK/GPUObjects/" + name
        (staged / relative).write_text(candidate)
        diffs.extend(difflib.unified_diff(original.splitlines(True), candidate.splitlines(True),
                                        fromfile="a/" + relative, tofile="b/" + relative))
        hashes[relative] = {"original": hashlib.sha256(original.encode()).hexdigest(),
                            "candidate": hashlib.sha256(candidate.encode()).hexdigest()}
    (args.output / "queue-drawables.patch").write_text("".join(diffs))
    (args.output / "source.json").write_text(json.dumps({"source": str(args.source.resolve()),
        "sha256": hashes, "experimental": True, "installed": False}, indent=2) + "\n")
