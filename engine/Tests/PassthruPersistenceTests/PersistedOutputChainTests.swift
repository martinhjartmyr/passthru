// Host-side tests for the ordered output-chain store. UserDefaults-injection
// pattern; tests the public API: empty default, single record, promote-if-
// present semantics, cap at five, Passthru UID rejected on write, Passthru
// UID rejected on read, duplicate write does not grow, round-trip across
// instances, isolation across two stores.

import Foundation
import XCTest

@testable import PassthruPersistence

final class PersistedOutputChainTests: XCTestCase {

    private let udacUID = "AppleUSBAudioEngine:uDAC-3:0000:0001"
    private let sennheiserUID = "AppleUSBAudioEngine:Sennheiser:0000:0002"
    private let boseUID = "AppleBT:Bose QC35"
    private let builtInUID = "AppleHDA:BuiltInSpeaker"
    private let headphonesUID = "AppleUSBAudioEngine:HD600:0000:0003"

    func testFreshStoreReadsEmpty() {
        let chain = PersistedOutputChain(defaults: makeDefaults(name: "fresh"))
        XCTAssertEqual(chain.read(), [])
    }

    func testRecordPrependsToEmptyChain() {
        let chain = PersistedOutputChain(defaults: makeDefaults(name: "prepend"))
        chain.record(uid: udacUID)
        XCTAssertEqual(chain.read(), [udacUID])
    }

    func testRecordPromotesIfPresent() {
        let chain = PersistedOutputChain(defaults: makeDefaults(name: "promote"))
        chain.record(uid: sennheiserUID)
        chain.record(uid: boseUID)
        chain.record(uid: udacUID)
        chain.record(uid: sennheiserUID)
        XCTAssertEqual(chain.read(), [sennheiserUID, udacUID, boseUID])
    }

    func testRecordCapsAtFive() {
        let chain = PersistedOutputChain(defaults: makeDefaults(name: "cap"))
        let uids = [udacUID, sennheiserUID, boseUID, builtInUID, headphonesUID, "uid-six"]
        for uid in uids {
            chain.record(uid: uid)
        }
        let stored = chain.read()
        XCTAssertEqual(stored.count, 5)
        XCTAssertEqual(stored, ["uid-six", headphonesUID, builtInUID, boseUID, sennheiserUID])
    }

    func testRecordRejectsPassthruUID() {
        let chain = PersistedOutputChain(defaults: makeDefaults(name: "reject-write"))
        chain.record(uid: PersistedOutputChain.passthruUID)
        XCTAssertEqual(chain.read(), [])
    }

    func testReadFiltersPersistedPassthruUID() {
        let defaults = makeDefaults(name: "reject-read")
        defaults.set([PersistedOutputChain.passthruUID, udacUID], forKey: "persisted-output-chain.v1.uids")
        let chain = PersistedOutputChain(defaults: defaults)
        XCTAssertEqual(chain.read(), [udacUID])
    }

    func testRecordRejectsPassthruUIDButKeepsEarlierEntries() {
        let chain = PersistedOutputChain(defaults: makeDefaults(name: "reject-mixed"))
        chain.record(uid: udacUID)
        chain.record(uid: PersistedOutputChain.passthruUID)
        XCTAssertEqual(chain.read(), [udacUID])
    }

    func testDuplicateRecordDoesNotGrow() {
        let chain = PersistedOutputChain(defaults: makeDefaults(name: "dup"))
        chain.record(uid: udacUID)
        chain.record(uid: udacUID)
        chain.record(uid: udacUID)
        XCTAssertEqual(chain.read(), [udacUID])
    }

    func testRoundTripAcrossInstances() {
        let defaults = makeDefaults(name: "roundtrip")
        let first = PersistedOutputChain(defaults: defaults)
        first.record(uid: udacUID)
        first.record(uid: sennheiserUID)
        let second = PersistedOutputChain(defaults: defaults)
        XCTAssertEqual(second.read(), [sennheiserUID, udacUID])
    }

    func testTwoStoresDoNotInterfere() {
        let a = PersistedOutputChain(defaults: makeDefaults(name: "a"))
        let b = PersistedOutputChain(defaults: makeDefaults(name: "b"))
        a.record(uid: udacUID)
        b.record(uid: boseUID)
        XCTAssertEqual(a.read(), [udacUID])
        XCTAssertEqual(b.read(), [boseUID])
    }
}
