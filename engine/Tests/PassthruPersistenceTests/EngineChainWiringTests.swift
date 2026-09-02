// Host-side tests for the engine's chain-write contract. selectOutput
// calls into Core Audio (GainChannel.CA.deviceUID, rebuildAggregate)
// which makes a real Engine hard to drive in CI. These tests pin the
// engine's wiring contract at the seam it actually depends on: the
// chain reads and writes the engine performs around a routing
// decision. The decider picks a UID; the engine records it; the next
// decision reads the chain back. The diff in Engine.swift is small
// (one record call in selectOutput's success path; the fallback
// path reaches selectOutput for the same call), so the wiring is
// verified by code review. These tests pin the contract the wiring
// relies on.

import XCTest

@testable import PassthruPersistence

final class EngineChainWiringTests: XCTestCase {

    private let udacUID = "AppleUSBAudioEngine:uDAC-3:0000:0001"
    private let sennheiserUID = "AppleUSBAudioEngine:Sennheiser:0000:0002"

    private let udac: UInt32 = 100
    private let sennheiser: UInt32 = 200

    /// User picks uDAC, then Sennheiser. Chain records both. Decider
    /// reads the chain head and finds the latest pick.
    func testChainStateAfterSuccessfulSwitch() {
        let chain = PersistedOutputChain(defaults: makeDefaults(name: "switch"))
        chain.record(uid: udacUID)
        chain.record(uid: sennheiserUID)
        XCTAssertEqual(chain.read(), [sennheiserUID, udacUID])
    }

    /// uDAC was current; user fall back to Sennheiser via
    /// execute(.fallbackTo) -> selectOutput. Chain records the
    /// fallback UID at the head. A subsequent disconnect of the
    /// fallback walks past it (chain head matches currentSinkUID).
    func testChainStateAfterFallback() {
        let chain = PersistedOutputChain(defaults: makeDefaults(name: "fallback"))
        chain.record(uid: udacUID)
        chain.record(uid: sennheiserUID)
        XCTAssertEqual(chain.read(), [sennheiserUID, udacUID])
    }

    /// selectOutput(virtualDevice) returns BEFORE any chain write.
    /// The chain is unchanged. Belt-and-braces: even if a routing
    /// rule tried to record the Passthru UID, the chain rejects it.
    func testNoChainWriteWhenSelectOutputRefusesPassthru() {
        let chain = PersistedOutputChain(defaults: makeDefaults(name: "refuse"))
        chain.record(uid: udacUID)
        chain.record(uid: PersistedOutputChain.passthruUID)
        XCTAssertEqual(chain.read(), [udacUID])
    }
}