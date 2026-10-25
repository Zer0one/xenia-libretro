#!/usr/bin/env python3
"""Prepare the drawable ownership candidate without editing vendored sources."""

import argparse
import difflib
import hashlib
import json
from pathlib import Path


def patch_source(original):
    source = original

    def replace(old, new):
        nonlocal source
        if source.count(old) != 1:
            raise ValueError("Source does not match the reviewed patch: " + old[:80])
        source = source.replace(old, new)

    replace(
        "\t// Now that this image is being acquired, release the existing drawable and its texture.\n"
        "\t// This is not done earlier so the texture is retained for any post-processing such as screen captures, etc.\n"
        "\treleaseMetalDrawable();",
        "\t// Acquiring a logical image may overlap the previous queued render/present.\n"
        "\t// Its drawable is detached by the queue-ordered presentation path instead.",
    )
    replace(
        "\tMVKSwapchainSignaler signaler = getPresentationSignaler();",
        "\t// Transfer the slot's drawable ownership to this presentation.\n"
        "\t// Prior rendering must have been encoded on this submission queue.\n"
        "\tretain();\n\t[mtlDrwbl retain];\n\treleaseMetalDrawable();\n"
        "\tMVKSwapchainSignaler signaler = getPresentationSignaler();",
    )
    replace(
        "\t// Ensure this image, the drawable, and the present fence are not destroyed while\n"
        "\t// awaiting MTLCommandBuffer completion. We retain the drawable separately because\n"
        "\t// a new drawable might be acquired by this image by then.",
        "\t// The image and drawable were retained before detaching the slot above.\n"
        "\t// Retain the present fence until command-buffer completion as well.",
    )
    replace(
        "\tretain();\n\t[mtlDrwbl retain];\n\tauto* fence = presentInfo.fence;",
        "\tauto* fence = presentInfo.fence;",
    )
    return source


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="Original MVKImage.mm")
    parser.add_argument("output", type=Path, help="New output directory")
    args = parser.parse_args()
    original = args.source.read_text()
    candidate = patch_source(original)
    args.output.mkdir(parents=True, exist_ok=False)
    (args.output / "MVKImage.mm").write_text(candidate)
    (args.output / "ownership-order.patch").write_text("".join(difflib.unified_diff(
        original.splitlines(True), candidate.splitlines(True),
        fromfile="a/MoltenVK/MoltenVK/GPUObjects/MVKImage.mm",
        tofile="b/MoltenVK/MoltenVK/GPUObjects/MVKImage.mm")))
    (args.output / "source.json").write_text(json.dumps({
        "source": str(args.source.resolve()),
        "original_sha256": hashlib.sha256(original.encode()).hexdigest(),
        "candidate_sha256": hashlib.sha256(candidate.encode()).hexdigest(),
    }, indent=2) + "\n")
