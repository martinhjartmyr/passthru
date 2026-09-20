// Governed SPSC ring bridging the virtual device clock and the physical
// DAC clock. Plain ring behaviour matches the driver-side contract
// (overrun drops oldest, underrun zero-fills, both counted); on top sits
// a fill governor that pins latency near a target so unreconciled clock
// rates cannot accumulate backlog as audible delay.
//
// Correction policy:
// - Until the ring has primed to target once, the governor is dormant:
//   reads serve silence, no sample is ever duplicated to fake a pre-fill.
// - While |fill - target| <= band, nothing happens - hysteresis keeps the
//   seam rare under realistic ppm-scale drift.
// - Past the band, the producer side restores fill to exactly target by
//   dropping the oldest excess samples or repeating its newest samples -
//   the minimal correction that re-pins, never more.
//
// Steady-state note: corrections restore at write time, then the consumer
// immediately drains one chunk, so observed fill wanders roughly inside
// [target - readChunk, target + band] rather than sitting exactly on
// target. Size target accordingly.
//
// Threading: one unfair lock around index math + copy. Realtime-safe
// usage: no allocation after init.

import Foundation
import os

public enum GovernedRingError: Error {
    case capacityNotPowerOfTwo
    case targetExceedsCapacity
}

public struct GovernorConfig {
    public var targetSamples: Int
    public var bandSamples: Int

    public init(targetSamples: Int, bandSamples: Int) {
        precondition(targetSamples > 0, "target must be positive")
        precondition(bandSamples >= 0, "band must not be negative")
        self.targetSamples = targetSamples
        self.bandSamples = bandSamples
    }
}

public final class GovernedRing {
    public struct Stats: Equatable {
        public var overruns = 0
        public var underruns = 0
        public var driftDrops = 0      // samples discarded to re-pin (excess)
        public var driftRepeats = 0    // samples duplicated to re-pin (deficit)
        public var corrections = 0     // drop or repeat events
    }

    /// One-lock snapshot for telemetry readers: consistent positions, fill,
    /// and counters, however the IO threads are mid-cycle.
    public struct Telemetry {
        public var stats = Stats()
        public var writtenSamples = 0
        public var readSamples = 0
        public var fillSamples = 0
        public var fillMilliseconds = 0.0
    }

    private let capacity: Int
    private let mask: Int
    private let sampleRate: Double
    private let channelCount: Int
    private let config: GovernorConfig
    private var storage: UnsafeMutablePointer<Float>
    private let cursor = OSAllocatedUnfairLock<Cursor>(initialState: Cursor())
    private struct Cursor {
        var head = 0   // next write position (samples), producer-owned
        var tail = 0   // next read position (samples), consumer-owned
        var primed = false
        var overruns = 0
        var underruns = 0
        var driftDrops = 0
        var driftRepeats = 0
        var corrections = 0
    }

    public init(capacitySamples: Int,
                sampleRate: Double,
                channelCount: Int = 2,
                config: GovernorConfig) throws {
        guard capacitySamples.nonzeroBitCount == 1 else {
            throw GovernedRingError.capacityNotPowerOfTwo
        }
        guard config.targetSamples < capacitySamples else {
            throw GovernedRingError.targetExceedsCapacity
        }
        precondition(channelCount > 0, "channelCount must be positive")
        capacity = capacitySamples
        mask = capacitySamples - 1
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.config = config
        storage = UnsafeMutablePointer<Float>.allocate(capacity: capacitySamples)
        storage.initialize(repeating: 0, count: capacitySamples)
    }

    deinit {
        storage.deinitialize(count: capacity)
        storage.deallocate()
    }

    /// Producer side. Applies the governor after appending; returns samples
    /// actually stored from `samples`.
    @discardableResult
    public func write(_ samples: UnsafePointer<Float>, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return cursor.withLock { c in
            let used = c.head - c.tail
            if used + count > capacity {
                c.tail += used + count - capacity
                c.overruns += 1
            }
            copyIntoBuffer(from: samples, startAt: c.head & mask, count: count)
            c.head += count

            govern(&c)
            return count
        }
    }

    /// Consumer side. Fills `count` samples; serves pure silence until the
    /// ring has primed to target once - priming shortfall is not an
    /// underrun. The governor deliberately does not run here: corrections
    /// are producer actions so consumer timing stays untouched.
    @discardableResult
    public func read(into out: UnsafeMutablePointer<Float>, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return cursor.withLock { c in
            if !c.primed {
                guard c.head - c.tail >= config.targetSamples else {
                    out.initialize(repeating: 0, count: count)
                    return 0
                }
                c.primed = true
            }

            let available = min(c.head - c.tail, count)
            if available > 0 {
                copyFromBuffer(to: out, startAt: c.tail & mask, count: available)
                c.tail += available
            }
            if available < count {
                out.advanced(by: available).initialize(repeating: 0, count: count - available)
                c.underruns += 1
            }
            return available
        }
    }

