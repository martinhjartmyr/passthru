// Host-side tests for the governed engine ring.
//
// Headline: fill stays pinned near target under injected constant-rate
// mismatch; corrections fire minimally past the hysteresis band; zero
// corrections while deviation stays inside the band; wraparound holds at
// the shrunken production capacity; startup primes on real audio without
// ever duplicating a sample. Everything is observed through write/read
// and stats - no cursor or internals peeking.

import XCTest

@testable import LatencyCore

final class GovernedRingTests: XCTestCase {

    private let capacity = 1 << 13          // 8192 samples = shipped cap
    private let rate = 48000.0
    private let channels = 2
    private let target = 1536
    private let band = 128

    private func makeRing(capacity: Int? = nil,
                          target: Int? = nil,
                          band: Int? = nil) throws -> GovernedRing {
        try GovernedRing(
            capacitySamples: capacity ?? self.capacity,
            sampleRate: rate,
            channelCount: channels,
            config: GovernorConfig(
                targetSamples: target ?? self.target,
                bandSamples: band ?? self.band))
    }

    /// Governor made inert via an unreachable band: plain SPSC behaviour.
    private func makeInertRing(capacity: Int) throws -> GovernedRing {
        try makeRing(capacity: capacity, target: 1, band: capacity)
    }

    /// Prime to target with a real read, exactly like the engine's first IO
    /// cycles: capture accumulates past target, render drains one chunk.
    /// Post-condition: primed, fill exactly at target, nothing duplicated.
    private func prime(_ ring: GovernedRing) {
        let warmup = target + 1024
        ring.write(pattern(warmup, seed: 999), count: warmup)
        var out = [Float](repeating: -1, count: 1024)
        XCTAssertEqual(ring.read(into: &out, count: 1024), 1024,
                       "priming must complete on real audio")
        XCTAssertEqual(out, Array(pattern(warmup, seed: 999).prefix(1024)),
                       "primed audio must not be duplicated")
        XCTAssertEqual(ring.fillSamples(), target, "prime lands exactly on target")
    }

    private func pattern(_ count: Int, seed: Int) -> [Float] {
        (0..<count).map { Float((seed + $0) % 251) / 251.0 }
    }

    // MARK: Priming

    func testReadsServeSilenceUntilPrimedWithoutUnderrunNoise() throws {
        let ring = try makeRing()
        var out = [Float](repeating: -1, count: 512)

        ring.write(pattern(1024, seed: 1), count: 1024) // below target
        let served = ring.read(into: &out, count: 512)
        XCTAssertEqual(served, 0)
        XCTAssertEqual(out, [Float](repeating: 0, count: 512))
        XCTAssertEqual(ring.stats().underruns, 0, "priming is not starvation")
        XCTAssertEqual(ring.stats().corrections, 0, "governor dormant while priming")

        ring.write(pattern(512, seed: 50), count: 512) // reaches target...
        var warm = [Float](repeating: -1, count: 512)
        XCTAssertEqual(ring.read(into: &warm, count: 512), 512)
        XCTAssertEqual(warm, Array(pattern(1024, seed: 1).prefix(512)),
                       "first served audio is the oldest real audio")
    }

    func testGovernorDormantDuringPrimingNeverDuplicates() throws {
        let ring = try makeRing()
        // A single sub-target write would sit far below target: the governor
        // must NOT repeat it up to target before the first read.
        ring.write(pattern(100, seed: 2), count: 100)
        XCTAssertEqual(ring.fillSamples(), 100)
        XCTAssertEqual(ring.stats().driftRepeats, 0)
        XCTAssertEqual(ring.stats().corrections, 0)
    }

    func testResetReturnsToPrimingState() throws {
        let ring = try makeRing()
        try prime(ring)
        ring.reset()

        XCTAssertEqual(ring.fillSamples(), 0, "stale backlog dropped")

        var out = [Float](repeating: -1, count: 256)
        XCTAssertEqual(ring.read(into: &out, count: 256), 0, "silences until refilled")
        XCTAssertEqual(out, [Float](repeating: 0, count: 256))

        ring.write(pattern(target, seed: 3), count: target)
        var warm = [Float](repeating: -1, count: 256)
        XCTAssertEqual(ring.read(into: &warm, count: 256), 256, "primes again")
    }

