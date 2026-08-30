// Per-client gain stage, extracted from the driver translation unit so the
// bit-transparency contract is executed as an assertion instead of folklore
// (SamplePathTests pins it).
//
// Contracts pinned by tests:
// - at exactly 1.0 the buffer is a bit-identical no-op;
// - otherwise every sample scales and clamps into [-1, 1];
// - non-unity processing increments the gained-buffers counter (watchdog
//   evidence that per-app gain is doing real work).

#pragma once

#include <CoreFoundation/CoreFoundation.h>

#include <atomic>

namespace passthru {

class ClientGain
{
public:
    // Realtime thread. Applies `gain` in place to `sampleCount` interleaved
    // samples; exactly 1.0 returns without touching memory.
    void Apply(Float32* samples, UInt32 sampleCount, Float32 gain);

    UInt64 AppliedBuffers() const;

private:
    std::atomic<UInt64> appliedBuffers_{0};
};

} // namespace passthru
