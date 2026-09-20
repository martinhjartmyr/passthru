// Contract tests for the 'lapv' seam on the Swift side. Consumes the same
// checked-in golden vectors as the driver's GainStoreTests
// (contract/lapv/, see SCHEMA.md there): parsing must yield equal tables,
// encoding must reproduce equivalent payloads.

import Foundation
import XCTest

@testable import GainChannel

private typealias Entry = GainChannel.Entry

final class LapvContractTests: XCTestCase {

    private var fixtureDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/GainChannelTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // engine package root
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("contract/lapv", isDirectory: true)
    }

    private func fixtureData(_ name: String) throws -> Data {
        try Data(contentsOf: fixtureDir.appendingPathComponent(name))
    }

    /// Zero-byte files stand for the null payload (XML plists cannot
    /// represent CF null - see SCHEMA.md).
    private func loadFixture(_ name: String) throws -> (payload: Any?, isNull: Bool) {
        let data = try fixtureData(name)
        if data.isEmpty {
            return (nil, true)
        }
        let plist = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil)
        return (plist, false)
    }

    private let validFixtures: [String: [Entry]] = [
        "empty-table.plist": [],
        "single-pid-entry.plist": [Entry(pid: 1234, gain: 0.25)],
        "single-bundle-entry.plist": [Entry(bundleID: "com.apple.Music", gain: 0.5)],
        "pid-entry-plus-bundle-fallback.plist": [
            Entry(pid: 1234, bundleID: "com.apple.Music", gain: 0.25),
            Entry(bundleID: "com.apple.Music", gain: 0.75),
        ],
        "gain-clamp-boundaries.plist": [
            Entry(pid: 111, gain: GainChannel.minGain),
            Entry(pid: 222, gain: GainChannel.maxGain),
        ],
    ]

    private let invalidFixtures = [
        "invalid-non-array-root.plist",
        "invalid-non-dict-element.plist",
        "invalid-non-numeric-gain.plist",
        "invalid-boolean-gain.plist",
    ]

    // MARK: Parse: same bytes -> equal table

    func testValidFixturesDecodeToExpectedTables() throws {
        for (name, expected) in validFixtures {
            let fixture = try loadFixture(name)
            XCTAssertFalse(fixture.isNull, name)
            XCTAssertEqual(GainChannel.decode(fixture.payload), expected, name)
        }
    }

    func testNullFixtureClearsTable() throws {
        let fixture = try loadFixture("null-clears-table.plist")
        XCTAssertTrue(fixture.isNull, "the null fixture is a zero-byte file")
        XCTAssertEqual(GainChannel.decode(fixture.payload), [])
    }

    func testInvalidFixturesRejectWholePayload() throws {
        for name in invalidFixtures {
            let fixture = try loadFixture(name)
            XCTAssertFalse(fixture.isNull, name)
            XCTAssertNil(GainChannel.decode(fixture.payload), name)
        }
    }

    // MARK: Emit: serializer reproduces equivalent payloads

    func testEncodeReproducesEquivalentPayloads() throws {
        for (name, _) in validFixtures {
            let fixture = try loadFixture(name)
            guard let decoded = GainChannel.decode(fixture.payload) else {
                XCTFail("\(name): should have decoded")
                continue
            }
            let emitted = GainChannel.encode(decoded)
            XCTAssertTrue((emitted as NSArray).isEqual(to: fixture.payload as? [Any]),
                "\(name): emit(parse(F)) equals F semantically")

            // And through real plist bytes again, still equal.
            let data = try PropertyListSerialization.data(
                fromPropertyList: emitted, format: .xml, options: 0)
            let reparsed = try PropertyListSerialization.propertyList(
                from: data, options: [], format: nil)
            XCTAssertTrue((reparsed as! NSObject).isEqual(fixture.payload as! NSObject),
                "\(name): serialized bytes parse back to F")
        }
    }
}