    // MARK: Carried ring policies (previously pinned only C++-side)

    func testUnderrunServesZerosAndCounts() throws {
        let ring = try makeRing(target: 4, band: 2048)
        ring.write(pattern(4, seed: 4), count: 4)

        var out = [Float](repeating: -1, count: 3)
        XCTAssertEqual(ring.read(into: &out, count: 3), 3) // primes, serves real

        var short = [Float](repeating: -1, count: 4)
        let served = ring.read(into: &short, count: 4) // 1 real + shortfall
        XCTAssertEqual(served, 1)
        XCTAssertEqual(short, [pattern(4, seed: 4)[3], 0, 0, 0])
        XCTAssertEqual(ring.stats().underruns, 1, "post-priming shortfall counts")
        XCTAssertEqual(ring.stats().overruns, 0)
    }

    func testOverrunDropsOldestAndCounts() throws {
        let ring = try makeRing(capacity: 4, target: 2, band: 2048)
        ring.write(pattern(4, seed: 0), count: 4)
        ring.write(pattern(3, seed: 7), count: 3)

        XCTAssertEqual(ring.stats().overruns, 1)
        var out = [Float](repeating: -1, count: 4)
        _ = ring.read(into: &out, count: 4)
        // Overflow by three drops p0..p2: p3 survives, then the new write.
        XCTAssertEqual(out, [pattern(7, seed: 0)[3]] + pattern(3, seed: 7))
    }

    // MARK: Telemetry getters

    func testFillReportingInSamplesAndMilliseconds() throws {
        // Governor inert so the getter, not the policy, is under test.
        let ring = try makeRing(target: 1, band: capacity)
        XCTAssertEqual(ring.fillSamples(), 0)
        XCTAssertEqual(ring.fillMilliseconds(), 0, accuracy: 1e-9)

        ring.write(pattern(1024, seed: 5), count: 1024)
        XCTAssertEqual(ring.fillSamples(), 1024)
        // Interleaved samples: 1024 stereo samples at 48 kHz = 512 frames.
        XCTAssertEqual(ring.fillMilliseconds(), 1024 / 2 / rate * 1000, accuracy: 1e-9)
        XCTAssertEqual(ring.capacityMilliseconds(), Double(capacity) / 2 / rate * 1000, accuracy: 1e-9)
    }

    func testTelemetrySnapshotIsConsistent() throws {
        let ring = try makeRing(target: 1, band: capacity)
        ring.write(pattern(300, seed: 6), count: 300)
        var out = [Float](repeating: 0, count: 100)
        _ = ring.read(into: &out, count: 100)

        let t = ring.telemetry()
        XCTAssertEqual(t.writtenSamples, 300)
        XCTAssertEqual(t.readSamples, 100)
        XCTAssertEqual(t.fillSamples, 200)
        XCTAssertEqual(t.writtenSamples - t.readSamples, t.fillSamples,
                       "written-minus-read is the direct inter-clock delta")
        XCTAssertEqual(t.fillMilliseconds, 200 / 2 / rate * 1000, accuracy: 1e-9)
    }

    func testCumulativePositionsTrackTotalsAndDeltaIsFill() throws {
        let ring = try makeRing(target: 1, band: capacity)
        ring.write(pattern(300, seed: 7), count: 300)
        var out = [Float](repeating: 0, count: 100)
        _ = ring.read(into: &out, count: 100)

        XCTAssertEqual(ring.totalWrittenSamples(), 300)
        XCTAssertEqual(ring.totalReadSamples(), 100)
        XCTAssertEqual(
            ring.totalWrittenSamples() - ring.totalReadSamples(),
            ring.fillSamples())
    }

    // MARK: Hysteresis

