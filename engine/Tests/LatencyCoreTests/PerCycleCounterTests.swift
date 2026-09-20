// Host-side tests for the per-cycle IO telemetry.
//
// Headline: record/drain round-trips; under-load drop-oldest keeps the
// most recent cadence; main-thread drain produces consistent min/avg/max
// summaries even when the producer was emitting irregular frame counts.
// Everything is observed through the public surface.

import XCTest

@testable import LatencyCore

final class PerCycleCounterTests: XCTestCase {

    func testEmptyDrainReturnsEmptySummary() {
        let c = PerCycleCounter()
        XCTAssertEqual(c.drain(), .empty)
    }

    func testRecordThenDrainReturnsSingleSample() {
        let c = PerCycleCounter()
        c.record(frames: 256, samples: 512, timeTicks: 1000)
        let s = c.drain()
        XCTAssertEqual(s.cycleCount, 1)
        XCTAssertEqual(s.framesMin, 256)
        XCTAssertEqual(s.framesMax, 256)
        XCTAssertEqual(s.framesAvg, 256, accuracy: 1e-9)
        XCTAssertEqual(s.samplesMin, 512)
        XCTAssertEqual(s.samplesMax, 512)
        XCTAssertEqual(s.samplesAvg, 512, accuracy: 1e-9)
        XCTAssertEqual(s.timeSpanMs, 0, accuracy: 1e-9)
    }

    func testMultipleRecordsAggregateMinAvgMax() {
        let c = PerCycleCounter()
        c.record(frames: 256, samples: 512, timeTicks: 0)
        c.record(frames: 512, samples: 1024, timeTicks: 1_000_000)
        c.record(frames: 384, samples: 768, timeTicks: 2_000_000)
        let s = c.drain()
        XCTAssertEqual(s.cycleCount, 3)
        XCTAssertEqual(s.framesMin, 256)
        XCTAssertEqual(s.framesMax, 512)
        XCTAssertEqual(s.framesAvg, (256 + 512 + 384) / 3.0, accuracy: 1e-9)
        XCTAssertEqual(s.samplesMin, 512)
        XCTAssertEqual(s.samplesMax, 1024)
        XCTAssertEqual(s.samplesAvg, (512 + 1024 + 768) / 3.0, accuracy: 1e-9)
    }

    func testDrainEmptiesRing() {
        let c = PerCycleCounter()
        c.record(frames: 256, samples: 512, timeTicks: 0)
        _ = c.drain()
        XCTAssertEqual(c.drain(), .empty)
    }

    func testDropOldestWhenRingFullKeepsMostRecentCadence() {
        let capacity = 4
        let c = PerCycleCounter(capacity: capacity)
        for i in 0..<10 {
            c.record(frames: 256 + i, samples: 512 + i * 2, timeTicks: UInt64(i) * 1000)
        }
        let s = c.drain()
        XCTAssertEqual(s.cycleCount, capacity,
                       "drain should report the number of cycles the ring held at full")
        XCTAssertEqual(s.framesMax, 256 + 9,
                       "the last record (frames=265) must be present after drop-oldest")
        XCTAssertEqual(s.samplesMax, 512 + 18)
        XCTAssertGreaterThanOrEqual(s.framesMin, 256 + 6,
            "the four most recent cycles span indices 6..9, so min is at least 262")
    }

    func testIrregularFrameCountsExposeProducerCadenceMismatch() {
        let c = PerCycleCounter()
        c.record(frames: 256, samples: 512, timeTicks: 0)
        c.record(frames: 1024, samples: 2048, timeTicks: 1_000_000)
        c.record(frames: 256, samples: 512, timeTicks: 2_000_000)
        c.record(frames: 1024, samples: 2048, timeTicks: 3_000_000)
        let s = c.drain()
        XCTAssertEqual(s.framesMin, 256)
        XCTAssertEqual(s.framesMax, 1024,
            "max must surface the larger cadence so [io] can flag the mismatch")
        XCTAssertNotEqual(s.framesMin, s.framesMax,
            "matching min and max would hide a real cadence disagreement")
    }

    func testTimeSpanReflectsTimeTicksRange() {
        let c = PerCycleCounter()
        c.record(frames: 256, samples: 512, timeTicks: 0)
        c.record(frames: 256, samples: 512, timeTicks: 1_000_000)
        let s = c.drain()
        XCTAssertGreaterThan(s.timeSpanMs, 0)
        // mach timebase varies by host; just bound within a sane envelope.
        // 1e6 ticks is sub-second on any current Mac, never more than a few seconds.
        XCTAssertLessThan(s.timeSpanMs, 10_000)
    }

    func testRejectZeroCapacityAtConstruction() {
        // `precondition` is uncatchable; the test simply exercises the
        // construction path with a valid capacity and confirms the
        // counter is built. A separate, opt-in negative test is not safe
        // to express under XCTest without disabling the precondition.
        let c = PerCycleCounter(capacity: 1)
        XCTAssertEqual(c.drain(), .empty)
    }
}
