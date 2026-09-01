// Per-app gain persistence.
//
// Truth owner: THIS app side (not the driver). Reasons:
// - the HAL plugin is sandboxed and dies with coreaudiod reloads; surviving
//   `killall coreaudiod` and reinstalls would need plugin-side file storage,
//   while the menu app already owns UserDefaults and outlives driver churn;
// - the app re-asserts stored gains into the driver on launch and whenever
//   the playing set changes (driver holds only a volatile runtime table).
//
// Keyed by bundle ID because PIDs change between launches; bundle IDs do not.
// Processes without a bundle ID (unnamed helpers) are session-only by design.
//
// Bounded growth: entries not seen playing for 30 days expire; hard cap of
// 200 entries keeps the plist small even under adversarial churn.

import Foundation

public struct PersistedGain: Codable, Equatable {
    public var gain: Double
    public var lastSeen: Date

    public init(gain: Double, lastSeen: Date) {
        self.gain = gain
        self.lastSeen = lastSeen
    }
}

public final class PersistedGains {
    private static let key = "persisted-app-gains.v1"
    private static let expiryDays = 30
    private static let capacity = 200

    private let defaults: UserDefaults
    public private(set) var entries: [String: PersistedGain] = [:]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    public func gain(forBundleID bundleID: String) -> Float? {
        guard !bundleID.isEmpty, let entry = entries[bundleID] else { return nil }
        return Float(entry.gain)
    }

    /// Store/refresh a gain; also stamps lastSeen.
    public func set(gain: Float, forBundleID bundleID: String) {
        guard !bundleID.isEmpty else { return }
        entries[bundleID] = PersistedGain(gain: Double(gain), lastSeen: Date())
        save()
    }

    public func touch(bundleIDs: Set<String>) {
        guard !bundleIDs.isEmpty else { return }
        var dirty = false
        for id in bundleIDs where entries[id] != nil {
            entries[id]?.lastSeen = Date()
            dirty = true
        }
        if dirty { save() }
    }

    public func remove(bundleID: String) {
        guard entries.removeValue(forKey: bundleID) != nil else { return }
        save()
    }

    // MARK: Storage

    private func load() {
        guard let raw = defaults.dictionary(forKey: Self.key) as? [String: [String: Any]] else {
            entries = [:]
            return
        }
        var loaded: [String: PersistedGain] = [:]
        for (id, dict) in raw {
            guard let gain = dict["gain"] as? Double,
                  let seen = dict["lastSeen"] as? Date else { continue }
            loaded[id] = PersistedGain(gain: gain, lastSeen: seen)
        }
        entries = loaded
        prune()
    }

    private func save() {
        prune()
        // Hard cap: keep the most recently seen `capacity` bundles.
        if entries.count > Self.capacity {
            let keep = Set(entries.sorted { $0.value.lastSeen > $1.value.lastSeen }
                .prefix(Self.capacity).map(\.key))
            entries = entries.filter { keep.contains($0.key) }
        }
        var raw: [String: [String: Any]] = [:]
        for (id, entry) in entries {
            raw[id] = ["gain": entry.gain, "lastSeen": entry.lastSeen]
        }
        defaults.set(raw, forKey: Self.key)
    }

    /// Drop entries for apps that stayed gone past the expiry window so the
    /// store cannot grow without bound.
    private func prune() {
        let cutoff = Calendar.current.date(byAdding: .day, value: -Self.expiryDays, to: Date()) ?? Date()
        entries = entries.filter { $0.value.lastSeen > cutoff }
    }
}