    func testNoCorrectionWhileDeviationStaysInsideBand() throws {
        let ring = try makeRing()
        try prime(ring)

        // Matched rates: deviation stays put, deep inside the band...
        for _ in 0..<50 {
            let chunk = pattern(128, seed: 100)
            ring.write(chunk, count: chunk.count)
            var out = [Float](repeating: 0, count: 128)
            _ = ring.read(into: &out, count: 128)
        }
        // ...then one excursion landing exactly at the band edge.
        let boundary = pattern(band, seed: 200)
        ring.write(boundary, count: boundary.count)
        var back = [Float](repeating: 0, count: band)
        _ = ring.read(into: &back, count: band)

        let stats = ring.stats()
        XCTAssertEqual(stats.corrections, 0)
        XCTAssertEqual(stats.driftDrops, 0)
        XCTAssertEqual(stats.driftRepeats, 0)
        XCTAssertEqual(ring.fillSamples(), target)
    }

    func testDeviationExactlyAtBandIsStillInside() throws {
        let ring = try makeRing()
        try prime(ring)
        // One write landing exactly at the boundary: no-correction side.
        ring.write(pattern(band, seed: 8), count: band)

        let stats = ring.stats()
        XCTAssertEqual(stats.corrections, 0)
        XCTAssertEqual(ring.fillSamples(), target + band)
    }

    // MARK: Minimal correction past hysteresis

    func testExcessCorrectionDropsExactlyBackToTarget() throws {
        let ring = try makeRing()
        try prime(ring) // fill exactly at target
        ring.write(pattern(band + 1, seed: 9), count: band + 1) // one past

        let stats = ring.stats()
        XCTAssertEqual(stats.driftDrops, band + 1,
                       "minimal drop restores pin at target, nothing more")
        XCTAssertEqual(stats.corrections, 1)
        XCTAssertEqual(stats.driftRepeats, 0)
        XCTAssertEqual(ring.fillSamples(), target)
    }

    func testShortfallCorrectionRepeatsExactlyBackToTarget() throws {
        let ring = try makeRing()
        try prime(ring) // fill exactly at target
        var out = [Float](repeating: 0, count: 500)
        _ = ring.read(into: &out, count: 500) // deficit 500, past the band
        ring.write(pattern(10, seed: 11), count: 10) // next write observes it

        let stats = ring.stats()
        XCTAssertEqual(stats.driftRepeats, target - (target - 500 + 10),
                       "minimal repeat restores pin at target")
        XCTAssertEqual(stats.corrections, 1)
        XCTAssertEqual(stats.driftDrops, 0)
        XCTAssertEqual(ring.fillSamples(), target)
    }

    func testRepeatClampsToAvailableHistory() throws {
        let ring = try makeRing()
        try prime(ring) // fill 512, primed

        var drain = [Float](repeating: 0, count: 512)
        _ = ring.read(into: &drain, count: 512) // empty, post-prime underrun next
        var sink = [Float](repeating: 0, count: 5000)
        _ = ring.read(into: &sink, count: 5000)
        XCTAssertEqual(ring.stats().underruns, 1)

        ring.write(pattern(10, seed: 12), count: 10)
        // Deficit is huge but only 10 samples of history exist to duplicate.

        XCTAssertEqual(ring.stats().driftRepeats, 10)
        XCTAssertEqual(ring.fillSamples(), 20)
    }

    // MARK: Pinned fill under injected clock mismatch

    func testFillStaysBoundedWhenProducerClockRunsFast() throws {
        let ring = try makeRing()
        try prime(ring)

        var violations = 0
        var fillSum = 0

        // Sustained positive drift: producer writes 1124, consumer reads
        // 1024 per cycle. Post-cycle envelope: [target - R, target + band].
        for cycle in 0..<400 {
            ring.write(pattern(1124, seed: cycle), count: 1124)
            var chunk = [Float](repeating: 0, count: 1024)
            _ = ring.read(into: &chunk, count: 1024)

            let fill = ring.fillSamples()
            if !(target - 1024...target + band).contains(fill) { violations += 1 }
            if cycle >= 100 { fillSum += fill }
        }

        let stats = ring.stats()
        XCTAssertEqual(violations, 0, "governor must bound the envelope")
        XCTAssertEqual(stats.overruns, 0, "governor prevents capacity overflow")
        XCTAssertEqual(stats.underruns, 0)
        XCTAssertGreaterThan(stats.driftDrops, 0, "drift must be reconciled")
        XCTAssertEqual(stats.driftRepeats, 0)

        // Statistical pin: late-session mean sits below target and above
        // one consumed chunk - never creeping back up.
        let mean = Double(fillSum) / 300.0
        XCTAssertGreaterThanOrEqual(mean, Double(target - 1024))
        XCTAssertLessThanOrEqual(mean, Double(target))
    }

