// Host-side tests for the single-UID last-output store. UserDefaults-injection
// pattern; tests the public API: load/save round-trip, nil-clean default,
// set/clear, key isolation across two instances on different keys, lastSeen
// stamp on write.

import Foundation
import XCTest

@testable import PassthruPersistence

final class PersistedLastOutputTests: XCTestCase {

    private func makeDefaults(name: String) -> UserDefaults {
        let suite = "test-\(name)-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testFreshStoreHasNoUID() {
        let store = PersistedLastOutput(defaults: makeDefaults(name: "fresh"))
        XCTAssertNil(store.uid)
    }

    func testSetUIDThenReadBack() {
        let store = PersistedLastOutput(defaults: makeDefaults(name: "set"))
        store.uid = "AppleUSBAudioEngine:uDac:0000:0001"
        XCTAssertEqual(store.uid, "AppleUSBAudioEngine:uDac:0000:0001")
    }

    func testSetUIDStampsLastSeen() {
        let store = PersistedLastOutput(defaults: makeDefaults(name: "stamp"))
        let before = Date()
        store.uid = "uid-A"
        let after = Date()
        XCTAssertNotNil(store.lastSeen)
        XCTAssertGreaterThanOrEqual(store.lastSeen!, before)
        XCTAssertLessThanOrEqual(store.lastSeen!, after)
    }

    func testClearRemovesUID() {
        let store = PersistedLastOutput(defaults: makeDefaults(name: "clear"))
        store.uid = "uid-A"
        store.uid = nil
        XCTAssertNil(store.uid)
    }

    func testRoundTripAcrossInstances() {
        let defaults = makeDefaults(name: "roundtrip")
        let first = PersistedLastOutput(defaults: defaults)
        first.uid = "uid-shared"
        let second = PersistedLastOutput(defaults: defaults)
        XCTAssertEqual(second.uid, "uid-shared")
    }

    func testTwoStoresDoNotInterfere() {
        let a = PersistedLastOutput(defaults: makeDefaults(name: "a"))
        let b = PersistedLastOutput(defaults: makeDefaults(name: "b"))
        a.uid = "uid-A"
        b.uid = "uid-B"
        XCTAssertEqual(a.uid, "uid-A")
        XCTAssertEqual(b.uid, "uid-B")
    }

    func testTouchRefreshesLastSeenWithoutChangingUID() {
        let store = PersistedLastOutput(defaults: makeDefaults(name: "touch"))
        store.uid = "uid-A"
        let original = store.lastSeen
        Thread.sleep(forTimeInterval: 0.01)
        store.touch()
        XCTAssertEqual(store.uid, "uid-A")
        XCTAssertNotNil(original)
        XCTAssertNotNil(store.lastSeen)
        XCTAssertGreaterThan(store.lastSeen!, original!)
    }
}
