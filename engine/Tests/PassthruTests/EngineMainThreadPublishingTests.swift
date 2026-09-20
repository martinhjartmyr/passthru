// Regression tests for the Engine's main-thread publishing rule.
//
// The host crash (NSInternalInconsistencyException via SwiftUI's
// AppDelegate.makeMainMenu, "modification of a menu's items on a
// non-main thread") was caused by @Published writes from eventQueue in
// tick(). These tests pin the rule that all @Published writes go
// through publishOnMain (off-main hops to main, main writes synchronously).
//
// We don't drive tick() itself from a background queue here:
// @testable-importing Passthru brings SwiftUI into the test binary and
// any objectWillChange observation crashes the test runner via the
// same AppKit assertion - just on the test's main thread, which is the
// dispatch main queue, so the off-main hop can't be observed in
// isolation. The two contract tests below, combined with tick()'s
// refactor (no direct @Published assignments remain), prevent the
// regression structurally.

import XCTest
import Combine
@testable import Passthru

final class EngineMainThreadPublishingTests: XCTestCase {

    func test_publishOnMain_fromBackground_hopsToMain() {
        let engine = Engine()
        let exp = expectation(description: "value observed on main")
        var cancellable: AnyCancellable?

        cancellable = engine.$gainPercent
            .dropFirst()
            .sink { newValue in
                XCTAssertTrue(Thread.isMainThread)
                XCTAssertEqual(newValue, 73.0, accuracy: 0.0001)
                exp.fulfill()
            }

        DispatchQueue.global(qos: .utility).async {
            engine.publishOnMain(\.gainPercent, 73.0)
        }

        wait(for: [exp], timeout: 2.0)
        cancellable?.cancel()
    }

    func test_publishOnMain_fromMain_writesSynchronously() {
        let engine = Engine()
        let exp = expectation(description: "immediate sink")
        var cancellable: AnyCancellable?

        cancellable = engine.$gainPercent
            .dropFirst()
            .sink { newValue in
                XCTAssertEqual(newValue, 42.0, accuracy: 0.0001)
                exp.fulfill()
            }

        XCTAssertTrue(Thread.isMainThread)
        engine.publishOnMain(\.gainPercent, 42.0)

        wait(for: [exp], timeout: 1.0)
        cancellable?.cancel()
    }
}
