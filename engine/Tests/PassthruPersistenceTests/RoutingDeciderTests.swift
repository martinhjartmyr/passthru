// Host-side tests for the routing decision. Pure function; the engine
// injects the current state and we assert the intended action. No audio
// hardware, no IO, no time.

import XCTest

@testable import PassthruPersistence

private let udac: UInt32 = 100
private let sennheiser: UInt32 = 200
private let bose: UInt32 = 300
private let builtIn: UInt32 = 400

private let udacUID = "AppleUSBAudioEngine:uDAC-3:0000:0001"
private let sennheiserUID = "AppleUSBAudioEngine:Sennheiser:0000:0002"
private let boseUID = "AppleBT:Bose QC35"
private let builtInUID = "AppleHDA:BuiltInSpeaker"

final class RoutingDeciderTests: XCTestCase {

    private func makeInputs(
        diff: DeviceListDiff = DeviceListDiff(added: [], removed: []),
        uidByID: [UInt32: String] = [:],
        currentSinkID: UInt32? = nil,
        currentSinkName: String? = nil,
        currentSinkUID: String? = nil,
        rememberedChain: [String] = [],
        rememberedChainHead: String? = nil
    ) -> RoutingInputs {
        if let head = rememberedChainHead {
            return makeInputs(
                diff: diff,
                uidByID: uidByID,
                currentSinkID: currentSinkID,
                currentSinkName: currentSinkName,
                currentSinkUID: currentSinkUID,
                rememberedChain: [head])
        }
        return RoutingInputs(
            diff: diff,
            uidByID: uidByID,
            currentSinkID: currentSinkID,
            currentSinkName: currentSinkName,
            currentSinkUID: currentSinkUID,
            rememberedChain: rememberedChain)
    }

    // MARK: noop cases

    func testNoopWhenNothingHappened() {
        let result = RoutingDecider.decide(makeInputs(
            uidByID: [builtIn: builtInUID],
            currentSinkID: builtIn))
        XCTAssertEqual(result, .noop)
    }

    func testNoopWhenUnrelatedDeviceAppears() {
        let result = RoutingDecider.decide(makeInputs(
            diff: DeviceListDiff(added: [sennheiser], removed: []),
            uidByID: [builtIn: builtInUID, sennheiser: sennheiserUID],
            currentSinkID: builtIn,
            rememberedChainHead: udacUID))
        XCTAssertEqual(result, .noop)
    }

    func testNoopWhenUnrelatedDeviceDisappears() {
        let result = RoutingDecider.decide(makeInputs(
            diff: DeviceListDiff(added: [], removed: [sennheiser]),
            uidByID: [builtIn: builtInUID],
            currentSinkID: builtIn,
            rememberedChainHead: udacUID))
        XCTAssertEqual(result, .noop)
    }

    // MARK: hot-plug case

    func testSwitchWhenRememberedDeviceJustAppeared() {
        let result = RoutingDecider.decide(makeInputs(
            diff: DeviceListDiff(added: [udac], removed: []),
            uidByID: [builtIn: builtInUID, udac: udacUID],
            currentSinkID: builtIn,
            rememberedChainHead: udacUID))
        XCTAssertEqual(result, .switchTo(uid: udacUID))
    }

    func testNoopWhenRememberedDeviceAlreadyCurrent() {
        // udac is current sink AND it just appeared. Don't switch to itself.
        let result = RoutingDecider.decide(makeInputs(
            diff: DeviceListDiff(added: [udac], removed: []),
            uidByID: [udac: udacUID],
            currentSinkID: udac,
            rememberedChainHead: udacUID))
        XCTAssertEqual(result, .noop)
    }

    // MARK: already-present-at-launch case
    //
    // With the engine no longer writing the system default output, the
    // "auto-promote a remembered device at launch" branch was removed:
    // the user picks the system default themselves, and the engine only
    // reacts to actual hot-plug diffs and the reconnect path below.

    // MARK: disconnect case

    func testFallbackWhenCurrentSinkDisappearsAndRememberedPresent() {
        let result = RoutingDecider.decide(makeInputs(
            diff: DeviceListDiff(added: [], removed: [builtIn]),
            uidByID: [udac: udacUID],
            currentSinkID: builtIn,
            currentSinkName: "Built-in Speaker",
            currentSinkUID: builtInUID,
            rememberedChainHead: udacUID))
        XCTAssertEqual(result, .fallbackTo(uid: udacUID))
    }

