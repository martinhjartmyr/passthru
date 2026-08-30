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
        rememberedUID: String? = nil,
        isRouted: Bool = false
    ) -> RoutingInputs {
        RoutingInputs(
            diff: diff,
            uidByID: uidByID,
            currentSinkID: currentSinkID,
            currentSinkName: currentSinkName,
            currentSinkUID: currentSinkUID,
            rememberedUID: rememberedUID,
            isRouted: isRouted)
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
            rememberedUID: udacUID))
        XCTAssertEqual(result, .noop)
    }

    func testNoopWhenUnrelatedDeviceDisappears() {
        let result = RoutingDecider.decide(makeInputs(
            diff: DeviceListDiff(added: [], removed: [sennheiser]),
            uidByID: [builtIn: builtInUID],
            currentSinkID: builtIn,
            rememberedUID: udacUID))
        XCTAssertEqual(result, .noop)
    }

    // MARK: hot-plug case

    func testSwitchWhenRememberedDeviceJustAppeared() {
        let result = RoutingDecider.decide(makeInputs(
            diff: DeviceListDiff(added: [udac], removed: []),
            uidByID: [builtIn: builtInUID, udac: udacUID],
            currentSinkID: builtIn,
            rememberedUID: udacUID))
        XCTAssertEqual(result, .switchTo(uid: udacUID))
    }

    func testNoopWhenRememberedDeviceAlreadyCurrent() {
        // udac is current sink AND it just appeared. Don't switch to itself.
        let result = RoutingDecider.decide(makeInputs(
            diff: DeviceListDiff(added: [udac], removed: []),
            uidByID: [udac: udacUID],
            currentSinkID: udac,
            rememberedUID: udacUID))
        XCTAssertEqual(result, .noop)
    }

    // MARK: already-present-at-launch case

    func testSwitchWhenRememberedDeviceIsPresentAndRouting() {
        // udac is present but not current; routing is on. Switch.
        let result = RoutingDecider.decide(makeInputs(
            uidByID: [builtIn: builtInUID, udac: udacUID],
            currentSinkID: builtIn,
            rememberedUID: udacUID,
            isRouted: true))
        XCTAssertEqual(result, .switchTo(uid: udacUID))
    }

    func testNoopWhenRememberedDeviceIsPresentButNotRouted() {
        // udac is present but routing is off. Don't surprise the user.
        let result = RoutingDecider.decide(makeInputs(
            uidByID: [builtIn: builtInUID, udac: udacUID],
            currentSinkID: builtIn,
            rememberedUID: udacUID,
            isRouted: false))
        XCTAssertEqual(result, .noop)
    }

    func testNoopWhenRememberedDeviceIsPresentAndAlreadyCurrent() {
        // udac is current AND present, but no diff event.
        let result = RoutingDecider.decide(makeInputs(
            uidByID: [udac: udacUID],
            currentSinkID: udac,
            rememberedUID: udacUID,
            isRouted: true))
        XCTAssertEqual(result, .noop)
    }

    // MARK: disconnect case

    func testFallbackWhenCurrentSinkDisappearsAndRememberedPresent() {
        let result = RoutingDecider.decide(makeInputs(
            diff: DeviceListDiff(added: [], removed: [builtIn]),
            uidByID: [udac: udacUID],
            currentSinkID: builtIn,
            currentSinkName: "Built-in Speaker",
            currentSinkUID: builtInUID,
            rememberedUID: udacUID))
        XCTAssertEqual(result, .fallbackTo(uid: udacUID))
    }

    func testStopAndErrorWhenCurrentSinkDisappearsWithNoRemembered() {
        let result = RoutingDecider.decide(makeInputs(
            diff: DeviceListDiff(added: [], removed: [builtIn]),
            uidByID: [:],
            currentSinkID: builtIn,
            currentSinkName: "Built-in Speaker",
            currentSinkUID: builtInUID,
            rememberedUID: nil))
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
            rememberedUID: udacUID))
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
            rememberedUID: udacUID,
            isRouted: true))
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
            rememberedUID: udacUID,
            isRouted: true))
        XCTAssertEqual(result, .fallbackTo(uid: udacUID))
    }
}
