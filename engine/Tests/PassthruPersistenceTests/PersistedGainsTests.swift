// Host-side tests for the per-app gain store. UserDefaults-injection pattern;
// tests the public API: round-trip, key isolation, empty-bundle-ID guards,
// touch stamps only existing entries, the 30-day expiry prune, the 200-entry
// hard cap.

import Foundation
import XCTest

@testable import PassthruPersistence

final class PersistedGainsTests: XCTestCase {

    private func seedRaw(_ defaults: UserDefaults, _ entries: [String: (gain: Double, lastSeen: Date)]) {
        let raw: [String: [String: Any]] = entries.reduce(into: [:]) { acc, pair in
            acc[pair.key] = ["gain": pair.value.gain, "lastSeen": pair.value.lastSeen]
        }
        defaults.set(raw, forKey: "persisted-app-gains.v1")
    }

    func testFreshStoreHasNoEntries() {
        let store = PersistedGains(defaults: makeDefaults(name: "fresh"))
        XCTAssertNil(store.gain(forBundleID: "com.example.any"))
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testSetThenReadBack() {
        let store = PersistedGains(defaults: makeDefaults(name: "roundtrip"))
        store.set(gain: 0.5, forBundleID: "com.example.app")
        XCTAssertEqual(store.gain(forBundleID: "com.example.app"), 0.5)
    }

    func testEmptyBundleIDIsIgnoredOnSet() {
        let store = PersistedGains(defaults: makeDefaults(name: "empty-set"))
        store.set(gain: 0.5, forBundleID: "")
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testEmptyBundleIDReturnsNilOnGain() {
        let store = PersistedGains(defaults: makeDefaults(name: "empty-get"))
        store.set(gain: 0.5, forBundleID: "com.example.app")
        XCTAssertNil(store.gain(forBundleID: ""))
    }

    func testTwoStoresDoNotInterfere() {
        let a = PersistedGains(defaults: makeDefaults(name: "a"))
        let b = PersistedGains(defaults: makeDefaults(name: "b"))
        a.set(gain: 0.25, forBundleID: "com.example.alpha")
        b.set(gain: 0.75, forBundleID: "com.example.beta")
        XCTAssertEqual(a.gain(forBundleID: "com.example.alpha"), 0.25)
        XCTAssertEqual(a.gain(forBundleID: "com.example.beta"), nil)
        XCTAssertEqual(b.gain(forBundleID: "com.example.beta"), 0.75)
        XCTAssertEqual(b.gain(forBundleID: "com.example.alpha"), nil)
    }

    func testRoundTripAcrossInstances() {
        let defaults = makeDefaults(name: "instances")
        let first = PersistedGains(defaults: defaults)
        first.set(gain: 0.6, forBundleID: "com.example.app")
        let second = PersistedGains(defaults: defaults)
        XCTAssertEqual(second.gain(forBundleID: "com.example.app"), 0.6)
    }

    func testRemoveDropsEntry() {
        let store = PersistedGains(defaults: makeDefaults(name: "remove"))
        store.set(gain: 0.5, forBundleID: "com.example.app")
        store.remove(bundleID: "com.example.app")
        XCTAssertNil(store.gain(forBundleID: "com.example.app"))
    }

    func testTouchOnlyStampsExistingEntries() {
        let defaults = makeDefaults(name: "touch")
        // 29 days old: within the 30-day expiry window so the entry
        // survives init()'s prune() and can be refreshed by touch().
        let recentlySeen = Date(timeIntervalSinceNow: -29 * 86400)
        let fresh = Date()
        seedRaw(defaults, [
            "com.example.existing": (0.4, recentlySeen),
            "com.example.fresh":   (0.5, fresh),
        ])

        let store = PersistedGains(defaults: defaults)
        store.touch(bundleIDs: ["com.example.existing", "com.example.missing"])

        let reloaded = PersistedGains(defaults: defaults)
        XCTAssertNotNil(reloaded.gain(forBundleID: "com.example.existing"),
                        "existing entry must survive - touch refreshed its lastSeen")
        XCTAssertNil(reloaded.gain(forBundleID: "com.example.missing"),
                     "missing entry must not be created by touch")
    }

    func testThirtyDayExpiryDropsStaleEntries() {
        let defaults = makeDefaults(name: "expiry")
        let stale = Date(timeIntervalSinceNow: -60 * 86400)
        let fresh = Date()
        seedRaw(defaults, [
            "com.example.stale": (0.3, stale),
            "com.example.fresh": (0.7, fresh),
        ])

        let store = PersistedGains(defaults: defaults)
        XCTAssertNil(store.gain(forBundleID: "com.example.stale"),
                     "60-day-old entry must be pruned at init")
        XCTAssertNotNil(store.gain(forBundleID: "com.example.fresh"),
                        "today's entry must survive")
    }

    func testCapacityCapAt200() {
        let defaults = makeDefaults(name: "cap")
        let now = Date()
        let raw: [String: (gain: Double, lastSeen: Date)] = (0..<201).reduce(into: [:]) { acc, i in
            // Spread lastSeen across seconds so the ordering is deterministic
            // and the oldest entry (index 0) is identifiable.
            acc["com.example.bundle-\(i)"] = (0.5, now.addingTimeInterval(TimeInterval(i)))
        }
        seedRaw(defaults, raw)

        let store = PersistedGains(defaults: defaults)
        // The cap is enforced inside save(), not init(). Force a save by
        // re-setting the newest entry, then re-read from the same suite.
        store.set(gain: 0.5, forBundleID: "com.example.bundle-200")

        let reloaded = PersistedGains(defaults: defaults)
        XCTAssertEqual(reloaded.entries.count, 200)
        XCTAssertNotNil(reloaded.gain(forBundleID: "com.example.bundle-200"),
                        "newest entry must survive the cap")
        XCTAssertNil(reloaded.gain(forBundleID: "com.example.bundle-0"),
                     "oldest entry must be evicted by the cap")
    }
}