    func testStopAndErrorWhenCurrentSinkDisappearsWithNoRemembered() {
        let result = RoutingDecider.decide(makeInputs(
            diff: DeviceListDiff(added: [], removed: [builtIn]),
            uidByID: [:],
            currentSinkID: builtIn,
            currentSinkName: "Built-in Speaker",
            currentSinkUID: builtInUID,
            rememberedChainHead: nil))
        XCTAssertEqual(result, .stopAndError(name: "Built-in Speaker"))
    }

    func testNoopWhenRememberedDeviceIsTheOneThatDisappeared() {
        // udac (current sink) disappeared, and it WAS the remembered one.
        // No fallback would be useful. Noop.
        let result = RoutingDecider.decide(makeInputs(
            diff: DeviceListDiff(added: [], removed: [udac]),
            uidByID: [bose: boseUID],
            currentSinkID: udac,
            currentSinkName: "uDAC-3",
            currentSinkUID: udacUID,
            rememberedChainHead: udacUID))
        XCTAssertEqual(result, .noop)
    }

    // MARK: priority

    func testHotPlugTakesPriorityOverAlreadyPresent() {
        // udac is present and also in added (listener fired after it
        // became present). Decision should still be switchTo.
        let result = RoutingDecider.decide(makeInputs(
            diff: DeviceListDiff(added: [udac], removed: []),
            uidByID: [builtIn: builtInUID, udac: udacUID],
            currentSinkID: builtIn,
            rememberedChainHead: udacUID))
        XCTAssertEqual(result, .switchTo(uid: udacUID))
    }

    func testDisconnectTakesPriorityOverAlreadyPresent() {
        // Two events at once: udac added, builtIn removed (current sink).
        // Disconnect case should fire (current sink gone), not switchTo.
        let result = RoutingDecider.decide(makeInputs(
            diff: DeviceListDiff(added: [udac], removed: [builtIn]),
            uidByID: [udac: udacUID],
            currentSinkID: builtIn,
            currentSinkName: "Built-in Speaker",
            currentSinkUID: builtInUID,
            rememberedChainHead: udacUID))
        XCTAssertEqual(result, .fallbackTo(uid: udacUID))
    }

    // MARK: chain walk on disconnect

    func testChainPicksFirstOnlineEntryWhenHeadOffline() {
        // uDAC (head) is offline; Sennheiser (next) is online. uDAC
        // disappears. Fall back to Sennheiser.
        let result = RoutingDecider.decide(makeInputs(
            diff: DeviceListDiff(added: [], removed: [udac]),
            uidByID: [sennheiser: sennheiserUID],
            currentSinkID: udac,
            currentSinkName: "uDAC-3",
            currentSinkUID: udacUID,
            rememberedChain: [udacUID, sennheiserUID]))
        XCTAssertEqual(result, .fallbackTo(uid: sennheiserUID))
    }

    func testChainWalksToFirstOnlineWhenHeadAlsoOffline() {
        // uDAC head and Sennheiser second are both offline; Bose is online.
        // Fall back to Bose, skipping both offline entries.
        let result = RoutingDecider.decide(makeInputs(
            diff: DeviceListDiff(added: [], removed: [udac]),
            uidByID: [bose: boseUID],
            currentSinkID: udac,
            currentSinkName: "uDAC-3",
            currentSinkUID: udacUID,
            rememberedChain: [udacUID, sennheiserUID, boseUID]))
        XCTAssertEqual(result, .fallbackTo(uid: boseUID))
    }

    func testChainAllOfflineFallsThroughToStopAndError() {
        let result = RoutingDecider.decide(makeInputs(
            diff: DeviceListDiff(added: [], removed: [udac]),
            uidByID: [:],
            currentSinkID: udac,
            currentSinkName: "uDAC-3",
            currentSinkUID: udacUID,
            rememberedChain: [udacUID, sennheiserUID, boseUID]))
        XCTAssertEqual(result, .stopAndError(name: "uDAC-3"))
    }

    func testChainEmptyFallsThroughToStopAndError() {
        // Belt-and-braces: a chain of [] (not just chain-of-nothing-online)
        // still falls through. Mirrors the no-remembered behaviour.
        let result = RoutingDecider.decide(makeInputs(
            diff: DeviceListDiff(added: [], removed: [udac]),
            uidByID: [sennheiser: sennheiserUID],
            currentSinkID: udac,
            currentSinkName: "uDAC-3",
            currentSinkUID: udacUID,
            rememberedChain: []))
        XCTAssertEqual(result, .stopAndError(name: "uDAC-3"))
    }

