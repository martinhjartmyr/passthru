// Per-cycle IO telemetry. The realtime thread calls `record(frames:samples:)`;
// the main-thread tick calls `drain()`. The producer never blocks: on a full
// ring it overwrites the oldest entry (drop-oldest), preserving the most
// recent sample of cadence.
//
// Threading: one unfair lock around the ring state, mirroring GovernedRing's
// pattern. Realtime-safe usage: no allocation after init.

import Darwin
import Foundation
import os

public struct CycleSample: Equatable {
    public let cycle: UInt64
    public let frames: Int
    public let samples: Int
    public let timeTicks: UInt64
}

public struct CycleSummary: Equatable {
    public let cycleCount: Int
    public let framesMin: Int
    public let framesAvg: Double
    public let framesMax: Int
    public let samplesMin: Int
    public let samplesAvg: Double
    public let samplesMax: Int
    public let timeSpanMs: Double

    public static let empty = CycleSummary(
        cycleCount: 0,
        framesMin: 0, framesAvg: 0, framesMax: 0,
        samplesMin: 0, samplesAvg: 0, samplesMax: 0,
        timeSpanMs: 0)
}

public final class PerCycleCounter {
    private struct Ring {
        var storage: [CycleSample]
        var head: Int = 0
        var tail: Int = 0
        var count: Int = 0

        init(capacity: Int) {
            storage = Array(repeating: CycleSample(cycle: 0, frames: 0, samples: 0, timeTicks: 0),
                             count: capacity)
        }
    }

    private let lock = OSAllocatedUnfairLock<Ring>(initialState: Ring(capacity: 64))
    private var cycleCounter: UInt64 = 0

    public init(capacity: Int = 64) {
        precondition(capacity > 0, "capacity must be positive")
        lock.withLock { r in
            r.storage = Array(repeating:
                CycleSample(cycle: 0, frames: 0, samples: 0, timeTicks: 0),
                count: capacity)
            r.head = 0
            r.tail = 0
            r.count = 0
        }
    }

    /// Producer side (realtime IO thread). Drops the oldest sample if the
    /// ring is full so cadence information is never silently lost.
    public func record(frames: Int, samples: Int, timeTicks: UInt64) {
        cycleCounter &+= 1
        let entry = CycleSample(
            cycle: cycleCounter, frames: frames, samples: samples, timeTicks: timeTicks)
        lock.withLock { r in
            r.storage[r.head] = entry
            r.head = (r.head + 1) % r.storage.count
            if r.count == r.storage.count {
                r.tail = (r.tail + 1) % r.storage.count
            } else {
                r.count += 1
            }
        }
    }

    /// Consumer side (main-thread tick). Drains the ring and returns a
    /// summary. The ring is empty after the call.
    public func drain() -> CycleSummary {
        lock.withLock { r -> CycleSummary in
            let n = r.count
            guard n > 0 else { return .empty }
            var framesMin = Int.max
            var framesMax = 0
            var framesSum = 0
            var samplesMin = Int.max
            var samplesMax = 0
            var samplesSum = 0
            var firstTicks: UInt64 = 0
            var lastTicks: UInt64 = 0
            for i in 0..<n {
                let s = r.storage[r.tail]
                r.tail = (r.tail + 1) % r.storage.count
                if s.frames < framesMin { framesMin = s.frames }
                if s.frames > framesMax { framesMax = s.frames }
                framesSum += s.frames
                if s.samples < samplesMin { samplesMin = s.samples }
                if s.samples > samplesMax { samplesMax = s.samples }
                samplesSum += s.samples
                if i == 0 { firstTicks = s.timeTicks }
                lastTicks = s.timeTicks
            }
            r.count = 0
            let spanNs = Self.ticksToNanoseconds(lastTicks) - Self.ticksToNanoseconds(firstTicks)
            return CycleSummary(
                cycleCount: n,
                framesMin: framesMin,
                framesAvg: Double(framesSum) / Double(n),
                framesMax: framesMax,
                samplesMin: samplesMin,
                samplesAvg: Double(samplesSum) / Double(n),
                samplesMax: samplesMax,
                timeSpanMs: Double(spanNs) / 1_000_000.0)
        }
    }

    private static let timebaseLock = OSAllocatedUnfairLock<mach_timebase_info_data_t>(
        initialState: mach_timebase_info_data_t(numer: 0, denom: 0))

    private static func ticksToNanoseconds(_ ticks: UInt64) -> UInt64 {
        let info = timebaseLock.withLock { lk -> mach_timebase_info_data_t in
            if lk.denom == 0 {
                var tmp = mach_timebase_info_data_t()
                mach_timebase_info(&tmp)
                lk.numer = tmp.numer
                lk.denom = tmp.denom
            }
            return mach_timebase_info_data_t(numer: lk.numer, denom: lk.denom)
        }
        if info.denom == 0 { return ticks }
        return ticks &* UInt64(info.numer) / UInt64(info.denom)
    }
}
