// Per-client gain stage - see ClientGain.hpp for the contract.

#include "ClientGain.hpp"

#include <algorithm>

namespace passthru {

void ClientGain::Apply(Float32* samples, UInt32 sampleCount, Float32 gain)
{
    if (sampleCount == 0 || gain == 1.0f) {
        return; // pass-through contract: exact 1.0 multiplies nothing
    }

    for (UInt32 i = 0; i < sampleCount; i++) {
        samples[i] = std::clamp(samples[i] * gain, -1.0f, 1.0f);
    }

    appliedBuffers_.fetch_add(1, std::memory_order_relaxed);
}

UInt64 ClientGain::AppliedBuffers() const
{
    return appliedBuffers_.load(std::memory_order_relaxed);
}

} // namespace passthru
