// Host-side tests for the extracted sample path.
//
// Headline: feeding a known float pattern through ClientGain at exactly
// unity must leave it bit-identical. The rest pins ring policy (overrun
// drop-oldest, underrun zero-fill, wraparound around the capacity boundary)
// without reloading coreaudiod.
//
// Build+run: cmake --build driver/build --target SamplePathTests && \
//            ./driver/build/SamplePathTests
// Exit code 0 = all assertions passed.

#include "../src/ClientGain.hpp"
#include "../src/RingBuffer.hpp"

#include <CoreFoundation/CoreFoundation.h>

#include <cstdio>
#include <cstring>
#include <vector>

using passthru::ClientGain;
using passthru::RingBuffer;

namespace {

int g_failures = 0;

void Check(bool condition, const char* what)
{
    if (condition) {
        std::printf("  ok   %s\n", what);
    } else {
        g_failures++;
        std::printf("  FAIL %s\n", what);
    }
}

bool BuffersEqual(const std::vector<Float32>& a, const std::vector<Float32>& b)
{
    return a.size() == b.size() &&
           std::memcmp(a.data(), b.data(), a.size() * sizeof(Float32)) == 0;
}

std::vector<Float32> ReadFrames(RingBuffer& ring, UInt64 frameCount,
    UInt32 channels)
{
    std::vector<Float32> dst(static_cast<size_t>(frameCount * channels),
        -1.0f); // sentinel: underrun path must zero this, not leave it
    ring.Read(dst.data(), frameCount);
    return dst;
}

} // namespace

