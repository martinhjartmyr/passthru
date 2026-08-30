// Device-list diff helper.
//
// Pure function over two ID sets. The CoreAudio system-object listener
// fires on any device list change but exposes no added/removed selectors;
// the caller diffs the new set against the previous one. Lives next to
// the routing decision so the same test target can exercise both.

import Foundation

public struct DeviceListDiff: Equatable {
    public let added: Set<UInt32>
    public let removed: Set<UInt32>

    public init(added: Set<UInt32>, removed: Set<UInt32>) {
        self.added = added
        self.removed = removed
    }
}

public enum DeviceListDiffer {
    public static func diff(previous: Set<UInt32>, current: Set<UInt32>) -> DeviceListDiff {
        DeviceListDiff(
            added: current.subtracting(previous),
            removed: previous.subtracting(current))
    }
}
