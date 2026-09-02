// Ordered, most-recent-first chain of real-output UIDs, capped at five.
//
// The chain is the next-generation replacement for PersistedLastOutput's
// single-UID slot. The decider's input shape is already an array, so a
// one-element chain is the engine-side bridge from the legacy store. New
// writes go through `record(uid:)` which enforces promote-if-present
// semantics and trims to the cap. The Passthru virtual-device UID is
// rejected at both read and write, defending the "Passthru is never the
// engine sink" invariant at the persistence seam itself.

import Foundation

public final class PersistedOutputChain {
    public static let cap: Int = 5

    /// The Passthru virtual device's UID as defined by the driver
    /// (driver/src/Driver.cpp: DeviceUID = "dev.passthru.virtual").
    public static let passthruUID: String = "dev.passthru.virtual"

    private static let chainKey = "persisted-output-chain.v1.uids"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func read() -> [String] {
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
}
