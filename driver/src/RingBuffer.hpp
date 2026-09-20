// Lock-free SPSC ring of interleaved Float32 samples, extracted from the
// driver translation unit so its policies are host-testable
// (SamplePathTests pins them).
//
// Producer = write side of the output stream (realtime thread A), consumer =
// read side of the input stream (realtime thread B). Monotonic cursors +
// acquire/release ordering.
//
// Policies (contract, not accident):
// - overrun drops oldest data - newest audio wins - and counts;
// - underrun serves zeros for the shortfall, reports it through the return
//   value, and counts.
//
// Threading honesty: libASPL serializes IO operations under its own mutex,
// so producer/consumer separation is a logical discipline here, not an
// architectural guard against concurrent access.

#pragma once

#include <CoreFoundation/CoreFoundation.h>

#include <atomic>
#include <vector>

namespace passthru {

class RingBuffer
{
public:
    RingBuffer(UInt32 channelCount, UInt64 capacityFrames);

    // Realtime producer side. On overrun, advances the read cursor far
    // enough to make room (dropping oldest frames) and counts the event.
    void Write(const Float32* data, UInt64 frameCount);

    // Realtime consumer side. Copies stored samples and zero-fills any
    // shortfall; returns how many frames came from stored data.
    UInt64 Read(Float32* dst, UInt64 frameCount);

    UInt64 Overruns() const;
    UInt64 Underruns() const;

    // Frames currently stored and not yet consumed.
    UInt64 Fill() const;

private:
    UInt64 StorageSamples() const;

    void CopyInto(const Float32* src, UInt64 pos, UInt64 count);
    void CopyFrom(Float32* dst, UInt64 pos, UInt64 count);

    const UInt32 channelCount_;
    std::vector<Float32> storage_;
    std::atomic<UInt64> readCursor_{0};
    std::atomic<UInt64> writeCursor_{0};
    std::atomic<UInt64> overruns_{0};
    std::atomic<UInt64> underruns_{0};
};

} // namespace passthru
