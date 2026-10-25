#!/usr/bin/env python3
"""Generate reviewed driver sources outside the upstream checkout."""
import difflib
import hashlib
import json
import sys
from pathlib import Path

from patch_driver import patch_source

source, output = map(Path, sys.argv[1:])
output.mkdir(parents=True, exist_ok=True)
image = source / "MoltenVK/MoltenVK/GPUObjects/MVKImage.mm"
original = image.read_text()
patched = patch_source(original)
sampler = source / "MoltenVK/MoltenVK/OS/MTLSamplerDescriptor+MoltenVK.m"
sampler_original = sampler.read_text()
old = "#if MVK_USE_METAL_PRIVATE_API\n/** Additional methods"
new = "#if MVK_USE_METAL_PRIVATE_API && __MAC_OS_X_VERSION_MAX_ALLOWED < 260000\n/** Additional methods"
if sampler_original.count(old) > 1:
    raise ValueError("Unexpected sampler declaration")
# Older sources redeclare lodBias, which SDK 26 exposes publicly. Newer
# sources use this block for other private declarations that remain required.
sampler_patched = (sampler_original.replace(old, new)
                   if "@property(nonatomic, readwrite) float lodBias;" in sampler_original
                   else sampler_original)
for name, text in [("MVKImage.mm", patched), (sampler.name, sampler_patched)]:
    target = output / name
    if not target.exists() or target.read_text() != text:
        target.write_text(text)
for name, before, after in [("ownership-order", original, patched),
                            ("sdk26-compatibility", sampler_original, sampler_patched)]:
    (output / (name + ".patch")).write_text("".join(difflib.unified_diff(
        before.splitlines(True), after.splitlines(True),
        fromfile="original", tofile="candidate")))
(output / "source.json").write_text(json.dumps({
    "source": str(source.resolve()),
    "original_image_sha256": hashlib.sha256(original.encode()).hexdigest(),
    "candidate_image_sha256": hashlib.sha256(patched.encode()).hexdigest(),
    "sdk26_sampler_change": sampler_original != sampler_patched,
}, indent=2) + "\n")