    func testChainSkipsPassthruUIDAndPicksNextEntry() {
        // Chain has Passthru UID as head (shouldn't be, but defensively).
        // Decider filters it and picks the next online entry.
        let result = RoutingDecider.decide(makeInputs(
            diff: DeviceListDiff(added: [], removed: [udac]),
            uidByID: [sennheiser: sennheiserUID],
            currentSinkID: udac,
            currentSinkName: "uDAC-3",
            currentSinkUID: udacUID,
            rememberedChain: ["dev.passthru.virtual", sennheiserUID]))
        XCTAssertEqual(result, .fallbackTo(uid: sennheiserUID))
    }

    func testChainOnlyPassthruFallsThroughToStopAndError() {
        // Chain of [Passthru] filters down to []. Stop and error.
        let result = RoutingDecider.decide(makeInputs(
            diff: DeviceListDiff(added: [], removed: [udac]),
            uidByID: [sennheiser: sennheiserUID],
            currentSinkID: udac,
            currentSinkName: "uDAC-3",
            currentSinkUID: udacUID,
            rememberedChain: ["dev.passthru.virtual"]))
        XCTAssertEqual(result, .stopAndError(name: "uDAC-3"))
    }

    func testChainOfflineAndPassthruSkippedPicksOnlineEntry() {
        // uDAC (head) offline; Passthru (next, defensive) filtered; Bose
        // (third) online. Fall back to Bose.
        let result = RoutingDecider.decide(makeInputs(
            diff: DeviceListDiff(added: [], removed: [udac]),
            uidByID: [bose: boseUID],
            currentSinkID: udac,
            currentSinkName: "uDAC-3",
            currentSinkUID: udacUID,
            rememberedChain: [udacUID, "dev.passthru.virtual", boseUID]))
        XCTAssertEqual(result, .fallbackTo(uid: boseUID))
    }

    func testChainWalksPastHeadWhenHeadIsDisappearedDevice() {
        // uDAC (current sink and head) disappears. With a second chain
        // entry behind it that IS online, walk past the disappeared head
        // and fall back to Sennheiser.
        let result = RoutingDecider.decide(makeInputs(
            diff: DeviceListDiff(added: [], removed: [udac]),
            uidByID: [sennheiser: sennheiserUID],
            currentSinkID: udac,
            currentSinkName: "uDAC-3",
            currentSinkUID: udacUID,
            rememberedChain: [udacUID, sennheiserUID]))
        XCTAssertEqual(result, .fallbackTo(uid: sennheiserUID))
    }

    // MARK: reconnect case (laptop wake, prior torn-down state)

    func testReconnectAfterDisconnectWithNilSink() {
        // Engine is torn down (currentSinkID nil). uDAC just reappeared
        // and is the chain head. Promote it.
        let result = RoutingDecider.decide(makeInputs(
            diff: DeviceListDiff(added: [udac], removed: []),
            uidByID: [udac: udacUID],
            currentSinkID: nil,
            rememberedChainHead: udacUID))
        XCTAssertEqual(result, .switchTo(uid: udacUID))
    }

    func testReconnectPromotesLiveChainEntryEvenWithoutAddEvent() {
        // The wake case where the listener coalesces: the device is
        // already online when the decider runs (no add event), the
        // engine is torn down, and the chain still has the entry.
        // The hot-plug branch is gated on `diff.added.contains(...)`,
        // so it does not fire here. The reconnect branch is not.
        let result = RoutingDecider.decide(makeInputs(
            uidByID: [udac: udacUID],
            currentSinkID: nil,
            rememberedChainHead: udacUID))
        XCTAssertEqual(result, .switchTo(uid: udacUID))
    }

    func testReconnectWalksChainWhenHeadIsOffline() {
        // uDAC (head) is offline; Bose (next) is online. Wake brought
        // Bose back. Promote Bose.
        let result = RoutingDecider.decide(makeInputs(
            diff: DeviceListDiff(added: [bose], removed: []),
            uidByID: [bose: boseUID],
            currentSinkID: nil,
            rememberedChain: [udacUID, boseUID]))
        XCTAssertEqual(result, .switchTo(uid: boseUID))
    }

    func testReconnectNoOnlineRememberedFallsThroughToNoop() {
        // No chain entry is online and currentSinkID is nil. The
        // disconnect branch requires a current sink, so it doesn't
        // fire; no reconnect target exists, so the reconnect branch
        // doesn't fire either. Result: noop. The engine is in a
        // known torn-down state; a subsequent tick (or a Retry click
        // that re-runs the decider) is the recovery path.
        let result = RoutingDecider.decide(makeInputs(
            diff: DeviceListDiff(added: [sennheiser], removed: []),
            uidByID: [sennheiser: sennheiserUID],
            currentSinkID: nil,
            rememberedChain: [udacUID]))
        XCTAssertEqual(result, .noop)
    }
}
