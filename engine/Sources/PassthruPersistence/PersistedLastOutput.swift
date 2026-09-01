// Single-UID last-output store.
//
// Truth owner: app side. The menu app already owns UserDefaults, outlives
// coreaudiod reloads, and re-asserts the remembered device at launch. No
// driver change required. Single UID - no growth problem, no expiry needed.

import Foundation

public final class PersistedLastOutput {
    private static let uidKey = "persisted-last-output.v1.uid"
    private static let seenKey = "persisted-last-output.v1.seen"

    private let defaults: UserDefaults
    private let now: () -> Date

    public init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
    }

    public var uid: String? {
        get { defaults.string(forKey: Self.uidKey) }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Self.uidKey)
                defaults.set(now().timeIntervalSinceReferenceDate, forKey: Self.seenKey)
            } else {
                defaults.removeObject(forKey: Self.uidKey)
                defaults.removeObject(forKey: Self.seenKey)
            }
        }
    }

    public var lastSeen: Date? {
        let timestamp = defaults.double(forKey: Self.seenKey)
        guard timestamp > 0 else { return nil }
        return Date(timeIntervalSinceReferenceDate: timestamp)
    }

    public func touch() {
        guard uid != nil else { return }
        defaults.set(now().timeIntervalSinceReferenceDate, forKey: Self.seenKey)
    }
}
