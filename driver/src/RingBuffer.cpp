// Lock-free SPSC ring of interleaved Float32 samples - see RingBuffer.hpp for
// the contract. Behaviour-preserving extraction of the ring that used to live
// in Driver.cpp: same cursor arithmetic, same drop and fill policies, same
// call ordering.

#include "RingBuffer.hpp"

#include <algorithm>
#include <cstring>

namespace passthru {

RingBuffer::RingBuffer(UInt32 channelCount, UInt64 capacityFrames)
    : channelCount_(channelCount),
      storage_(static_cast<size_t>(channelCount * capacityFrames), 0.0f)
{
}

void RingBuffer::Write(const Float32* data, UInt64 frameCount)
{
    const UInt64 samples = frameCount * channelCount_;
    const UInt64 wr = writeCursor_.load(std::memory_order_relaxed);
    UInt64 rd = readCursor_.load(std::memory_order_acquire);

    // Overrun: drop oldest frames to make room; newest audio wins.
    const UInt64 capacity = StorageSamples();
    if (wr - rd + samples > capacity) {
        rd = wr + samples - capacity;
        readCursor_.store(rd, std::memory_order_release);
        overruns_.fetch_add(1, std::memory_order_relaxed);
    }

    CopyInto(data, wr % StorageSamples(), samples);
    writeCursor_.store(wr + samples, std::memory_order_release);
}

UInt64 RingBuffer::Read(Float32* dst, UInt64 frameCount)
{
    const UInt64 want = frameCount * channelCount_;
    const UInt64 rd = readCursor_.load(std::memory_order_relaxed);
    const UInt64 wr = writeCursor_.load(std::memory_order_acquire);

    const UInt64 avail = std::min(wr - rd, want);
    if (avail != 0) {
        CopyFrom(dst, rd % StorageSamples(), avail);
        readCursor_.store(rd + avail, std::memory_order_release);
    }
    if (avail != want) {
        underruns_.fetch_add(1, std::memory_order_relaxed);
        memset(dst + avail, 0, (want - avail) * sizeof(Float32));
    }
    return avail;
}

UInt64 RingBuffer::Overruns() const
{
    return overruns_.load(std::memory_order_relaxed);
}

UInt64 RingBuffer::Underruns() const
{
    return underruns_.load(std::memory_order_relaxed);
}

UInt64 RingBuffer::Fill() const
{
    const UInt64 samples =
        writeCursor_.load(std::memory_order_acquire) -
        readCursor_.load(std::memory_order_acquire);
    return samples / channelCount_;
}

UInt64 RingBuffer::StorageSamples() const
{
    return storage_.size();
}

void RingBuffer::CopyInto(const Float32* src, UInt64 pos, UInt64 count)
{
    const UInt64 first = std::min(count, StorageSamples() - pos);
    std::memcpy(storage_.data() + pos, src, first * sizeof(Float32));
    std::memcpy(storage_.data(), src + first, (count - first) * sizeof(Float32));
}

void RingBuffer::CopyFrom(Float32* dst, UInt64 pos, UInt64 count)
{
    const UInt64 first = std::min(count, StorageSamples() - pos);
    std::memcpy(dst, storage_.data() + pos, first * sizeof(Float32));
    std::memcpy(dst + first, storage_.data(), (count - first) * sizeof(Float32));
}

} // namespace passthru
