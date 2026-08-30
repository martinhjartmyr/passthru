// Host-side tests for the device-list diff helper. Pure set arithmetic;
// CoreAudio-free.

import XCTest

@testable import PassthruPersistence

final class DeviceListDiffTests: XCTestCase {

    func testEmptyToEmptyIsNoOp() {
        let result = DeviceListDiffer.diff(previous: [], current: [])
        XCTAssertEqual(result, DeviceListDiff(added: [], removed: []))
    }

    func testNewIDAppearsInAdded() {
        let result = DeviceListDiffer.diff(previous: [1, 2], current: [1, 2, 3])
        XCTAssertEqual(result, DeviceListDiff(added: [3], removed: []))
    }

    func testOldIDDisappearsInRemoved() {
        let result = DeviceListDiffer.diff(previous: [1, 2, 3], current: [1, 2])
        XCTAssertEqual(result, DeviceListDiff(added: [], removed: [3]))
    }

    func testSameSetProducesNoChanges() {
        let result = DeviceListDiffer.diff(previous: [1, 2, 3], current: [3, 2, 1])
        XCTAssertEqual(result, DeviceListDiff(added: [], removed: []))
    }

    func testAddAndRemoveInSameCall() {
        let result = DeviceListDiffer.diff(previous: [1, 2], current: [2, 3])
        XCTAssertEqual(result, DeviceListDiff(added: [3], removed: [1]))
    }

    func testAllReplaced() {
        let result = DeviceListDiffer.diff(previous: [1, 2], current: [3, 4])
        XCTAssertEqual(result, DeviceListDiff(added: [3, 4], removed: [1, 2]))
    }
}