    /// Drops buffered content and returns to the priming state: a new output
    /// device is a new clock, and equilibrium should start at target, not
    /// from the previous clock's backlog.
    public func reset() {
        cursor.withLock { c in
            c.tail = c.head
            c.primed = false
        }
    }

    // MARK: Telemetry

    public func stats() -> Stats {
        cursor.withLock { Stats(
            overruns: $0.overruns,
            underruns: $0.underruns,
            driftDrops: $0.driftDrops,
            driftRepeats: $0.driftRepeats,
            corrections: $0.corrections) }
    }

    public func telemetry() -> Telemetry {
        cursor.withLock { t in
            var telemetry = Telemetry()
            telemetry.stats = Stats(
                overruns: t.overruns,
                underruns: t.underruns,
                driftDrops: t.driftDrops,
                driftRepeats: t.driftRepeats,
                corrections: t.corrections)
            telemetry.writtenSamples = t.head
            telemetry.readSamples = t.tail
            telemetry.fillSamples = t.head - t.tail
            telemetry.fillMilliseconds = Self.milliseconds(
                samples: t.head - t.tail, channelCount: channelCount, sampleRate: sampleRate)
            return telemetry
        }
    }

    /// Samples currently stored: the pipeline's buffered-latency amount.
    public func fillSamples() -> Int {
        cursor.withLock { $0.head - $0.tail }
    }

    public func fillMilliseconds() -> Double {
        Self.milliseconds(samples: fillSamples(),
                          channelCount: channelCount,
                          sampleRate: sampleRate)
    }

    public func capacityMilliseconds() -> Double {
        Self.milliseconds(samples: capacity,
                          channelCount: channelCount,
                          sampleRate: sampleRate)
    }

    /// Interleaved samples are frames times channels; latency maths is per
    /// frame, so the channel count divides here exactly once.
    private static func milliseconds(samples: Int, channelCount: Int, sampleRate: Double) -> Double {
        Double(samples) / Double(channelCount) / sampleRate * 1000
    }

    /// Monotonic totals; their delta plus net corrections is the direct
    /// inter-clock position read.
    public func totalWrittenSamples() -> Int {
        cursor.withLock { $0.head }
    }

    public func totalReadSamples() -> Int {
        cursor.withLock { $0.tail }
    }

    // MARK: Governor

    /// Caller holds the lock. Restores pin-at-target past the hysteresis band;
    /// dormant until the ring has primed so startup never duplicates audio.
    private func govern(_ c: inout Cursor) {
        guard c.primed else { return }
        let fill = c.head - c.tail
        let excess = fill - config.targetSamples
        if excess > config.bandSamples {
            c.tail += excess
            c.driftDrops += excess
            c.corrections += 1
            return
        }
        let deficit = -excess
        if deficit > config.bandSamples {
            let repeatCount = min(deficit, fill, capacity - fill)
            guard repeatCount > 0 else { return }
            copyWithinStorage(from: (c.head - repeatCount) & mask,
                              to: c.head & mask,
                              count: repeatCount)
            c.head += repeatCount
            c.driftRepeats += repeatCount
            c.corrections += 1
        }
    }

    // MARK: Wrapped copies

    private func copyIntoBuffer(from source: UnsafePointer<Float>, startAt: Int, count: Int) {
        let firstChunk = min(count, capacity - startAt)
        storage.advanced(by: startAt).update(from: source, count: firstChunk)
        if count > firstChunk {
            storage.update(from: source.advanced(by: firstChunk), count: count - firstChunk)
        }
    }

    private func copyFromBuffer(to destination: UnsafeMutablePointer<Float>, startAt: Int, count: Int) {
        let firstChunk = min(count, capacity - startAt)
        destination.update(from: storage.advanced(by: startAt), count: firstChunk)
        if count > firstChunk {
            destination.advanced(by: firstChunk).update(from: storage, count: count - firstChunk)
        }
    }

    /// Copies `count` samples within storage (assign semantics, overlap-safe).
    private func copyWithinStorage(from sourcePos: Int, to destPos: Int, count: Int) {
        var remaining = count
        var src = sourcePos % capacity
        var dst = destPos % capacity
        while remaining > 0 {
            let chunk = min(remaining, capacity - src, capacity - dst)
            storage.advanced(by: dst).update(from: storage.advanced(by: src), count: chunk)
            src = (src + chunk) % capacity
            dst = (dst + chunk) % capacity
            remaining -= chunk
        }
    }
}
