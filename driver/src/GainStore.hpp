// Per-app gain table.
//
// Holds process-ID-to-gain and bundle-ID-to-gain pairs delivered by clients
// through a custom Core Audio property ('lapv') on the device object.
//
// Threading contract:
// - SetFromPlist/CopyPlist/EntryCount/Revision run on plugin dispatch threads
//   (non-realtime).
// - GainFor() runs on realtime IO threads. Readers take an immutable snapshot
//   via std::atomic_load on a shared_ptr (C++17-compatible), so they never
//   block on writers and never observe a partially built table.

#pragma once

#include <CoreFoundation/CoreFoundation.h>

#include <unistd.h>

#include <atomic>
#include <memory>
#include <string>
#include <vector>

namespace passthru {

struct AppGainEntry
{
    pid_t pid = 0;          // 0 = entry is not pid-keyed
    std::string bundleId;   // empty = entry is not bundle-keyed
    Float32 gain = 1.0f;
};

class GainStore
{
public:
    static constexpr Float32 MinGain = 0.0f;
    static constexpr Float32 MaxGain = 4.0f;

    // Replace the whole table from a CFPropertyList payload ('lapv').
    // The schema - entry shape, precedence, clamping, accept/reject rules -
    // lives in contract/lapv/SCHEMA.md beside the golden-vector plists that
    // test/GainStoreTests.cpp grades this parser against.
    bool SetFromPlist(CFPropertyListRef value);

    // Serialize current table in the same shape SetFromPlist accepts.
    // Returns a +1 reference the caller must CFRelease().
    CFPropertyListRef CopyPlist() const;

    // Realtime thread. Exact pid match wins; otherwise the first pure
    // bundle-keyed entry (no pid) matching the client's bundle ID; otherwise
    // unity. Pid-keyed entries apply exclusively to their own process.
    // Never blocks on writers.
    Float32 GainFor(pid_t pid, const std::string& bundleId) const;

    size_t EntryCount() const;

    // Bumped on every accepted update; lets the watchdog log only changes.
    UInt64 Revision() const
    {
        return revision_.load(std::memory_order_relaxed);
    }

private:
    struct Snapshot
    {
        std::vector<AppGainEntry> entries;
    };

    std::shared_ptr<const Snapshot> AcquireSnapshot() const
    {
        return std::atomic_load(&snapshot_);
    }

    std::shared_ptr<const Snapshot> snapshot_; // accessed via std::atomic_load/store
    std::atomic<UInt64> revision_{0};
};

} // namespace passthru
