// Local driver capability marker. Keep separate from the upstream bug fix.
// Version 1 identifies the shared-submission-queue drawable ownership patch.
#include <cstdint>

extern "C" __attribute__((visibility("default")))
uint32_t xeniaMoltenVKDrawableOwnershipPatchVersion() {
    return 1;
}