int main()
{
    std::printf("SamplePathTests\n");

    // MARK: ClientGain

    {
        // Headline: unity is a bit-identical no-op. Pattern includes
        // denormals, negative zero, and values near the clamp edges -
        // anything a multiply could perturb.
        const std::vector<Float32> pattern = {0.0f, -0.0f, 1e-40f, -1e-40f,
            0.25f, -0.25f, 0.999999f, -0.999999f, 1e20f, -1e20f};
        std::vector<Float32> samples = pattern;

        ClientGain gain;
        gain.Apply(samples.data(),
            static_cast<UInt32>(samples.size()), 1.0f);

        Check(BuffersEqual(samples, pattern),
            "unity leaves every sample bit-identical");
        Check(gain.AppliedBuffers() == 0, "unity does not count as gained");
    }

    {
        ClientGain gain;
        Float32 scaled[] = {0.25f, -0.25f};
        gain.Apply(scaled, 2, 0.5f);
        Check(scaled[0] == 0.125f && scaled[1] == -0.125f,
            "non-unity gain scales every sample");
        Check(gain.AppliedBuffers() == 1, "one non-unity buffer counted");

        Float32 clampedHigh[] = {0.75f};
        Float32 clampedLow[] = {-0.75f};
        gain.Apply(clampedHigh, 1, 2.0f);
        gain.Apply(clampedLow, 1, 2.0f);
        Check(clampedHigh[0] == 1.0f && clampedLow[0] == -1.0f,
            "clamp saturates instead of wrapping");
        Check(gain.AppliedBuffers() == 3, "each non-unity apply counts");

        Float32 zero[] = {0.5f};
        gain.Apply(zero, 0, 2.0f);
        Check(gain.AppliedBuffers() == 3, "empty buffer is not processed");
    }

    // MARK: RingBuffer policies

    {
        RingBuffer ring(1, 4);
        Check(ring.Overruns() == 0 && ring.Underruns() == 0,
            "fresh ring has zero counters");

        auto served = ReadFrames(ring, 3, 1);
        Check(served.size() == 3 && served[0] == 0.0f && served[1] == 0.0f &&
                  served[2] == 0.0f,
            "underrun serves zeros");
        Check(ring.Underruns() == 1 && ring.Overruns() == 0,
            "underrun counted once");
    }

    {
        RingBuffer ring(1, 4);
        const Float32 first[] = {9, 8};
        ring.Write(first, 2);
        auto served = ReadFrames(ring, 4, 1);
        Check(served[0] == 9 && served[1] == 8 && served[2] == 0 &&
                  served[3] == 0,
            "partial data served then zero-filled");
        Check(ring.Underruns() == 1, "shortfall counted");
    }

    {
        // Overrun: drop oldest, newest audio wins.
        RingBuffer ring(1, 4);
        const Float32 older[] = {1, 2, 3, 4};
        const Float32 newer[] = {5, 6, 7};
        ring.Write(older, 4);
        ring.Write(newer, 3);
        Check(ring.Overruns() == 1, "overrun counted");

        auto served = ReadFrames(ring, 4, 1);
        Check(served[0] == 4 && served[1] == 5 && served[2] == 6 &&
                  served[3] == 7,
            "oldest frames dropped, newest preserved");
        Check(ring.Underruns() == 0, "no underrun on full readback");
    }

    {
        // Wraparound: cursor arithmetic across the capacity boundary from
        // both sides, with chunk sizes that do not divide the capacity.
        RingBuffer ring(1, 4);
        bool fifoHolds = true;
        UInt64 expected = 100;
        for (int cycle = 0; cycle < 64; cycle++) {
            std::vector<Float32> out;
            for (UInt64 i = 0; i < 3; i++, expected++) {
                out.push_back(static_cast<Float32>(expected % 128));
            }
            ring.Write(out.data(), out.size());
            auto served = ReadFrames(ring, 3, 1);
            if (!BuffersEqual(served, out)) {
                fifoHolds = false;
                break;
            }
        }
        Check(fifoHolds, "FIFO order survives repeated boundary crossings");
        Check(ring.Overruns() == 0 && ring.Underruns() == 0,
            "clean cycles touch no drop/fill counters");
    }

    {
        // One write straddling the storage end in a single memcpy pair.
        RingBuffer ring(1, 4);
        const Float32 head[] = {1, 2, 3};
        ring.Write(head, 3);
        auto drained = ReadFrames(ring, 3, 1);
        (void)drained; // cursor now at position 3 of 4

        const Float32 spanning[] = {4, 5, 6, 7};
        ring.Write(spanning, 4);
        auto served = ReadFrames(ring, 4, 1);
        Check(served[0] == 4 && served[1] == 5 && served[2] == 6 &&
                  served[3] == 7,
            "single write wrapping the storage end stays intact");
        Check(ring.Overruns() == 0,
            "exact fit does not drop anything");
    }

    {
        // Stereo interleaving: frames keep channel order through the ring.
        RingBuffer ring(2, 8);
        const Float32 stereo[] = {0.10f, 0.90f, 0.20f, 0.80f, 0.30f, 0.70f};
        ring.Write(stereo, 3);
        auto served = ReadFrames(ring, 3, 2);
        Check(BuffersEqual(served, {0.10f, 0.90f, 0.20f, 0.80f, 0.30f, 0.70f}),
            "interleaved channel pairs survive the ring");
    }

    {
        // IO-cycle simulation: producer/consumer ping-pong like the bridge
        // handler does across write/read callbacks.
        RingBuffer ring(2, 16);
        bool clean = true;
        for (UInt32 cycle = 0; cycle < 200 && clean; cycle++) {
            std::vector<Float32> block;
            for (UInt32 s = 0; s < 32; s++) {
                block.push_back(static_cast<Float32>((cycle + s) % 7) / 7.0f);
            }
            ring.Write(block.data(), 16);
            auto served = ReadFrames(ring, 16, 2);
            if (!BuffersEqual(served, block)) {
                clean = false;
            }
        }
        Check(clean, "200 simulated IO cycles deliver identical audio");
        Check(ring.Overruns() == 0 && ring.Underruns() == 0,
            "simulated cycles run clean");
    }

    {
        // The fill getter reports stored FRAMES in flight.
        RingBuffer ring(2, 4); // stereo, capacity 4 frames = 8 samples
        Check(ring.Fill() == 0, "fresh ring reports zero fill");

        const Float32 data[] = {1, 2, 3, 4, 5, 6};
        ring.Write(data, 3);
        Check(ring.Fill() == 3, "fill tracks written frames");

        Float32 sink[8];
        ring.Read(sink, 2);
        Check(ring.Fill() == 1, "fill drops by consumed frames");

        ring.Read(sink, 2); // shortfall path
        Check(ring.Fill() == 0 && ring.Underruns() == 1,
            "fill never counts zero-filled shortfall");
    }

    {
        RingBuffer ring(1, 4);
        const Float32 older[] = {1, 2, 3, 4};
        const Float32 newer[] = {5, 6, 7};
        ring.Write(older, 4);
        ring.Write(newer, 3); // overrun drops oldest
        Check(ring.Fill() == 4, "overrun keeps fill pinned at capacity");
    }

    if (g_failures == 0) {
        std::printf("ALL PASS\n");
        return 0;
    }
    std::printf("%d FAILURE(S)\n", g_failures);
    return 1;
}
