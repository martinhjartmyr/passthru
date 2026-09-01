// Shared test helper: a fresh UserDefaults suite per call, keyed by test name
// and a UUID so concurrent test classes do not collide on the same suite.
// All persistence tests in this target use this helper instead of duplicating
// the setup locally.

import Foundation
import XCTest

extension XCTestCase {
    func makeDefaults(name: String) -> UserDefaults {
        let suite = "test-\(name)-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
