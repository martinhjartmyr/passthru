// Regression tests for the playing-app row identity contract.
//
// The host crash (Bad pointer dereference inside SwiftUI's
// ForEachState.LazyEdits during a graph flush on the main run loop)
// was caused by `PlayingApp.id` being a recycled PID. When the engine
// switched its rendering sink, Core Audio's property-listener storm
// landed, the per-app mixer republished `engine.playingApps`, and a
// helper that had just re-entered with the same PID it held moments
// before tripped SwiftUI's diff between disposed and re-created
// lazy state for the same id.
//
// These tests pin the new rule: identity is the bundle ID for bundled
// apps (so a helper relaunch with a fresh PID still maps to the same
// row and slider), and `pid + seq` for unnamed helpers (so each
// "join" is a distinct row in a fast-changing helper cloud).

import XCTest
@testable import Passthru

final class PlayingAppIdentityTests: XCTestCase {

    func test_bundledApp_sameBundle_differentPIDs_collapsesToSameIdentity() {
        let a = PlayingApp(
            pid: 9409, bundleID: "com.google.Chrome.helper",
            name: "Google Chrome Helper", isHelper: true,
            iconPath: nil, gain: 0.71,
            identity: .bundle("com.google.Chrome.helper"))
        let b = PlayingApp(
            pid: 12345, bundleID: "com.google.Chrome.helper",
            name: "Google Chrome Helper", isHelper: true,
            iconPath: nil, gain: 0.71,
            identity: .bundle("com.google.Chrome.helper"))
        XCTAssertEqual(a.id, b.id)
    }

    func test_unnamedHelper_samePID_differentSeq_areDistinctRows() {
        let a = PlayingApp(
            pid: 58317, bundleID: "", name: "Helper (pid 58317)",
            isHelper: true, iconPath: nil, gain: 1.0,
            identity: .helper(pid: 58317, seq: 1))
        let b = PlayingApp(
            pid: 58317, bundleID: "", name: "Helper (pid 58317)",
            isHelper: true, iconPath: nil, gain: 1.0,
            identity: .helper(pid: 58317, seq: 2))
        XCTAssertNotEqual(a.id, b.id)
    }

    func test_bundledAndHelper_identitiesDoNotCollide() {
        let bundled = AppIdentity.bundle("com.example.app")
        let helper = AppIdentity.helper(pid: 1, seq: 1)
        XCTAssertNotEqual(bundled, helper)
    }

    func test_equatable_isAllFields() {
        let a = PlayingApp(
            pid: 1, bundleID: "b", name: "n", isHelper: false,
            iconPath: "/a", gain: 0.5,
            identity: .bundle("b"))
        var b = a
        XCTAssertEqual(a, b)
        b = PlayingApp(
            pid: 1, bundleID: "b", name: "n", isHelper: false,
            iconPath: "/a", gain: 0.6,
            identity: .bundle("b"))
        XCTAssertNotEqual(a, b)
    }

    func test_setAppGain_acceptsRowWithMatchingIdentityEvenIfPIDChanged() {
        let engine = Engine()
        let oldRow = PlayingApp(
            pid: 9409, bundleID: "com.google.Chrome.helper",
            name: "Google Chrome Helper", isHelper: true,
            iconPath: nil, gain: 0.71,
            identity: .bundle("com.google.Chrome.helper"))
        let newRow = PlayingApp(
            pid: 12345, bundleID: "com.google.Chrome.helper",
            name: "Google Chrome Helper", isHelper: true,
            iconPath: nil, gain: 0.71,
            identity: .bundle("com.google.Chrome.helper"))
        engine.injectPlayingAppsForTest([newRow])
        engine.setAppGain(oldRow, percent: 80.0)
        let call = engine.lastPerAppGainCall
        XCTAssertNotNil(call)
        XCTAssertEqual(call?.percent ?? 0, 80.0, accuracy: 0.0001)
    }

    func test_setAppGain_rejectsUnknownIdentity() {
        let engine = Engine()
        let row = PlayingApp(
            pid: 1, bundleID: "b", name: "n", isHelper: false,
            iconPath: nil, gain: 1.0,
            identity: .bundle("b"))
        engine.setAppGain(row, percent: 80.0)
        XCTAssertNil(engine.lastPerAppGainCall)
    }
}