    func testConsumerFasterClockRepeatsWithoutStarvation() throws {
        let ring = try makeRing()
        try prime(ring) // fill exactly at target
        // Drain one chunk so the first mismatched write lands inside the
        // band, mirroring the engine's write/read interleaving.
        var headStart = [Float](repeating: 0, count: 1024)
        _ = ring.read(into: &headStart, count: 1024)

        var minFill = Int.max
        var maxFill = 0
        var msViolations = 0

        // Sustained negative drift: producer writes 1024, consumer reads
        // 1124 per cycle. Repeats reconcile; supply must never run dry.
        for cycle in 0..<400 {
            ring.write(pattern(1024, seed: 1000 + cycle), count: 1024)
            var chunk = [Float](repeating: 0, count: 1124)
            _ = ring.read(into: &chunk, count: 1124)

            let fill = ring.fillSamples()
            minFill = min(minFill, fill)
            maxFill = max(maxFill, fill)
            if ring.fillMilliseconds() > 35 { msViolations += 1 }
        }

        let stats = ring.stats()
        XCTAssertEqual(msViolations, 0, "steady state stays under the 40 ms bar")
        XCTAssertGreaterThan(stats.driftRepeats, 0, "deficit drift reconciled")
        XCTAssertEqual(stats.driftDrops, 0)
        XCTAssertEqual(stats.underruns, 0, "no starvation once warmed up")
        XCTAssertGreaterThan(minFill, 0)
        XCTAssertLessThanOrEqual(maxFill, target + band)
        XCTAssertEqual(stats.overruns, 0)
    }

    // MARK: Wraparound at the shrunken production capacity

    func testFIFOOrderSurvivesWraparoundAtShrunkenCapacity() throws {
        let ring = try makeInertRing(capacity: capacity)

        // Chunk sizes that do not divide the capacity, crossing the storage
        // end from both directions over many cycles.
        for cycle in 0..<64 {
            let written = pattern(cycle % 2 == 0 ? 3001 : 1999, seed: cycle * 17)
            ring.write(written, count: written.count)

            var out = [Float](repeating: -1, count: written.count)
            let served = ring.read(into: &out, count: written.count)
            XCTAssertEqual(served, written.count)
            XCTAssertEqual(out, written, "cycle \(cycle): FIFO order broke")
        }

        let stats = ring.stats()
        XCTAssertEqual(stats.corrections, 0)
        XCTAssertEqual(stats.overruns, 0)
        XCTAssertEqual(stats.underruns, 0)
    }

    func testSingleWriteStraddlingStorageEndStaysIntact() throws {
        let ring = try makeInertRing(capacity: capacity)
        // Position the cursor three samples before the storage end.
        ring.write(pattern(8189, seed: 13), count: 8189)
        var drained = [Float](repeating: 0, count: 8189)
        _ = ring.read(into: &drained, count: 8189)

        let spanning = pattern(4096, seed: 14)
        ring.write(spanning, count: spanning.count)

        var out = [Float](repeating: -1, count: spanning.count)
        _ = ring.read(into: &out, count: spanning.count)
        XCTAssertEqual(out, spanning)
    }

    // MARK: Construction contract

    func testRejectsNonPowerOfTwoCapacity() {
        XCTAssertThrowsError(try makeRing(capacity: 8000))
    }

    func testRejectsTargetAtOrAboveCapacity() {
        XCTAssertThrowsError(try makeRing(capacity: 8192, target: 8192))
        XCTAssertThrowsError(try makeRing(capacity: 8192, target: 16384))
    }
}
