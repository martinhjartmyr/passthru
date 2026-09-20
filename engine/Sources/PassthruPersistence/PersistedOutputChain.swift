// Ordered, most-recent-first chain of real-output UIDs, capped at five.
//
// The chain is the persistence representation of the user's output
// history. New writes go through `record(uid:)` which enforces
// promote-if-present semantics and trims to the cap. The Passthru
// virtual-device UID is rejected at both read and write, defending
// the "Passthru is never the engine sink" invariant at the
// persistence seam itself.
//
// One-shot migration from the legacy single-UID slot
// (`persisted-last-output.v1.uid`) runs on first launch with the
// chain key absent and the legacy key present. The legacy UID is
// prepended to the chain (or dropped if it equals the Passthru
// UID), the legacy key is deleted, and the chain key is written.
// After migration the legacy key is gone and only the chain key
// remains. Subsequent launches see the chain key and skip
// migration. On a fresh install (no legacy key) the migration is a
// no-op.

import Foundation

public final class PersistedOutputChain {
    public static let cap: Int = 5

    /// The Passthru virtual device's UID as defined by the driver
    /// (driver/src/Driver.cpp: DeviceUID = "dev.passthru.virtual").
    public static let passthruUID: String = "dev.passthru.virtual"

    private static let chainKey = "persisted-output-chain.v1.uids"
    private static let legacyUIDKey = "persisted-last-output.v1.uid"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func read() -> [String] {
        migrateIfNeeded()
        guard let stored = defaults.array(forKey: Self.chainKey) as? [String] else {
            return []
        }
        return stored.filter { $0 != Self.passthruUID }
    }

    public func record(uid: String) {
        guard uid != Self.passthruUID else { return }

        var chain = read()
        chain.removeAll { $0 == uid }
        chain.insert(uid, at: 0)
        if chain.count > Self.cap {
            chain = Array(chain.prefix(Self.cap))
        }
        defaults.set(chain, forKey: Self.chainKey)
    }

    /// Runs once per launch: if the chain key is absent and the legacy
    /// key is present, the legacy UID is prepended to the chain (or
    /// dropped if it equals the Passthru UID), the legacy key is
    /// deleted, and the chain key is written. Idempotent: subsequent
    /// calls see the chain key and skip.
    private func migrateIfNeeded() {
        guard defaults.array(forKey: Self.chainKey) == nil else { return }
        guard let legacy = defaults.string(forKey: Self.legacyUIDKey) else { return }
        defaults.removeObject(forKey: Self.legacyUIDKey)
        guard legacy != Self.passthruUID else { return }
        defaults.set([legacy], forKey: Self.chainKey)
    }
}
