// Host-side tests for the gain-channel client.
// Covers payload encode/decode round-trips and the constants' consistency;
// runs without audio hardware.

import CoreAudio
import XCTest

@testable import GainChannel

private typealias Entry = GainChannel.Entry

final class GainChannelTests: XCTestCase {

    // MARK: Constants (single source)

    func testSelectorPacksLapv() {
        // 'l'=0x6C 'a'=0x61 'p'=0x70 'v'=0x76 - the same literal the driver
        // registers (Driver.cpp kAppGainsSelector).
        XCTAssertEqual(GainChannel.selector, AudioObjectPropertySelector(0x6C61_7076))
    }

    func testGainRangeMatchesDriver() {
        XCTAssertEqual(GainChannel.minGain, 0.0)
        XCTAssertEqual(GainChannel.maxGain, 4.0)
        XCTAssertLessThan(GainChannel.minGain, GainChannel.maxGain)
    }

    func testClampMatchesDriverSemantics() {
        XCTAssertEqual(GainChannel.clamped(-1.0), GainChannel.minGain)
        XCTAssertEqual(GainChannel.clamped(8.0), GainChannel.maxGain)
        XCTAssertEqual(GainChannel.clamped(0.5), 0.5)
        XCTAssertEqual(GainChannel.clamped(1.0), 1.0)
        XCTAssertEqual(GainChannel.clamped(Double.nan), 1.0)
    }

    // MARK: Encode

    func testEncodeBuildsDriverPayloadShape() {
        let payload = GainChannel.encode([
            Entry(pid: 1234, gain: 0.25),
            Entry(bundleID: "com.apple.Music", gain: 0.5),
        ])

        XCTAssertEqual(payload.count, 2)
        XCTAssertEqual(payload[0]["pid"] as? Int, 1234)
        XCTAssertNil(payload[0]["bundle-id"])
        XCTAssertEqual(payload[0]["gain"] as? Double, 0.25)
        XCTAssertEqual(payload[1]["bundle-id"] as? String, "com.apple.Music")
        XCTAssertNil(payload[1]["pid"])
        XCTAssertEqual(payload[1]["gain"] as? Double, 0.5)
    }

    func testEncodeOmitsInertPidKeys() {
        let payload = GainChannel.encode([Entry(pid: -5, bundleID: nil, gain: 2.0)])
        XCTAssertNil(payload[0]["pid"])
    }

    // MARK: Decode / round-trip

    func testRoundTripPreservesEntries() {
        let entries = [
            Entry(pid: 1234, gain: 0.25),
            Entry(bundleID: "com.apple.Music", gain: 0.5),
        ]
        XCTAssertEqual(GainChannel.decode(GainChannel.encode(entries)), entries)
    }

    func testDecodeOfNilClearsTable() {
        XCTAssertEqual(GainChannel.decode(nil), [])
    }

    func testDecodeAcceptsEmptyArray() {
        XCTAssertEqual(GainChannel.decode([[String: Any]]()), [])
    }

    func testDecodeSkipsInertEntries() {
        let decoded = GainChannel.decode([["gain": Double(0.3)]])
        XCTAssertEqual(decoded, [])
    }

    func testDecodeTreatsNonPositivePidAsNotKeyed() {
        let decoded = GainChannel.decode([["pid": Int(-3), "bundle-id": "x", "gain": Double(2)]])
        XCTAssertEqual(decoded, [Entry(bundleID: "x", gain: 2)])
    }

    func testDecodeRejectsNonArrayRoot() {
        XCTAssertNil(GainChannel.decode("scalar"))
        XCTAssertNil(GainChannel.decode(["not": "an array"]))
    }

    func testDecodeRejectsNonDictElement() {
        XCTAssertNil(GainChannel.decode(["a string"]))
    }

    func testDecodeRejectsMissingOrNonNumericGain() {
        XCTAssertNil(GainChannel.decode([["pid": Int(1)]]))
        XCTAssertNil(GainChannel.decode([["pid": Int(1), "gain": "loud"]]))
    }

    func testDecodeRejectsWrongTypedKeysAndBooleans() {
        XCTAssertNil(GainChannel.decode([["pid": "1234", "gain": Double(1)]]))
        XCTAssertNil(GainChannel.decode([["bundle-id": 99, "gain": Double(1)]]))
        XCTAssertNil(GainChannel.decode([["pid": Int(1), "gain": true]]))
    }

    func testDecodeClampsIntoAcceptedRange() {
        let decoded = GainChannel.decode([
            ["pid": Int(1), "gain": Double(-1)],
            ["pid": Int(2), "gain": Double(9)],
        ])
        XCTAssertEqual(decoded, [
            Entry(pid: 1, gain: GainChannel.minGain),
            Entry(pid: 2, gain: GainChannel.maxGain),
        ])
    }
}
